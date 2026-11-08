#!/usr/bin/env python3
"""Serialize native tccli processes sharing one HOME without handling credentials.

tccli initializes every profile's .configure with truncate-and-write on startup.
The lock therefore belongs to the configuration directory, not to one profile.
Exec keeps the inheritable lock descriptor in the actual tccli process: there is
no supervisor that can release the lock while its child is still writing files.
Other programs invoking tccli directly must cooperate with the same lock.
"""
import fcntl
import os
from pathlib import Path
import stat
import sys


def main():
    descriptor = None
    try:
        directory = Path.home() / ".tccli"
        directory.mkdir(mode=0o700, exist_ok=True)
        if directory.stat().st_uid != os.getuid():
            raise OSError("configuration directory is not owned by the current user")
        descriptor = os.open(directory / ".cvm-skill.lock",
                             os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid() or details.st_nlink != 1:
            raise OSError("invalid lock file")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.set_inheritable(descriptor, True)
    except KeyboardInterrupt:
        return 130
    except OSError:
        print("无法取得本机 tccli 配置锁；请检查当前用户对 ~/.tccli 的访问权限。", file=sys.stderr)
        return 73

    try:
        os.execvp("tccli", ["tccli", *sys.argv[1:]])
    except FileNotFoundError:
        print("tccli 未安装或启动器不可用。", file=sys.stderr)
        return 127
    except OSError:
        print("无法启动 tccli；请检查安装和执行权限。", file=sys.stderr)
        return 126
    finally:
        # exec success never runs this block. Only startup failure releases it.
        if descriptor is not None:
            os.close(descriptor)


if __name__ == "__main__":
    sys.exit(main())

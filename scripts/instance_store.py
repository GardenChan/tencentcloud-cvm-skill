#!/usr/bin/env python3
"""Local instance connection records: locked, atomic writes; passwords use stdin."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


def read_records(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return {}
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("记录必须是普通文件")
        records = json.load(stream)
    if not isinstance(records, dict) or any(not isinstance(v, dict) for v in records.values()):
        raise ValueError("记录文件不是实例对象，已停止以保护原文件")
    return records


@contextmanager
def locked(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(str(path) + ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def write_records(path, records):
    if path.is_symlink():
        raise ValueError("拒绝覆盖符号链接记录文件")
    fd, name = tempfile.mkstemp(prefix=".cvm-records-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(records, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "save", "connect", "host", "clear-password", "delete", "get", "list"))
    parser.add_argument("--id")
    parser.add_argument("--host", default="")
    parser.add_argument("--region", default="")
    parser.add_argument("--user", default="")
    parser.add_argument("--field", choices=("password", "host", "region", "user"))
    parser.add_argument("--reveal", action="store_true")
    args = parser.parse_args()
    path = Path(os.environ["CVM_STORE_FILE"]).expanduser()
    if args.action not in ("init", "list") and not args.id:
        parser.error("此操作需要 --id")
    if args.action in ("get", "list"):
        records = read_records(path)
        if args.action == "list":
            for record in records.values():
                record.pop("password", None)
            print(json.dumps(records, ensure_ascii=False))
        else:
            if args.id not in records:
                raise ValueError("当前 profile 没有该实例的本地记录")
            record = records[args.id]
            if args.field:
                value = record.get(args.field, "")
                if not isinstance(value, str) or not value:
                    raise ValueError("本地记录缺少所需字段")
                print(value)
            else:
                if not args.reveal:
                    record.pop("password", None)
                print(json.dumps(record, ensure_ascii=False))
        return
    with locked(path):
        records = read_records(path)
        if args.action == "delete":
            records.pop(args.id, None)
        elif args.action == "clear-password":
            if args.id in records:
                records[args.id].pop("password", None)
        elif args.action in ("save", "connect", "host"):
            record = records.setdefault(args.id, {})
            if args.action == "save":
                password = sys.stdin.read()
                if not password or "\x00" in password or "\n" in password or "\r" in password:
                    raise ValueError("密码为空或包含不支持的控制字符")
                record["password"] = password
            for field in ("host", "region", "user"):
                value = getattr(args, field)
                if value:
                    record[field] = value
            record.setdefault("created_at", datetime.now(timezone.utc).isoformat())
        write_records(path, records)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as exc:
        # Never include record contents or stdin in diagnostic output.
        print(f"本地实例记录操作失败: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)

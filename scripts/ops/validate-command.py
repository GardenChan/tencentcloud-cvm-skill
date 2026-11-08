#!/usr/bin/env python3
"""Validate one diagnostic command and emit safely quoted shell arguments.

This is a deliberately finite grammar, not a shell sandbox or a prefix blacklist.
Both SSH and TAT use the same grammar. Add new commands with argument validation.
"""
import argparse
import re
import shlex
import sys
from urllib.parse import urlsplit


EXAMPLES = """uptime; uname -a; hostname; date; timedatectl status
cat /etc/os-release; cat /proc/loadavg; cat /proc/meminfo
top -bn1; mpstat; nproc; lscpu; free -h; vmstat
df -h; df -i; lsblk; fdisk -l; du -sh /var/log
ps aux; ps -ef; pgrep nginx; pidof nginx
ip addr; ip route; ifconfig; netstat -tlnp; ss -tlnp
ping -c 4 example.com; curl -I https://example.com; dig example.com
nslookup example.com; traceroute example.com; tracepath example.com
systemctl status nginx; systemctl is-active nginx; service nginx status
systemctl list-units --type=service
tail -n 100 /var/log/syslog; head -n 100 /var/log/syslog
journalctl -u nginx -n 100; dmesg
who; w; last -n 20; lastlog; id; groups; crontab -l
docker ps; docker images; docker stats --no-stream
nginx -t; php -v; node -v; python3 --version; java -version
mysql --version; redis-cli info; redis-cli ping"""

EXACT = {
    tuple(shlex.split(c))
    for c in (
        "uptime", "uname", "uname -a", "uname -r", "uname -m",
        "hostname", "hostname -f", "hostname -I", "hostname -i", "date", "date -u",
        "timedatectl", "timedatectl status", "top -bn1", "mpstat", "nproc", "lscpu",
        "free", "free -h", "free -m", "vmstat", "df", "df -h", "df -i", "lsblk",
        "fdisk -l", "ps aux", "ps -ef", "ip addr", "ip addr show", "ip route",
        "ip route show", "ifconfig", "netstat -tlnp", "netstat -tunlp", "ss -tlnp",
        "ss -tunlp", "ss -tn", "who", "w", "lastlog", "id", "groups", "crontab -l",
        "dmesg", "docker ps", "docker ps -a", "docker images", "docker stats --no-stream",
        "nginx -t", "php -v", "node -v", "python --version", "python3 --version",
        "java -version", "mysql --version", "redis-cli info", "redis-cli ping",
        "cat /etc/os-release", "cat /proc/loadavg", "cat /proc/meminfo",
        "cat /etc/passwd", "cat /etc/group",
    )
}


def number(value, maximum=10000):
    return value.isascii() and value.isdigit() and 1 <= int(value) <= maximum


def name(value):
    return re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@:-]*", value) is not None


def host(value):
    return re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]*", value) is not None


def path(value, logs_only=False):
    return (value.startswith("/var/log/") if logs_only else value.startswith("/")) and ".." not in value.split("/")


def validate(command):
    if any(c in command for c in "\n\r\x00;|&><`$\\"):
        raise ValueError("仅接受单条诊断命令，不接受 Shell 运算符、转义或多行输入")
    try:
        args = shlex.split(command)
    except ValueError as exc:
        raise ValueError("命令引号不完整") from exc
    if not args or any(any(ord(c) < 32 or ord(c) == 127 for c in a) for a in args):
        raise ValueError("命令为空或包含控制字符")
    if tuple(args) in EXACT:
        return args
    cmd = args[0]
    if cmd in ("du",) and len(args) == 3 and args[1] in ("-sh", "-h") and path(args[2]):
        return args
    if cmd in ("pgrep", "pidof") and len(args) == 2 and name(args[1]):
        return args
    if cmd == "ping" and len(args) == 4 and args[1] == "-c" and number(args[2], 10) and host(args[3]):
        return args
    if cmd == "curl" and len(args) == 3 and args[1] in ("-I", "--head"):
        url = urlsplit(args[2])
        if url.scheme in ("http", "https") and url.hostname and not url.username and not url.password:
            return ["curl", "--head", "--connect-timeout", "5", "--max-time", "15", "--", args[2]]
    if cmd in ("dig", "nslookup", "traceroute", "tracepath") and len(args) == 2 and host(args[1]):
        return args
    if cmd == "systemctl":
        if len(args) == 3 and args[1] in ("status", "is-active", "is-enabled") and name(args[2]):
            return ["systemctl", "--no-pager", args[1], "--", args[2]]
        if args[1:] in (["list-units"], ["list-units", "--type=service"]):
            return ["systemctl", "--no-pager", "list-units", "--type=service"]
    if cmd == "service" and len(args) == 3 and name(args[1]) and args[2] == "status":
        return args
    if cmd in ("tail", "head") and len(args) == 4 and args[1] == "-n" and number(args[2]) and path(args[3], logs_only=True):
        return [cmd, "-n", args[2], "--", args[3]]
    if cmd == "last" and len(args) == 3 and args[1] == "-n" and number(args[2]):
        return args
    if cmd == "journalctl":
        remaining = args[1:]
        seen = set()
        while remaining:
            flag, *remaining = remaining
            if flag in seen:
                break
            seen.add(flag)
            if flag == "--no-pager":
                continue
            if not remaining or flag not in ("-u", "-n"):
                break
            value, *remaining = remaining
            if not (name(value) if flag == "-u" else number(value)):
                break
        else:
            if "-u" in seen or "-n" in seen:
                return [*args, *([] if "--no-pager" in seen else ["--no-pager"])]
    raise ValueError("命令或参数不在诊断列表中；使用 --list 查看支持的形式，写操作请使用对应管理脚本")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--command")
    group.add_argument("--list", action="store_true")
    args = parser.parse_args()
    if args.list:
        print(EXAMPLES)
        return 0
    try:
        result = validate(args.command)
    except ValueError as exc:
        print(f"命令校验失败: {exc}", file=sys.stderr)
        return 2
    print(" ".join(shlex.quote(arg) for arg in result))
    return 0


if __name__ == "__main__":
    sys.exit(main())

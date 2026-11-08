#!/usr/bin/env python3
"""Link-only local authentication using tccli's native OAuth implementation.

Only browser launching and callback transport are adapted in a private worker.
The installed tccli owns authorization parameters, credential exchange and save.
No callback URL, token, code or credential is written to session state or logs.
"""
import argparse
import errno
import fcntl
import importlib
import inspect
import json
import os
from pathlib import Path
import queue
import re
import secrets
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import parse_qs, urlsplit

PENDING = {"starting", "awaiting_authorization", "verifying", "stopping"}
TERMINAL = {"ready", "failed", "expired", "cancelled"}
SAFE_ID = re.compile(r"^[a-f0-9]{32}$")
SAFE_PROFILE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
HERE = Path(__file__).resolve().parent


class FlowError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message
        super().__init__(message)


def atomic_json(path, value):
    if path.is_symlink():
        raise FlowError("UNSAFE_STATE", "会话文件不能为符号链接")
    fd, temporary = tempfile.mkstemp(prefix=".auth-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, encoding="utf-8") as stream:
        meta = os.fstat(stream.fileno())
        if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o077:
            raise FlowError("UNSAFE_STATE", "会话文件须归当前用户所有且不可被其他用户读取")
        return json.load(stream)


def state_root():
    root = Path(os.environ.get("TENCENT_CVM_AUTH_STATE_DIR", str(Path.home() / ".tencent-cvm/auth"))).expanduser().absolute()
    if root.is_symlink():
        raise FlowError("UNSAFE_STATE", "会话目录不能为符号链接")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    meta = root.stat()
    if meta.st_uid != os.getuid() or meta.st_mode & 0o077:
        raise FlowError("UNSAFE_STATE", "会话目录须归当前用户所有且权限为700")
    return root


def session_path(root, session_id):
    if not SAFE_ID.fullmatch(session_id):
        raise FlowError("INVALID_SESSION", "会话标识无效，请使用start返回的session_id")
    path = root / session_id
    if path.is_symlink() or not path.is_dir():
        raise FlowError("SESSION_NOT_FOUND", "未找到该授权会话")
    return path


def public_state(value):
    result = {key: value[key] for key in ("session_id", "profile", "status", "auth_url", "created_at", "expires_at", "callback_scope", "error") if key in value}
    if result.get("status") not in PENDING or result.get("status") == "stopping":
        result.pop("auth_url", None)
    return result


def process_alive(directory):
    try:
        pid = read_json(directory / "process.json")["pid"]
        os.kill(pid, 0)  # Read-only liveness check; cancel never signals this PID.
        return True
    except (OSError, ValueError, KeyError):
        return False


def update_status(directory, state, status, error=None):
    state = dict(state, status=status)
    if status not in PENDING:
        state.pop("auth_url", None)
    if error:
        state["error"] = {"code": error[0], "message": error[1]}
    atomic_json(directory / "state.json", state)
    return state


def status(directory):
    state = read_json(directory / "state.json")
    if state["status"] not in PENDING or process_alive(directory):
        return state
    # The supervisor may have published ready/failed just before exiting. A
    # stale pending snapshot must never overwrite that final result, even when
    # a later same-profile session already owns the lifecycle lock.
    state = read_json(directory / "state.json")
    if state["status"] not in PENDING:
        return state
    if state.get("version", 1) < 2:
        return update_status(directory, state, "failed", ("LOGIN_INTERRUPTED", "后台授权会话已结束；重新开始会生成新链接"))
    fd = lifecycle_file(directory.parent, state["profile"])
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            latest = read_json(directory / "state.json")
            # This is a transient response only. The live native process or a
            # successor owns the lock, so this observer must not write state.
            return dict(latest, status="stopping") if latest["status"] in PENDING else latest
        latest = read_json(directory / "state.json")
        if latest["status"] not in PENDING:
            return latest
        return update_status(directory, latest, "failed", ("LOGIN_INTERRUPTED", "后台授权会话已结束；重新开始会生成新链接"))
    finally:
        os.close(fd)


def lifecycle_file(root, profile):
    fd = os.open(root / ("profile-" + profile + ".active"), os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    os.fchmod(fd, 0o600)
    return fd


def native_python():
    executable = shutil.which("tccli")
    if not executable:
        raise FlowError("TCCLI_MISSING", "未找到tccli，请通过官方安装渠道安装")
    with open(Path(executable).resolve(), "rb") as stream:
        first = stream.readline(512).decode("utf-8", "replace").strip()
    if not first.startswith("#!"):
        raise FlowError("UNSUPPORTED_RUNTIME", "无法识别tccli运行时；链接授权需要标准Python版tccli")
    parts = shlex.split(first[2:])
    if parts and Path(parts[0]).name == "env":
        parts = parts[1:]
        if parts and parts[0] == "-S":
            parts = parts[1:]
        if len(parts) == 1:
            parts = [shutil.which(parts[0]) or ""]
    if len(parts) != 1 or not re.fullmatch(r"python(?:3(?:\.\d+)?)?", Path(parts[0]).name) or not os.access(parts[0], os.X_OK):
        raise FlowError("UNSUPPORTED_RUNTIME", "tccli启动器不是可识别的Python运行时；请使用标准Python安装，不能改用验证码收集")
    return parts[0]


def start(profile, timeout, execution_context):
    if execution_context != "local":
        return {"profile": profile, "status": "needs_host_auth", "callback_scope": "same_machine", "error": {"code": "LOCAL_CALLBACK_REQUIRED", "message": "链接授权要求浏览器和执行器位于同一台机器；远程环境请使用宿主已有认证或可信连接器"}}
    root = state_root()
    lock_path = root / ("profile-" + profile + ".lock")
    lock = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    active = None
    try:
        os.fchmod(lock, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        pointer = root / ("profile-" + profile + ".json")
        previous = {"profile": profile, "status": "stopping", "callback_scope": "same_machine"}
        if pointer.exists():
            old_directory = session_path(root, read_json(pointer)["session_id"])
            previous = status(old_directory)
            if previous["status"] in PENDING and previous["expires_at"] > time.time() and not (old_directory / "cancel").exists():
                return public_state(previous)
            if previous.get("version", 1) < 2 and process_alive(old_directory):
                # An already-running older worker cannot inherit the new lock.
                # Wait for its actual exit; never overlap it during an upgrade.
                legacy_deadline = time.monotonic() + 2
                while process_alive(old_directory) and time.monotonic() < legacy_deadline:
                    time.sleep(0.05)
                if process_alive(old_directory):
                    blocked = dict(previous, status="stopping")
                    blocked["error"] = {"code": "SESSION_STOPPING", "message": "原授权进程尚未退出，请稍后再开始"}
                    return public_state(blocked)
        # This lock is inherited by the supervisor AND native child, so neither
        # a published terminal status nor a supervisor crash permits a new
        # same-profile login while an older native process can still save.
        active = lifecycle_file(root, profile)
        wait_until = time.monotonic() + 2
        while True:
            try:
                fcntl.flock(active, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= wait_until:
                    blocked = dict(previous, status="stopping")
                    blocked["error"] = {"code": "SESSION_STOPPING", "message": "上一次授权正在停止；请稍后查询状态，不会同时启动另一个账号写入流程"}
                    return public_state(blocked)
                time.sleep(0.05)
        runtime = native_python()
        session_id = uuid.uuid4().hex
        directory = root / session_id
        directory.mkdir(mode=0o700)
        now = time.time()
        state = {"version": 2, "session_id": session_id, "profile": profile, "status": "starting", "created_at": now, "expires_at": now + timeout, "callback_scope": "same_machine"}
        atomic_json(directory / "state.json", state)
        process = subprocess.Popen([runtime, str(Path(__file__).resolve()), "_worker", "--directory", str(directory), "--lifecycle-fd", str(active)],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True, close_fds=True, pass_fds=(active,))
        atomic_json(directory / "process.json", {"pid": process.pid})
        atomic_json(pointer, {"session_id": session_id})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            state = read_json(directory / "state.json")
            if state["status"] != "starting":
                break
            if process.poll() is not None:
                state = read_json(directory / "state.json")
                if state["status"] in PENDING:
                    # The native child may still hold the inherited lifecycle
                    # lock while its parent-loss watchdog shuts it down. Do not
                    # publish a terminal state or overwrite a fresh final result.
                    state = dict(state, status="stopping")
                break
            time.sleep(0.05)
        return public_state(state)
    finally:
        if active is not None:
            os.close(active)
        os.close(lock)


def cancel(directory):
    state = status(directory)
    if state["status"] not in PENDING:
        return public_state(state)
    # The worker observes this marker and terminates only its own work. Never
    # signal a stored PID, which could belong to another process after reuse.
    fd = os.open(directory / "cancel", os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    os.close(fd)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        state = status(directory)
        if state["status"] not in PENDING:
            break
        time.sleep(0.05)
    return public_state(state)


def native_modules():
    login = importlib.import_module("tccli.plugins.auth.login")
    browser_flow = importlib.import_module("tccli.plugins.auth.browser_flow")
    inspect.signature(login.login).bind(True, "profile", "zh-CN")
    if not all(callable(getattr(browser_flow, name, None)) for name in ("try_run", "HTTPHandler", "ThreadingHTTPServer")) or not callable(login.webbrowser.open):
        raise FlowError("UNSUPPORTED_RUNTIME", "当前tccli原生认证接口不兼容，请通过原渠道更新后重试")
    return login, browser_flow


def authorization_url(url, callback_port):
    parsed = urlsplit(url)
    query = parse_qs(parsed.query)
    if parsed.scheme != "https" or parsed.netloc != "cloud.tencent.com" or parsed.path != "/open/authorize" or parsed.fragment:
        raise FlowError("UNSUPPORTED_AUTH_URL", "tccli生成了不受支持的授权地址，已停止")
    if set(query) != {"scope", "app_id", "redirect_url", "state"} or any(len(v) != 1 for v in query.values()) or query["scope"] != ["login"]:
        raise FlowError("UNSUPPORTED_AUTH_URL", "tccli授权地址格式发生变化，已停止")
    target = urlsplit(query["redirect_url"][0])
    if target.scheme != "https" or target.netloc != "cli.cloud.tencent.com" or target.path != "/oauth":
        raise FlowError("UNSUPPORTED_AUTH_URL", "授权回调服务不匹配，已停止")
    nested = parse_qs(target.query)
    if len(nested.get("redirect_url", [])) != 1:
        raise FlowError("UNSUPPORTED_AUTH_URL", "授权地址缺少唯一的本机会话回调，已停止")
    callback = urlsplit(nested["redirect_url"][0])
    try:
        matching_port = callback.port == callback_port
    except ValueError:
        matching_port = False
    if (callback.scheme != "http" or callback.hostname not in ("localhost", "127.0.0.1")
            or callback.username is not None or callback.password is not None
            or callback.path not in ("", "/") or callback.query or callback.fragment or not matching_port):
        raise FlowError("UNSUPPORTED_AUTH_URL", "授权回调不属于本次本机会话，已停止")
    return query["state"][0]


def stop_owned_process(process, force=False):
    if process is None:
        return
    if process.poll() is None:
        # Each child has a new process session. Signals never reach a browser,
        # the caller, or unrelated services. Native login stops immediately so
        # it cannot save credentials while cancellation is being acknowledged.
        try:
            os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    else:
        process.wait()


def loopback_servers(server_base, handler, attempts=20):
    """Own both possible localhost destinations before publishing the link."""
    class IPv4Server(server_base):
        address_family = socket.AF_INET
        allow_reuse_address = False
        daemon_threads = True

    class IPv6Server(server_base):
        address_family = socket.AF_INET6
        allow_reuse_address = False
        daemon_threads = True

        def server_bind(self):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()

    for unused in range(attempts):
        first = None
        try:
            first = IPv4Server(("127.0.0.1", 0), handler)
            second = IPv6Server(("::1", first.server_address[1]), handler)
            return [first, second]
        except OSError as exc:
            if first is not None:
                first.server_close()
            if exc.errno == errno.EADDRINUSE:
                continue
            if isinstance(exc, PermissionError):
                raise FlowError("LOCAL_CALLBACK_BLOCKED", "当前执行器不允许监听本机回调端口；请通过具备本机权限的宿主启动授权") from exc
            raise FlowError("LOCAL_CALLBACK_UNAVAILABLE", "无法同时独占本机IPv4和IPv6回调；已停止，未生成可能回到其他服务的授权链接") from exc
    raise FlowError("LOCAL_CALLBACK_UNAVAILABLE", "本机回调端口持续冲突，请稍后重试")


def native_worker(directory, parent_pid):
    """The only process allowed to invoke native OAuth or save credentials."""
    os.umask(0o077)
    state = read_json(directory / "state.json")
    servers = []
    expected_state = {"value": None}
    callback_used = threading.Event()
    callback_lock = threading.Lock()

    def event(kind, **values):
        atomic_json(directory / "native.json", dict(kind=kind, **values))

    def parent_watchdog():
        while True:
            # If the supervisor is killed, the inherited lifecycle lock remains
            # held until this child exits. No orphan login can run indefinitely.
            if os.getppid() != parent_pid or time.time() >= state["expires_at"]:
                os._exit(143)
            time.sleep(0.05)

    threading.Thread(target=parent_watchdog, daemon=True).start()
    try:
        try:
            native, transport = native_modules()
        except (ImportError, AttributeError, TypeError, ValueError) as exc:
            raise FlowError("UNSUPPORTED_RUNTIME", "当前tccli原生认证接口不兼容，请通过原渠道更新后重试") from exc
        credential_dir = Path.home() / ".tccli"
        credential_dir.mkdir(mode=0o700, exist_ok=True)
        credential_file = credential_dir / (state["profile"] + ".credential")
        if credential_file.is_symlink():
            raise FlowError("UNSAFE_CREDENTIAL_PATH", "账号凭证路径不能是符号链接")

        class Handler(transport.HTTPHandler):
            result_queue = queue.Queue(1)

            def send_response(self, code, message=None):
                self.response_status = code
                super().send_response(code, message)

            def do_GET(self):
                parsed = urlsplit(self.path)
                values = parse_qs(parsed.query)
                supplied = values.get("state", [""])
                redirect = urlsplit(values.get("redirect_url", [""])[0])
                valid = parsed.path == "/" and len(supplied) == 1 and expected_state["value"] and secrets.compare_digest(supplied[0], expected_state["value"])
                valid = valid and redirect.scheme == "https" and redirect.netloc == "cli.cloud.tencent.com" and redirect.path == "/oauth_success"
                with callback_lock:
                    if not valid or callback_used.is_set():
                        self.send_response(400)
                        self.end_headers()
                        self.wfile.write(b"This login link is invalid or already used. Return to the chat for the current link.")
                        return
                    callback_used.set()
                # Native tccli alone exchanges the token and stores credentials.
                super().do_GET()
                if getattr(self, "response_status", 500) >= 400:
                    event("failed", error={"code": "AUTH_FAILED", "message": "腾讯云授权回调未完成，请重新开始并使用本次链接"})
                    os._exit(1)

            def log_message(self, *args):
                pass

        def local_transport(*unused):
            servers.extend(loopback_servers(transport.ThreadingHTTPServer, Handler))
            for server in servers:
                threading.Thread(target=server.serve_forever, daemon=True).start()
            return servers[0].server_address[1], Handler.result_queue

        def capture_url(url, *unused, **kwargs):
            if len(servers) != 2 or servers[0].server_address[1] != servers[1].server_address[1]:
                raise FlowError("UNSUPPORTED_AUTH_URL", "本次双栈本机回调尚未就绪，已停止")
            expected_state["value"] = authorization_url(url, servers[0].server_address[1])
            event("authorize", auth_url=url)
            return True

        transport.try_run = local_transport
        native.webbrowser.open = capture_url
        native.login(True, state["profile"], "zh-CN")
        if credential_file.exists():
            os.chmod(credential_file, 0o600)
        event("authorized")
        return 0
    except BaseException as exc:
        code = exc.code if isinstance(exc, FlowError) else "AUTH_FAILED"
        message = exc.message if isinstance(exc, FlowError) else "本次原生授权未完成；请使用重新开始后生成的新链接"
        event("failed", error={"code": code, "message": message})
        return 1
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


def worker(directory, lifecycle_fd):
    """Publish terminal status only after all credential-writing work is dead."""
    os.umask(0o077)
    state = read_json(directory / "state.json")
    native = None
    check = None
    terminal = "failed"
    failure = ("AUTH_FAILED", "后台授权未完成")
    try:
        native = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_native", "--directory", str(directory),
                                   "--parent-pid", str(os.getpid()), "--lifecycle-fd", str(lifecycle_fd)],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  start_new_session=True, close_fds=True, pass_fds=(lifecycle_fd,))
        while True:
            current = read_json(directory / "state.json")
            if (directory / "cancel").exists():
                update_status(directory, current, "stopping")
                terminal, failure = "cancelled", None
                break
            if time.time() >= state["expires_at"]:
                update_status(directory, current, "stopping")
                terminal = "expired"
                failure = ("LOGIN_EXPIRED", "本次授权已过期；重新开始会生成新链接")
                break
            if check is not None:
                code = check.poll()
                if code is not None:
                    terminal = "ready" if code == 0 else "failed"
                    failure = None if code == 0 else ("AUTH_CHECK_FAILED", "网页授权已完成并保存认证，但只读连接检查未通过；请先复用已有认证检查连接和权限，无需重新登录；未创建或购买资源")
                    break
            else:
                try:
                    message = read_json(directory / "native.json")
                except FileNotFoundError:
                    message = {}
                if message.get("kind") == "authorize" and current["status"] == "starting":
                    update_status(directory, dict(current, auth_url=message["auth_url"]), "awaiting_authorization")
                code = native.poll()
                if code is not None:
                    native.wait()
                    try:
                        message = read_json(directory / "native.json")
                    except FileNotFoundError:
                        message = {}
                    if code != 0 or message.get("kind") != "authorized":
                        error = message.get("error", {})
                        failure = (error.get("code", "AUTH_FAILED"), error.get("message", "本次授权未完成；请重新开始并使用新的链接"))
                        break
                    update_status(directory, current, "verifying")
                    check = subprocess.Popen(["/bin/bash", str(HERE / "check.sh"), "--profile", state["profile"]],
                                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                             start_new_session=True)
            time.sleep(0.05)
    except BaseException as exc:
        failure = (exc.code, exc.message) if isinstance(exc, FlowError) else ("UNSUPPORTED_RUNTIME", "当前tccli运行时无法完成链接授权，请通过原渠道更新后重试")
    finally:
        stop_owned_process(native, force=True)
        stop_owned_process(check)
        # Native can no longer write credentials or state after wait() returns.
        update_status(directory, read_json(directory / "state.json"), terminal, failure)
        os.close(lifecycle_fd)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "status", "cancel", "_worker", "_native"))
    parser.add_argument("--profile", default="default")
    parser.add_argument("--session-id")
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--lifecycle-fd", type=int)
    parser.add_argument("--parent-pid", type=int)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--execution-context", choices=("local", "remote", "unknown"), default="unknown")
    args = parser.parse_args()
    if not SAFE_PROFILE.fullmatch(args.profile):
        parser.error("profile格式无效")
    if not 1 <= args.timeout <= 3600:
        parser.error("timeout须为1–3600秒")
    try:
        if args.action == "_worker":
            worker(args.directory, args.lifecycle_fd)
            os._exit(0)
        if args.action == "_native":
            result = native_worker(args.directory, args.parent_pid)
            os._exit(result)
        if args.action == "start":
            value = start(args.profile, args.timeout, args.execution_context)
        else:
            directory = session_path(state_root(), args.session_id or "")
            value = public_state(status(directory)) if args.action == "status" else cancel(directory)
        print(json.dumps(value, ensure_ascii=False))
        return 0 if value["status"] not in {"failed", "expired", "needs_host_auth"} else 1
    except (FlowError, OSError, ValueError, KeyError) as exc:
        code = exc.code if isinstance(exc, FlowError) else "LOCAL_AUTH_ERROR"
        message = exc.message if isinstance(exc, FlowError) else "无法读取或创建本地授权会话，请检查权限或重新开始"
        print(json.dumps({"status": "failed", "error": {"code": code, "message": message}}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())

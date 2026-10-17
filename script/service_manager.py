#!/usr/bin/env python3
"""Install or control user LaunchAgents for the local Gateway and Whisper service."""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import time
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# This helper imports the sibling supervisor from a signed app resource directory.
# Runtime bytecode files would modify that signed bundle.
sys.dont_write_bytecode = True

GATEWAY = "dev.kamisato-yuna.MLXGateway.service"
WHISPER = "dev.kamisato-yuna.MLXGateway.whisper"
LABELS = (WHISPER, GATEWAY)
ROOT = Path(__file__).resolve().parent.parent
USER_HOME = Path.home()
AGENTS = USER_HOME / "Library/LaunchAgents"
SUPPORT = USER_HOME / "Library/Application Support/MLXGateway/service"
LOGS = USER_HOME / "Library/Logs/MLXGateway/services"
APP = USER_HOME / "Applications/MLXGateway.app"
DOMAIN = f"gui/{os.getuid()}"
MAINTENANCE = "dev.kamisato-yuna.MLXGateway.maintenance"
OPERATION = SUPPORT / "last-operation.json"


def call(*args, check=True):
    return subprocess.run(list(map(str, args)), check=check, text=True, capture_output=True, timeout=30)


def job(label):
    return f"{DOMAIN}/{label}"


def plist(label, arguments, cwd, name):
    return {
        "Label": label, "ProgramArguments": list(map(str, arguments)),
        "WorkingDirectory": str(cwd), "RunAtLoad": True, "KeepAlive": True,
        "ThrottleInterval": 5, "ExitTimeOut": 15, "AbandonProcessGroup": False,
        "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive", "Umask": 63,
        "AssociatedBundleIdentifiers": ["dev.kamisato-yuna.MLXGateway"],
        "StandardOutPath": str(LOGS / f"{name}.stdout.log"),
        "StandardErrorPath": str(LOGS / f"{name}.stderr.log"),
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                 "PYTHONUNBUFFERED": "1"},
    }


def stop_jobs():
    # Stop the HTTP entry first, so new requests do not arrive during backend shutdown.
    for label in (GATEWAY, WHISPER):
        if call("/bin/launchctl", "print", job(label), check=False).returncode == 0:
            call("/bin/launchctl", "bootout", job(label))
            deadline = time.monotonic() + 25
            while call("/bin/launchctl", "print", job(label), check=False).returncode == 0:
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"{label} 尚未退出，请检查日志后重试。")
                time.sleep(0.1)


def start_jobs():
    for label in LABELS:
        call("/bin/launchctl", "enable", job(label))
        if call("/bin/launchctl", "print", job(label), check=False).returncode != 0:
            call("/bin/launchctl", "bootstrap", DOMAIN, AGENTS / f"{label}.plist")


def stop_original_listener(port, identifier):
    found = call("/usr/sbin/lsof", "-nP", "-t", f"-iTCP:{port}", "-sTCP:LISTEN", check=False)
    for raw in set(found.stdout.split()):
        pid = int(raw)
        command = call("/bin/ps", "-p", pid, "-o", "args=").stdout.strip()
        if identifier not in command:
            raise RuntimeError(f"Port {port} belongs to an unexpected process; not stopping it")
        print(f"Migrating existing {identifier} listener: pid={pid}, port={port}", flush=True)
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            listeners = call("/usr/sbin/lsof", "-nP", "-t", f"-iTCP:{port}", "-sTCP:LISTEN", check=False)
            if raw not in listeners.stdout.split():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"Original listener on {port} did not stop; not force-killing it")


def install(source_app, runtime):
    from whisper_supervisor import Configuration
    config_file = runtime / "audio-service/gateway.json"
    config = Configuration.read(config_file)
    if config.base_url != "http://127.0.0.1:44120/v1" or config.model != "whisper-1":
        raise RuntimeError("Existing Whisper endpoint/model differs; leaving it unchanged")
    for key, expected in (("gatewayHost", "127.0.0.1"), ("gatewayPort", "44110"),
                          ("runtimeDirectory", str(runtime))):
        value = call("/usr/bin/defaults", "read", "dev.kamisato-yuna.MLXGateway", key).stdout.strip()
        if value != expected:
            raise RuntimeError(f"Existing {key} differs; leaving it unchanged")
    call("/usr/bin/codesign", "--verify", "--strict", source_app)
    info = plistlib.loads((source_app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "dev.kamisato-yuna.MLXGateway":
        raise RuntimeError("Source bundle is not MLX Gateway")
    if APP.exists():
        existing = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
        if existing.get("CFBundleIdentifier") != info["CFBundleIdentifier"]:
            raise RuntimeError("Destination belongs to another app; not replacing it")
        call("/usr/bin/codesign", "--verify", "--strict", APP)
    python = runtime / ".venv/bin/python"
    if not os.access(python, os.X_OK):
        raise RuntimeError("Existing runtime Python is not executable")
    for directory in (AGENTS, SUPPORT, LOGS, APP.parent):
        directory.mkdir(parents=True, exist_ok=True)
    staging = SUPPORT / "MLXGateway.installing.app"
    if staging.exists():
        raise RuntimeError("An unfinished app staging directory exists; inspect it before retrying")
    call("/usr/bin/ditto", source_app, staging)
    call("/usr/bin/codesign", "--verify", "--strict", staging)
    candidates = {
        WHISPER: plist(WHISPER, [python, SUPPORT / "whisper_supervisor.py", "--config", config_file], runtime, "whisper"),
        GATEWAY: plist(GATEWAY, [APP / "Contents/MacOS/MLXGateway"], runtime, "gateway"),
    }
    # Complete copies and validations before interrupting either live listener.
    stop_jobs()
    stop_original_listener(44110, "/MLXGateway.app/Contents/MacOS/MLXGateway")
    stop_original_listener(44120, "-m mlx_audio.server")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    if APP.exists():
        backup = SUPPORT / "backups" / stamp
        backup.mkdir(parents=True, exist_ok=True)
        APP.rename(backup / APP.name)
    staging.rename(APP)
    shutil.copy2(Path(__file__).with_name("whisper_supervisor.py"), SUPPORT / "whisper_supervisor.py")
    for label, content in candidates.items():
        path = AGENTS / f"{label}.plist"
        if path.exists():
            backup = SUPPORT / "backups" / stamp
            backup.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, backup / path.name)
        path.write_bytes(plistlib.dumps(content, sort_keys=False))
        path.chmod(0o600)
        call("/usr/bin/plutil", "-lint", path)
    start_jobs()
    print(json.dumps({"app": str(APP), "launch_agents": [str(AGENTS / f"{label}.plist") for label in LABELS],
                      "runtime": str(runtime), "logs": str(LOGS)}, ensure_ascii=False, indent=2))


def status():
    for label in LABELS:
        result = call("/bin/launchctl", "print", job(label), check=False)
        print(label)
        if result.returncode:
            print("  not loaded")
        else:
            for line in result.stdout.splitlines():
                if any(key in line for key in ("state =", "pid =", "runs =", "last exit code", "last terminating signal")):
                    print(line.strip())


def read_plists():
    return {label: plistlib.loads((AGENTS / f"{label}.plist").read_bytes()) for label in LABELS}


def read_job(label, disabled):
    path = AGENTS / f"{label}.plist"
    content = plistlib.loads(path.read_bytes()) if path.exists() else {}
    result = call("/bin/launchctl", "print", job(label), check=False)
    def field(name):
        found = re.search(r"^\t" + re.escape(name) + r" = (.+)$", result.stdout, re.MULTILINE)
        return found.group(1) if found else None
    pid = field("pid")
    return {"label": label, "name": "Gateway" if label == GATEWAY else "Whisper",
            "installed": bool(content), "loaded": result.returncode == 0,
            "login": bool(content.get("RunAtLoad")) and not disabled,
            "recovery": content.get("KeepAlive") is True and not disabled,
            "state": field("state") or "未加载", "pid": int(pid) if pid else None,
            "runs": int(field("runs") or 0),
            "lastExit": field("last exit code") or field("last terminating signal") or "—"}


def http_json(url):
    try:
        with urllib.request.urlopen(url, timeout=1) as response:
            return json.load(response)
    except Exception:
        return None


def whisper_ready(config, jobs):
    from whisper_supervisor import listener_is_child
    audio_url = config.get("baseURL", "").rstrip("/")
    if not audio_url:
        return False
    managed = next((entry for entry in jobs if entry["label"] == WHISPER and entry["loaded"]), None)
    def owned():
        return managed is None or (managed["state"] == "running" and managed["pid"] is not None
                                   and listener_is_child(audio_url, managed["pid"]))
    try:
        if not owned():
            return False
        models = http_json(audio_url + "/models")
        return (isinstance(models, dict) and isinstance(models.get("data"), list)
                and any(isinstance(item, dict) and item.get("id") == config.get("model") for item in models["data"])
                and owned())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        return False


def snapshot(runtime):
    disabled_output = call("/bin/launchctl", "print-disabled", DOMAIN).stdout
    jobs = [read_job(label, bool(re.search('"' + re.escape(label) + r'"\s*=>\s*true', disabled_output)))
            for label in LABELS]
    gateway_host = call("/usr/bin/defaults", "read", "dev.kamisato-yuna.MLXGateway", "gatewayHost", check=False).stdout.strip()
    gateway_port = call("/usr/bin/defaults", "read", "dev.kamisato-yuna.MLXGateway", "gatewayPort", check=False).stdout.strip()
    gateway_url = f"http://{'[' + gateway_host + ']' if ':' in gateway_host else gateway_host}:{gateway_port}"
    config_path = runtime / "audio-service/gateway.json"
    config = json.loads(config_path.read_text()) if config_path.exists() else {}
    audio_url = config.get("baseURL", "").rstrip("/")
    with ThreadPoolExecutor(max_workers=2) as pool:
        health_task = pool.submit(http_json, gateway_url + "/health")
        models_task = pool.submit(whisper_ready, config, jobs)
        health = health_task.result()
        ready = models_task.result()
    model = config.get("model", "")
    operation = json.loads(OPERATION.read_text()) if OPERATION.exists() else None
    if operation and operation.get("state") == "running":
        worker = call("/bin/launchctl", "print", job(MAINTENANCE), check=False)
        if worker.returncode or not re.search(r"^\tpid = \d+", worker.stdout, re.MULTILINE):
            operation = dict(operation, state="failed", message="服务操作助手已退出，请检查维护日志后重试。")
    return {"jobs": jobs, "gatewayReady": health is not None, "whisperReady": ready,
            "gatewayURL": gateway_url, "audioURL": audio_url, "model": model,
            "logs": str(LOGS), "operation": operation}


def write_operation(action, state, message):
    SUPPORT.mkdir(parents=True, exist_ok=True)
    temporary = OPERATION.with_suffix(".tmp")
    temporary.write_text(json.dumps({"action": action, "state": state, "message": message,
                                     "date": datetime.now().astimezone().isoformat()}, ensure_ascii=False))
    temporary.chmod(0o600)
    temporary.replace(OPERATION)


def configure_jobs(contents, login, recovery):
    if recovery and not login:
        raise ValueError("自动恢复需要同时启用登录自启。")
    for label, content in contents.items():
        content = dict(content, RunAtLoad=login, KeepAlive=recovery)
        path = AGENTS / f"{label}.plist"
        temporary = path.with_suffix(".tmp")
        temporary.write_bytes(plistlib.dumps(content, sort_keys=False))
        temporary.chmod(0o600)
        temporary.replace(path)
        call("/bin/launchctl", "enable" if login else "disable", job(label))


def start_configured_jobs(contents):
    for label, content in contents.items():
        call("/bin/launchctl", "enable", job(label))
        if call("/bin/launchctl", "print", job(label), check=False).returncode:
            call("/bin/launchctl", "bootstrap", DOMAIN, AGENTS / f"{label}.plist")
        call("/bin/launchctl", "kickstart", job(label))
        # Disabled jobs already running continue until stopped, but will not start at login.
        if not content.get("RunAtLoad"):
            call("/bin/launchctl", "disable", job(label))


def stop_control_window(pid):
    if not pid:
        return
    result = call("/bin/ps", "-p", pid, "-o", "args=", check=False)
    if not result.stdout.strip():
        return
    executable = str(APP / "Contents/MacOS/MLXGateway")
    if not result.stdout.strip().startswith(executable) or "--service-control" not in result.stdout:
        raise RuntimeError("控制窗口进程已变化，未终止其他应用。")
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    raise RuntimeError("控制窗口未退出，请关闭窗口后重试。")


def worker(args):
    action = args.operation
    try:
        contents = read_plists()
        if action == "configure" and args.recovery == "true" and args.login != "true":
            raise ValueError("自动恢复需要同时启用登录自启。")
        # Reject unrelated jobs before any mutation; preserve every launch argument and endpoint.
        if contents[GATEWAY].get("ProgramArguments") != [str(APP / "Contents/MacOS/MLXGateway")]:
            raise RuntimeError("Gateway 启动路径不同，请先检查已有服务配置。")
        running = any(call("/bin/launchctl", "print", job(label), check=False).returncode == 0 for label in LABELS)
        stop_jobs()
        if action == "configure":
            configure_jobs(contents, args.login == "true", args.recovery == "true")
            contents = read_plists()
        should_start = action in ("start", "restart") or (action == "configure" and running)
        if should_start:
            stop_control_window(args.control_pid)
            call("/usr/bin/defaults", "write", "dev.kamisato-yuna.MLXGateway", "showServiceSettingsOnce", "-bool", "true")
            start_configured_jobs(contents)
        write_operation(action, "completed", {"start": "已提交启动，等待就绪。", "stop": "服务已停止。",
                        "restart": "已提交重启，等待就绪。", "configure": "常驻配置已保存。"}[action])
        if not should_start and not args.control_pid:
            call("/usr/bin/open", "-n", APP, "--args", "--service-control", "--show-service-settings")
    except Exception as error:
        write_operation(action, "failed", str(error))
        # Leave a usable control window after failure, without starting a listener implicitly.
        if not args.control_pid:
            call("/usr/bin/open", "-n", APP, "--args", "--service-control", "--show-service-settings", check=False)
        raise


def submit(args):
    current = call("/bin/launchctl", "print", job(MAINTENANCE), check=False)
    if re.search(r"^\tpid = \d+", current.stdout, re.MULTILINE):
        raise RuntimeError("另一个服务操作正在执行，请稍候。")
    call("/bin/launchctl", "bootout", job(MAINTENANCE), check=False)
    LOGS.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, str(Path(__file__).resolve()), "worker", "--operation", args.operation,
               "--login", args.login, "--recovery", args.recovery, "--control-pid", str(args.control_pid)]
    write_operation(args.operation, "running", "正在执行服务操作…")
    try:
        # launchctl submit infers KeepAlive; use an explicit one-shot job instead.
        maintenance_path = SUPPORT / "maintenance.plist"
        content = plist(MAINTENANCE, command, USER_HOME, "maintenance")
        content["KeepAlive"] = False
        maintenance_path.write_bytes(plistlib.dumps(content, sort_keys=False))
        maintenance_path.chmod(0o600)
        call("/bin/launchctl", "bootstrap", DOMAIN, maintenance_path)
    except Exception as error:
        write_operation(args.operation, "failed", str(error))
        raise
    print(json.dumps({"submitted": True}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "start", "stop", "status", "snapshot", "submit", "worker"))
    parser.add_argument("--operation", choices=("start", "stop", "restart", "configure"), default="start")
    parser.add_argument("--login", choices=("true", "false"), default="true")
    parser.add_argument("--recovery", choices=("true", "false"), default="true")
    parser.add_argument("--control-pid", type=int, default=0)
    parser.add_argument("--app", type=Path, default=ROOT / "build/DerivedData/Build/Products/Debug/MLXGateway.app")
    parser.add_argument("--runtime", type=Path, default=ROOT.parent / "mlx-local-runtime")
    args = parser.parse_args()
    if args.action == "install":
        install(args.app.resolve(), args.runtime.resolve())
    elif args.action == "start":
        start_configured_jobs(read_plists()); status()
    elif args.action == "stop":
        for label in LABELS:
            call("/bin/launchctl", "disable", job(label))
        stop_jobs(); status()
    elif args.action == "snapshot":
        print(json.dumps(snapshot(args.runtime.resolve()), ensure_ascii=False))
    elif args.action == "submit":
        submit(args)
    elif args.action == "worker":
        worker(args)
    else:
        status()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""llama.cpp 控制台 —— 本地 Web 面板（仅用 Python 标准库）。

功能:
  * 查看 llama-server 运行状态 / 已加载模型 / 显存占用
  * 在 4 个本地模型之间切换（写入 [models] active 后重启）
  * 调节 -ngl / -c / 线程 / 并发 / KV cache 类型 / flash-attn / mmproj
  * 一键重启、停止、跑一次对话测速（tok/s），日志实时查看

用法:
    python app.py                # http://127.0.0.1:8090
    python app.py --port 8095

环境变量:
    LLAMA_CPP_ROOT    默认 D:\\llama.cpp
    LLAMA_PANEL_CONF  覆盖 ini 路径（测试用）
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import tools as local_tools

# --------------------------------------------------------------------------
# 路径与常量
# --------------------------------------------------------------------------
ROOT = Path(os.environ.get("LLAMA_CPP_ROOT", str(Path(__file__).resolve().parent.parent)))
CONF = Path(os.environ.get("LLAMA_PANEL_CONF", str(ROOT / "scripts" / "llama.conf.ini")))
SCRIPTS = ROOT / "scripts"
LOGS = ROOT / "logs"
PID_FILE = LOGS / "llama-server.pid"
LAUNCHER = SCRIPTS / "start-llama.ps1"
PANEL_DIR = Path(__file__).resolve().parent
UI_FILE = PANEL_DIR / "ui.html"
BACKUP_DIR = PANEL_DIR / "backups"

CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
JOB_TIMEOUT = 300          # start-llama.ps1 自身最多等 240s 就绪
MAX_BODY = 1 << 20

# --------------------------------------------------------------------------
# 与会话 / 目录浏览（供 web/chat.html 使用）
# --------------------------------------------------------------------------
DATA_DIR = Path(os.environ.get("LLAMA_PANEL_DATA", str(PANEL_DIR / "data")))
SESS_FILE = DATA_DIR / "chat-sessions.json"
FS_LIMIT = 400
APP_EXE = ROOT / "chat-app" / "llama-chat.exe"
SKIN_DIR = ROOT / "web" / "skins"
VENDOR_DIR = ROOT / "web" / "vendor"
VENDOR_MIME = {
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".woff2": "font/woff2",
    ".woff": "font/woff",
    ".ttf": "font/ttf",
    ".svg": "image/svg+xml",
    ".map": "application/json",
}
SKIN_MIME = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
             ".webp": "image/webp", ".svg": "image/svg+xml", ".json": "application/json",
             ".css": "text/css"}
SAMPLING_KEYS = (
    "temp", "top_p", "top_k", "min_p",
    "presence_penalty", "frequency_penalty",
    "repeat_penalty", "repeat_last_n", "dry_multiplier",
)

def load_sessions():
    try:
        return json.loads(SESS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None

SESS_BACKUP_DIR = DATA_DIR / "backups"
BACKUP_KEEP = 30


def backup_sessions() -> None:
    """每次写盘前留一份快照，最多保留 BACKUP_KEEP 份。"""
    if not SESS_FILE.exists():
        return
    try:
        SESS_BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        target = SESS_BACKUP_DIR / f"chat-sessions-{stamp}.json"
        if not target.exists():
            shutil.copy2(SESS_FILE, target)
        files = sorted(SESS_BACKUP_DIR.glob("chat-sessions-*.json"))
        for old in files[:-BACKUP_KEEP]:
            old.unlink(missing_ok=True)
    except Exception as exc:  # noqa: BLE001
        log(f"备份会话失败：{exc}")


def save_sessions(payload) -> int:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    backup_sessions()
    tmp = SESS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, SESS_FILE)
    return SESS_FILE.stat().st_size

def vendor_file(rel: str) -> Path:
    """静态第三方资源（KaTeX 等）只允许落在 web/vendor 下。"""
    base = VENDOR_DIR.resolve()
    target = (base / rel.replace("/", os.sep)).resolve()
    if not str(target).lower().startswith(str(base).lower()):
        raise PermissionError("静态资源路径越界")
    return target


def skin_file(rel: str) -> Path:
    """皮肤资源只允许落在 web/skins 下。"""
    base = SKIN_DIR.resolve()
    target = (base / rel.replace("/", "\\")).resolve()
    if not str(target).lower().startswith(str(base).lower()):
        raise PermissionError("皮肤路径越界")
    return target


def fs_list(path_value: str) -> dict:
    """只读列目录：工作区选路径、把目录清单塞进上下文都走这里。"""
    if not path_value:
        roots = []
        try:
            roots = [d + "\\" for d in os.listdrives()]
        except AttributeError:
            roots = [f"{c}:\\" for c in "CDEFGH" if os.path.exists(f"{c}:\\")]
        return {"path": "", "parent": "", "roots": roots, "entries": []}

    raw = str(path_value or "").strip()
    p = Path(raw).expanduser() if raw else Path.home()
    if not p.is_absolute():
        raise ValueError("必须是绝对路径")
    fell_back = False
    if not p.exists() or not p.is_dir():
        # 常见情况：配置里还留着 Windows 路径（D:\...）或已被删除
        # 与其报错，不如回到 home，让用户自己点进去选
        fell_back = True
        p = Path.home()

    entries = []
    try:
        with os.scandir(p) as it:
            for i, e in enumerate(it):
                if i >= FS_LIMIT:
                    break
                try:
                    is_dir = e.is_dir()
                except OSError:
                    is_dir = False
                try:
                    size = 0 if is_dir else e.stat().st_size
                except OSError:
                    size = 0
                entries.append({"name": e.name, "dir": is_dir, "size": size})
    except PermissionError as exc:
        raise PermissionError(f"没有权限读取: {p}") from exc

    entries.sort(key=lambda x: (not x["dir"], x["name"].lower()))
    parent = str(p.parent) if p.parent != p else ""
    return {
        "path": str(p),
        "parent": parent,
        "roots": [],
        "entries": entries,
        # 请求的路径不可用时回落到 home，前端可以据此提示用户
        "fell_back": fell_back,
        "requested": raw,
    }

ROLES = [
    ("base", "Qwen3.5 9B", "-Base"),
    ("qwen36", "Qwen3.6 35B-A3B", "-Qwen36"),
    ("deepseek", "DeepSeek R1 8B", "-DeepSeek"),
]
ROLE_LABEL = {r: l for r, l, _ in ROLES}
ROLE_SWITCH = {r: s for r, _, s in ROLES}
ROLE_FILE_KEY = {
    "base": "model",
    "qwen36": "qwen36",
    "deepseek": "deepseek",
}
ROLE_ALIAS_KEY = {
    "base": "alias",
    "qwen36": "alias_qwen36",
    "deepseek": "alias_deepseek",
}
CACHE_TYPES = {"f16", "bf16", "q8_0", "q5_1", "q5_0", "q4_1", "q4_0", "iq4_nl"}

_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# --------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------
LOG_FILE = PANEL_DIR / "panel.log"

def log(msg: str) -> None:
    """控制台（可能是 pythonw 的 None）与日志文件双写。"""
    try:
        print(f"[panel] {msg}", flush=True)
    except Exception:  # pythonw 下 sys.stdout 为 None
        pass
    try:
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > 2_000_000:
            LOG_FILE.unlink()
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}\n")
    except OSError:
        pass

def fatal(message: str) -> int:
    """启动失败时留下日志并弹窗，避免 pythonw 下静默退出。"""
    log("错误: " + message.replace("\n", " | "))
    try:
        import tkinter.messagebox as messagebox
        messagebox.showerror("llama.cpp 控制台", message)
    except Exception:  # noqa: BLE001
        pass
    return 1

def panel_running(host: str, port: int) -> bool:
    try:
        data = http_json(f"http://127.0.0.1:{port}/api/state", 1.5)
        return isinstance(data, dict) and "models" in data and "server" in data
    except Exception:  # noqa: BLE001
        return False

def open_browser(url: str) -> None:
    try:
        import webbrowser
        webbrowser.open(url)
        log(f"已请求浏览器打开: {url}")
    except Exception as exc:  # noqa: BLE001
        log(f"打开浏览器失败: {exc}")

def decode_bytes(b: bytes) -> str:
    for enc in ("utf-8", "gbk"):
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            continue
    return b.decode("utf-8", "replace")

def http_json(url: str, timeout: float = 2.0, payload=None):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with _OPENER.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))

def pid_alive(pid: int) -> bool:
    if os.name != "nt" or not pid:
        return False
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    STILL_ACTIVE = 259
    handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not handle:
        return False
    try:
        code = ctypes.c_ulong()
        ok = ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
        return bool(ok) and code.value == STILL_ACTIVE
    finally:
        ctypes.windll.kernel32.CloseHandle(handle)

def tail_text(path: Path, max_bytes: int = 262144) -> str:
    try:
        size = path.stat().st_size
        with open(path, "rb") as fh:
            if size > max_bytes:
                fh.seek(size - max_bytes)
            return decode_bytes(fh.read())
    except OSError:
        return ""

def as_int(value, default: int) -> int:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default

def image_size(path: Path):
    try:
        return path.stat().st_size
    except OSError:
        return 0

# --------------------------------------------------------------------------
# ini 读写（保注释、保 BOM、保换行风格）
# --------------------------------------------------------------------------
HEADER_RE = re.compile(r"^\s*\[([^\]]+)\]\s*$")
KV_RE = re.compile(r"^(\s*)([A-Za-z0-9_.\-]+)(\s*=\s*)(.*)$")

def parse_conf(path: Path = CONF) -> dict:
    values: dict[str, dict[str, str]] = {}
    if not path.exists():
        return values
    section = "global"
    for line in path.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        text = line.strip()
        if not text or text[0] in "#;":
            continue
        header = HEADER_RE.match(text)
        if header:
            section = header.group(1).strip().lower()
            continue
        if "=" in text:
            key, val = text.split("=", 1)
            val = val.split("#", 1)[0].strip()
            values.setdefault(section, {})[key.strip().lower()] = val
    return values

def cfg_get(values: dict, section: str, key: str, default=""):
    section_values = values.get(section)
    if not section_values:
        return default
    value = section_values.get(key)
    return default if value in (None, "") else value

def backup_conf() -> None:
    if not CONF.exists():
        return
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy2(CONF, BACKUP_DIR / f"llama.conf.{stamp}.ini")
    for old in sorted(BACKUP_DIR.glob("llama.conf.*.ini"))[:-20]:
        try:
            old.unlink()
        except OSError:
            pass

def update_conf(updates: dict[str, dict[str, str]]) -> None:
    """按 section/key 就地改值，保留缩进、行内注释、BOM 与换行符。"""
    raw = CONF.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    newline = "\r\n" if "\r\n" in text else "\n"

    pending = {section: dict(items) for section, items in updates.items()}
    out: list[str] = []
    section = "global"

    def flush(name: str) -> None:
        items = pending.pop(name, None)
        if items:
            for key, value in items.items():
                out.append(f"{key} = {value}")

    for line in text.splitlines():
        header = HEADER_RE.match(line)
        if header:
            flush(section)
            section = header.group(1).strip().lower()
            out.append(line)
            continue
        match = KV_RE.match(line)
        if match and section in pending:
            key = match.group(2).strip().lower()
            if key in pending[section]:
                value = pending[section].pop(key)
                rest = match.group(4)
                hash_at = rest.find("#")
                if hash_at >= 0:
                    body = rest[:hash_at]
                    tail = rest[len(body.rstrip()):]
                else:
                    body, tail = rest, ""
                if not body.strip():
                    tail = rest
                out.append(f"{match.group(1)}{match.group(2)}{match.group(3)}{value}{tail}")
                if not pending[section]:
                    del pending[section]
                continue
        out.append(line)

    flush(section)
    for name, items in pending.items():
        out.append("")
        out.append(f"[{name}]")
        for key, value in items.items():
            out.append(f"{key} = {value}")

    body = newline.join(out)
    if text.endswith(("\n", "\r\n")):
        body += newline
    encoded = body.encode("utf-8")
    CONF.write_bytes((b"\xef\xbb\xbf" + encoded) if bom else encoded)

def resolve_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else ROOT / path

# --------------------------------------------------------------------------
# 状态采集
# --------------------------------------------------------------------------
def server_port(values: dict) -> int:
    return as_int(cfg_get(values, "server", "port", "8080"), 8080)

def health(port: int) -> bool:
    try:
        return http_json(f"http://127.0.0.1:{port}/health", 0.9).get("status") == "ok"
    except Exception:
        return False

def loaded_model(port: int):
    """当前服务端的模型信息。router 模式下会有多个，用 router 标记。"""
    try:
        data = http_json(f"http://127.0.0.1:{port}/v1/models", 2.0)
        items = data.get("data") or []
        if not items:
            return None
        router = any(isinstance(m.get("status"), dict) for m in items)
        if router:
            models = []
            ctx_max = 0
            for m in items:
                st = (m.get("status") or {}).get("value") or ""
                ctx = int(m.get("context_length") or 0)
                ctx_max = max(ctx_max, ctx)
                models.append({"id": m.get("id") or "", "status": st, "ctx": ctx})
            return {"router": True, "id": "router", "n_ctx": ctx_max or None, "models": models}
        first = items[0]
        meta = first.get("meta") or {}
        return {
            "id": first.get("id") or "",
            "n_ctx": meta.get("n_ctx"),
            "n_params": meta.get("n_params"),
            "size": meta.get("size"),
            "ftype": meta.get("ftype"),
            "n_ctx_train": meta.get("n_ctx_train"),
        }
    except Exception:
        return None

def memory_info(pid: int = 0):
    """系统内存占用（GB）+ llama-server 进程工作集，用于面板的内存条。"""
    info = {"total_gb": 0.0, "used_gb": 0.0, "percent": 0, "proc_gb": 0.0}
    if os.name != "nt":
        return info
    gb = 1024.0 ** 3
    try:
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        st = MEMORYSTATUSEX()
        st.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            info["total_gb"] = round(st.ullTotalPhys / gb, 1)
            info["used_gb"] = round((st.ullTotalPhys - st.ullAvailPhys) / gb, 1)
            info["percent"] = int(st.dwMemoryLoad)
    except Exception:
        pass

    if pid:
        try:
            class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
                _fields_ = [
                    ("cb", ctypes.c_ulong),
                    ("PageFaultCount", ctypes.c_ulong),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t),
                ]

            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
            if handle:
                try:
                    counters = PROCESS_MEMORY_COUNTERS()
                    counters.cb = ctypes.sizeof(PROCESS_MEMORY_COUNTERS)
                    if ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
                        info["proc_gb"] = round(counters.WorkingSetSize / gb, 2)
                finally:
                    ctypes.windll.kernel32.CloseHandle(handle)
        except Exception:
            pass
    return info

def gpu_info():
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total,memory.used", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=4, creationflags=CREATE_NO_WINDOW,
        )
        line = out.stdout.strip().splitlines()[0]
        parts = [p.strip() for p in line.split(",")]
        return {"name": parts[0], "total_mb": int(float(parts[1])), "used_mb": int(float(parts[2]))}
    except Exception:
        return None

KEEPALIVE_TASK = "llama-keepalive"
_KA_CACHE = {"at": 0.0, "data": None}
KA_TTL = 8.0

def keepalive_state(force: bool = False) -> dict:
    """查询计划任务 llama-keepalive（每 3 分钟 ensure-running）。

    PowerShell 冷启动约 0.4s，所以结果缓存几秒，避免面板轮询把它打成重负载。
    """
    now = time.time()
    if not force and _KA_CACHE["data"] is not None and (now - _KA_CACHE["at"]) < KA_TTL:
        return _KA_CACHE["data"]

    script = r"""
$ErrorActionPreference = 'SilentlyContinue'
$t = Get-ScheduledTask -TaskName 'llama-keepalive'
if (-not $t) { '{"exists":false}'; exit 0 }
$i = Get-ScheduledTaskInfo -TaskName 'llama-keepalive'
$last = ''
$next = ''
if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $last = $i.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') }
if ($i.NextRunTime -and $i.NextRunTime.Year -gt 2000) { $next = $i.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') }
[pscustomobject]@{
  exists = $true
  enabled = ($t.State -ne 'Disabled')
  state = [string]$t.State
  lastRun = $last
  nextRun = $next
  lastResult = [int]$i.LastTaskResult
} | ConvertTo-Json -Compress
"""
    data = {"exists": None, "enabled": None, "error": "查询失败"}
    try:
        done = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
            capture_output=True, timeout=10, creationflags=CREATE_NO_WINDOW,
        )
        lines = decode_bytes(done.stdout).strip().splitlines()
        parsed = json.loads(lines[-1]) if lines else {}
        if isinstance(parsed, dict):
            data = parsed
    except Exception as exc:  # noqa: BLE001
        data = {"exists": None, "enabled": None, "error": str(exc)}

    _KA_CACHE["at"] = now
    _KA_CACHE["data"] = data
    return data

def set_keepalive(enabled: bool) -> dict:
    action = "/ENABLE" if enabled else "/DISABLE"
    ok = False
    output = ""
    try:
        done = subprocess.run(
            ["schtasks.exe", "/Change", "/TN", KEEPALIVE_TASK, action],
            capture_output=True, timeout=20, creationflags=CREATE_NO_WINDOW,
        )
        output = (decode_bytes(done.stdout) + decode_bytes(done.stderr)).strip()
        ok = done.returncode == 0
    except Exception as exc:  # noqa: BLE001
        output = str(exc)

    state = keepalive_state(force=True)
    if ok and state.get("enabled") != enabled:
        ok = False
        output = (output + "\n任务状态未按预期变化").strip()
    return {"ok": ok, "output": output, "state": state}

def last_eval():
    text = tail_text(LOGS / "llama-server.err.log")
    if not text:
        return None
    # (?<!prompt ) 避免把 "prompt eval time" 也当成生成速度
    items = re.findall(
        r"(?<!prompt )eval time\s*=\s*([\d.]+) ms /\s*(\d+) tokens.*?([\d.]+) tokens per second", text
    )
    prompt = re.findall(
        r"prompt eval time\s*=\s*([\d.]+) ms /\s*(\d+) tokens.*?([\d.]+) tokens per second", text
    )
    if not items:
        return None
    ms, tokens, tps = items[-1]
    result = {"ms": float(ms), "tokens": int(tokens), "tps": float(tps)}
    if prompt:
        result["prompt_tps"] = float(prompt[-1][2])
        result["prompt_tokens"] = int(prompt[-1][1])
    return result

def quant_of(name: str) -> str:
    """从文件名里猜量化格式，例如 Q4_K_M / Q5_K_S / IQ4_XS / F16。"""
    m = re.search(r"(IQ\d[A-Z_]*|Q\d[_A-Z0-9]*|F16|F32|BF16)", name, re.I)
    return m.group(1).upper() if m else ""


def scan_models(values: dict) -> dict:
    """扫描 models/ 目录（含子目录），列出所有 gguf 及它们是否已配置。"""
    models_dir = ROOT / "models"
    configured = {}
    for role, info in build_models(values).items():
        if info.get("path"):
            configured[str(Path(info["path"]).resolve()).lower()] = role
        # 投影只认「明确配置在本模型段里」的，避免 [model] mmproj 的默认值被所有角色认领
        mm_rel = ""
        if role == "base":
            mm_rel = cfg_get(values, "model", "mmproj", "")
        else:
            mm_rel = cfg_get(values, "gpu" if role == "base" else role, "mmproj", "")
        if mm_rel:
            try:
                configured[str(resolve_path(mm_rel).resolve()).lower()] = role + ":mmproj"
            except Exception:  # noqa: BLE001
                pass
    files = []
    if models_dir.is_dir():
        for item in sorted(models_dir.rglob("*.gguf"), key=lambda x: str(x).lower()):
            try:
                rel = str(item.relative_to(ROOT)).replace("\\", "/")
            except ValueError:
                rel = item.name
            low = item.name.lower()
            is_mm = ("mmproj" in low) or ("projector" in low) or (".mmproj." in low)
            files.append({
                "name": item.name,
                "rel": rel,
                "size": image_size(item),
                "mmproj": is_mm,
                "quant": quant_of(item.name),
                "family": "deepseek" if "deepseek" in low else ("qwen" if "qwen" in low else "other"),
                "configured_as": configured.get(str(item.resolve()).lower(), ""),
                "role_label": ROLE_LABEL.get(configured.get(str(item.resolve()).lower(), "").split(":")[0], ""),
            })
    return {
        "root": str(models_dir),
        "files": files,
        "slots": [{"role": r, "label": l} for r, l, _ in ROLES],
    }


def build_models(values: dict) -> dict:
    gpu_defaults = {
        "ngl": as_int(cfg_get(values, "gpu", "n_gpu_layers", "99"), 99),
        "ctx": as_int(cfg_get(values, "gpu", "ctx_size", "8192"), 8192),
        "ctk": cfg_get(values, "gpu", "cache_type_k", "q8_0"),
        "ctv": cfg_get(values, "gpu", "cache_type_v", "q8_0"),
    }
    prompts = load_prompts()
    names = load_names()
    vision_wanted = load_vision()

    # 视觉投影（mmproj）只对支持多模态的模型有意义，且必须真的存在投影文件

    models = {}
    for role, label, _switch in ROLES:
        section = "gpu" if role == "base" else role
        rel = cfg_get(values, "model", ROLE_FILE_KEY[role], "")
        path = resolve_path(rel) if rel else None
        low = rel.lower()
        # 注意顺序：DeepSeek-R1 的权重是 Qwen3 蒸馏，文件名里同时含 qwen，必须先判 deepseek
        family = "deepseek" if "deepseek" in low else ("qwen" if "qwen" in low else "other")
        mmproj_rel = cfg_get(values, section, "mmproj", cfg_get(values, "model", "mmproj", ""))
        mmproj_path = resolve_path(mmproj_rel) if mmproj_rel else None
        mmproj_ok = bool(mmproj_path and mmproj_path.exists())
        if family != "qwen":
            vision_ok, vision_reason = False, "该模型不支持视觉投影"
        elif not mmproj_ok:
            vision_ok, vision_reason = False, "缺少投影文件 " + mmproj_rel + "（放入后可开启）"
        else:
            vision_ok, vision_reason = True, "视觉可用（" + os.path.basename(mmproj_rel) + "）"
        models[role] = {
            "role": role,
            "system_prompt": prompts.get(role, ""),
            "display_name": names.get(role, ""),
            "vision_wanted": bool(vision_wanted.get(role, False)),
            "label": label,
            "file": rel,
            "path": str(path) if path else "",
            "exists": bool(path and path.exists()),
            "size": image_size(path) if path else 0,
            "alias": cfg_get(values, "server", ROLE_ALIAS_KEY[role], ""),
            "section": section,
            "ngl": as_int(cfg_get(values, section, "n_gpu_layers", gpu_defaults["ngl"]), gpu_defaults["ngl"]),
            "ctx": as_int(cfg_get(values, section, "ctx_size", gpu_defaults["ctx"]), gpu_defaults["ctx"]),
            "ctk": cfg_get(values, section, "cache_type_k", gpu_defaults["ctk"]),
            "ctv": cfg_get(values, section, "cache_type_v", gpu_defaults["ctv"]),
            "sampling": {k: cfg_get(values, section, k, cfg_get(values, "sampling", k, "")) for k in SAMPLING_KEYS},
            "max_tokens": as_int(cfg_get(values, section, "max_tokens", "4096"), 4096),
            "vision_ok": vision_ok,
            "vision_reason": vision_reason,
            "family": family,
            "mmproj": mmproj_rel,
        }
    return models

PROMPTS_FILE = DATA_DIR / "model-prompts.json"
NAMES_FILE = DATA_DIR / "model-names.json"
VISION_FILE = DATA_DIR / "model-vision.json"


def load_prompts() -> dict:
    try:
        data = json.loads(PROMPTS_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


def load_names() -> dict:
    try:
        data = json.loads(NAMES_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


def load_vision() -> dict:
    try:
        data = json.loads(VISION_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


def save_vision(role: str, on: bool) -> dict:
    roles = {r[0] for r in ROLES}
    if role not in roles:
        raise ValueError(f"未知模型：{role}")
    data = load_vision()
    data[role] = bool(on)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = VISION_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(VISION_FILE)
    return data


def save_name(role: str, name: str) -> dict:
    roles = {r[0] for r in ROLES}
    if role not in roles:
        raise ValueError(f"未知模型：{role}")
    data = load_names()
    name = (name or "").strip()
    if len(name) > 40:
        raise ValueError("显示名最多 40 个字符")
    if name:
        data[role] = name
    else:
        data.pop(role, None)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = NAMES_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(NAMES_FILE)
    return data


def save_prompt(role: str, text: str) -> dict:
    roles = {r[0] for r in ROLES}
    if role not in roles:
        raise ValueError(f"未知模型：{role}")
    data = load_prompts()
    text = (text or "").strip()
    if text:
        data[role] = text
    else:
        data.pop(role, None)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = PROMPTS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(PROMPTS_FILE)
    return data


def web_cfg(values: dict) -> dict:
    return {
        "enabled": cfg_get(values, "web", "enabled", "false").strip().lower() in ("true", "1", "yes", "on"),
        "engine": cfg_get(values, "web", "engine", "bing").strip().lower() or "bing",
        "fallback": cfg_get(values, "web", "fallback", "360").strip().lower(),
        "max_results": as_int(cfg_get(values, "web", "max_results", "5"), 5),
        "scan_pages": as_int(cfg_get(values, "web", "scan_pages", "3"), 3),
        "fetch_pages": as_int(cfg_get(values, "web", "fetch_pages", "2"), 2),
        "fetch_chars": as_int(cfg_get(values, "web", "fetch_chars", "1600"), 1600),
        "max_chars": as_int(cfg_get(values, "web", "max_chars", "8000"), 8000),
        "timeout": as_int(cfg_get(values, "web", "timeout", "15"), 15),
        "block_private": cfg_get(values, "web", "block_private", "true").strip().lower() in ("true", "1", "yes", "on"),
        "render": (cfg_get(values, "web", "render", "auto").strip().lower() or "auto"),
        "render_timeout": as_int(cfg_get(values, "web", "render_timeout", "45"), 45),
        "render_max_kb": as_int(cfg_get(values, "web", "render_max_kb", "4096"), 4096),
        "site_api": cfg_get(values, "web", "site_api", "true").strip().lower() in ("true", "1", "yes", "on"),
        "search_fallback": cfg_get(values, "web", "search_fallback", "true").strip().lower() in ("true", "1", "yes", "on"),
    }


def router_cfg(values: dict) -> dict:
    sel = cfg_get(values, "router", "roles", "base,deepseek")
    roles = [r.strip().lower() for r in sel.split(",") if r.strip()]
    roles = [r for r in roles if r in ROLE_FILE_KEY]
    return {
        "enabled": cfg_get(values, "router", "enabled", "false").strip().lower() in ("true", "1", "yes", "on"),
        "models_max": max(1, min(8, as_int(cfg_get(values, "router", "models_max", "2"), 2))),
        "roles": roles,
    }


def write_models_ini(values: dict, roles: list) -> str:
    """按选中的模型生成 router 预设文件（段名用 alias，保证和 /v1/models 的 id 一致）。"""
    out = [
        "; 由控制台自动生成 —— 不要手改，改控制台的「多模型」设置",
        "; 仅在 llama.conf.ini 里 [router] enabled = true 时生效",
        "",
    ]
    cap = max(2048, as_int(cfg_get(values, "router", "ctx_cap", "16384"), 16384))
    out.append(f"; 多模型时每个模型的上下文被压到 {cap}（[router] ctx_cap），否则显存放不下")
    out.append("")
    for role in roles:
        section = "gpu" if role == "base" else role
        key = ROLE_FILE_KEY.get(role, "model")
        alias = cfg_get(values, "server", ROLE_ALIAS_KEY.get(role, "alias"), role)
        rel = cfg_get(values, "model", key, "")
        if not rel:
            continue
        path = resolve_path(rel)
        def g(k, d=""):
            v = cfg_get(values, section, k, "")
            return v if v else cfg_get(values, "gpu", k, d)
        out.append(f"[{alias}]")
        out.append(f"model = {path}")
        try:
            ctx_val = min(int(g("ctx_size", "32768") or 32768), cap)
        except ValueError:
            ctx_val = cap
        out.append(f"ctx-size = {ctx_val}")
        out.append(f"n-gpu-layers = {g('n_gpu_layers', '99')}")
        ctk = g("cache_type_k", ""); ctv = g("cache_type_v", "")
        if ctk: out.append(f"cache-type-k = {ctk}")
        if ctv: out.append(f"cache-type-v = {ctv}")
        fa = g("flash_attn", "on")
        if fa in ("on", "off", "auto"): out.append(f"flash-attn = {fa}")
        mm = cfg_get(values, section, "mmproj", "")
        if mm and cfg_get(values, "vision", "enabled", "false").lower() == "true":
            out.append(f"mmproj = {resolve_path(mm)}")
        extra = cfg_get(values, section, "extra_args", "").strip()
        for tok in extra.split():
            if tok.startswith("--"):
                continue
        if extra:
            # extra_args 是命令行形式，转成 INI 的 key = value 需要成对；这里简化：
            # 只处理形如 --flag 或 --flag value 的串
            parts = extra.split()
            i = 0
            while i < len(parts):
                flag = parts[i]
                if flag.startswith("--"):
                    name = flag[2:]
                    val = "on"
                    if i + 1 < len(parts) and not parts[i + 1].startswith("--"):
                        val = parts[i + 1]
                        i += 1
                    out.append(f"{name} = {val}")
                i += 1
        out.append("")
    target = SCRIPTS / "models.ini"
    target.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
    return str(target)


def chat_cfg(values: dict) -> dict:
    threshold = cfg_get(values, "chat", "sum_threshold", "0.5")
    try:
        th = float(threshold)
    except ValueError:
        th = 0.5
    th = min(0.95, max(0.1, th))
    return {
        "summarize": cfg_get(values, "chat", "summarize", "true").strip().lower() in ("true", "1", "yes", "on"),
        "sum_threshold": th,
        "sum_keep": max(1, min(50, as_int(cfg_get(values, "chat", "sum_keep", "4"), 4))),
    }


def tools_state() -> dict:
    values = parse_conf()
    local_tools.set_web_config(web_cfg(values))
    level = cfg_get(values, "tools", "level", "off").strip().lower()
    if level not in local_tools.LEVELS:
        level = "off"
    workspace = cfg_get(values, "tools", "workspace", "") or str(ROOT / "workspace")
    rounds = as_int(cfg_get(values, "tools", "max_rounds", "8"), 8)
    ceiling = cfg_get(values, "tools", "ceiling", "full").strip().lower()
    if ceiling not in local_tools.LEVELS:
        ceiling = "full"
    return {
        "level": level,
        "web": web_cfg(parse_conf()),
        "ceiling": ceiling,
        "levels": [
            {"id": "off", "label": "关闭"},
            {"id": "read", "label": "只读"},
            {"id": "write", "label": "工作区可写"},
            {"id": "full", "label": "完全访问"},
        ],
        "workspace": workspace,
        "max_rounds": rounds,
        "tools": local_tools.catalog(level),
    }


def apply_tool_config(payload: dict) -> dict:
    level = str(payload.get("level") or "off").strip().lower()
    if level not in local_tools.LEVELS:
        raise ValueError("level 只能是 off / read / write / full")
    updates = {"tools": {"level": level}}
    ws = str(payload.get("workspace") or "").strip()
    if ws:
        target = Path(ws).expanduser()
        if not target.is_absolute():
            raise ValueError(f"工作区必须是绝对路径：{ws}")
        if not target.is_dir():
            # 工作区本来就是「用来放文件的目录」，不存在就建出来，别为难用户
            try:
                target.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                raise ValueError(f"无法创建工作区目录 {target}：{exc}") from exc
        updates["tools"]["workspace"] = str(target)
    update_conf(updates)
    return tools_state()


def exec_tool(payload: dict) -> dict:
    name = str(payload.get("name") or "")
    args = payload.get("args") or {}
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except Exception:
            raise ValueError("args 不是合法 JSON")
    st = tools_state()
    local_tools.set_web_config(web_cfg(parse_conf()))
    level = str(payload.get("level") or st["level"]).strip().lower()
    if level not in local_tools.LEVELS:
        raise ValueError("level 非法")
    if local_tools.LEVELS[level] > local_tools.LEVELS[st["ceiling"]]:
        raise ValueError(f"超出本机允许的上限（{st['ceiling']}）")
    result = local_tools.run(name, args, level, st["workspace"])
    log(f"tool {name} level={level} ceiling={st['ceiling']} ok={result.get('ok')}")
    return result


def build_state() -> dict:
    values = parse_conf()
    if not values:
        raise FileNotFoundError(f"找不到配置文件: {CONF}")

    port = server_port(values)
    alive = health(port)
    loaded = loaded_model(port) if alive else None

    pid = 0
    try:
        pid = int(PID_FILE.read_text(encoding="utf-8-sig").strip())
    except (OSError, ValueError):
        pid = 0

    uptime = 0
    try:
        uptime = int(time.time() - PID_FILE.stat().st_mtime)
    except OSError:
        pass

    models_all = build_models(values)
    # 只把磁盘上真实存在的模型给前端。配置里保留的槽位（比如还没下载的
    # Uncensored / DeepSeek）不会在控制台出现空卡片，文件放下后自动回来。
    models = {role: info for role, info in models_all.items() if info["exists"]}
    active = cfg_get(values, "models", "active", "base").lower()
    if models and active not in models:
        active = next(iter(models))

    roles = {m["path"] for m in models_all.values() if m["path"]}
    others = []
    models_dir = ROOT / "models"
    if models_dir.is_dir():
        for item in sorted(models_dir.glob("*.gguf")):
            if str(item) in roles:
                continue
            others.append({"name": item.name, "size": image_size(item)})

    return {
        "root": str(ROOT),
        "conf": str(CONF),
        "chat": chat_cfg(values),
        "router": router_cfg(values),
        "web": web_cfg(values),

        "server": {
            "host": cfg_get(values, "server", "host", "127.0.0.1"),
            "port": port,
            "base": f"http://127.0.0.1:{port}",
        },
        "running": alive,
        "pid": pid,
        "pid_alive": pid_alive(pid),
        "uptime": uptime,
        "loaded": loaded,
        "gpu": gpu_info(),
        "memory": memory_info(pid),
        "active": active,
        "models": models,
        "other_files": others,
        "settings": {
            "threads": as_int(cfg_get(values, "server", "threads", "8"), 8),
            "parallel": as_int(cfg_get(values, "server", "parallel", "1"), 1),
            "flash_attn": cfg_get(values, "gpu", "flash_attn", "on").lower() in ("on", "true", "1", "yes"),
            "vision": cfg_get(values, "vision", "enabled", "false").lower() == "true",
        },
        "job": JOB.snapshot(),
        "last_eval": last_eval(),
        "keepalive": keepalive_state(),
        "cache_types": sorted(CACHE_TYPES),
        "sampling": {k: cfg_get(values, "sampling", k, "") for k in SAMPLING_KEYS},
    }

# --------------------------------------------------------------------------
# 后台任务（启动/重启 llama-server）
# --------------------------------------------------------------------------
class JobRunner:
    def __init__(self):
        self._lock = threading.Lock()
        self._reset()

    def _reset(self):
        self.running = False
        self.kind = None
        self.started = 0.0
        self.finished = 0.0
        self.output: list[str] = []
        self.ok = None
        self.code = None

    def start(self, kind: str, args: list[str]) -> bool:
        with self._lock:
            if self.running:
                return False
            self._reset()
            self.running = True
            self.kind = kind
            self.started = time.time()
        threading.Thread(target=self._run, args=(args,), daemon=True).start()
        return True

    def _append(self, line: str) -> None:
        with self._lock:
            self.output.append(line)
            if len(self.output) > 400:
                del self.output[:100]

    def _run(self, args: list[str]) -> None:
        command = [
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", str(LAUNCHER), *args,
        ]
        # 输出重定向到文件而不是管道：llama-server 是 Start-Process 拉起的
        # 孙进程，会继承 stdout 句柄，用 PIPE 时父进程退出后 read() 永远等不到
        # EOF（实测任务卡死 3 分钟以上）。文件轮询没有这个继承问题。
        out_file = PANEL_DIR / ".job-output.log"
        try:
            out_file.unlink(missing_ok=True)
        except OSError:
            pass

        try:
            with open(out_file, "wb") as handle:
                proc = subprocess.Popen(
                    command, cwd=str(SCRIPTS),
                    stdout=handle, stderr=subprocess.STDOUT,
                    creationflags=CREATE_NO_WINDOW,
                )
        except Exception as exc:  # noqa: BLE001
            self._append(f"[panel] 启动失败: {exc}")
            with self._lock:
                self.running = False
                self.ok = False
                self.finished = time.time()
            return

        pos = 0
        buffer = ""
        deadline = time.time() + JOB_TIMEOUT
        code = None

        def drain() -> None:
            nonlocal pos, buffer
            try:
                with open(out_file, "rb") as handle:
                    handle.seek(pos)
                    chunk = handle.read()
                    pos = handle.tell()
            except OSError:
                return
            if not chunk:
                return
            buffer += decode_bytes(chunk)
            parts = buffer.split("\n")
            buffer = parts.pop()
            for line in parts:
                self._append(line.rstrip("\r"))

        while True:
            time.sleep(0.4)
            drain()
            code = proc.poll()
            if code is not None:
                time.sleep(0.2)
                drain()
                if buffer.strip():
                    self._append(buffer.strip())
                    buffer = ""
                break
            if time.time() > deadline:
                proc.kill()
                code = -1
                self._append("[panel] 超时，已终止启动进程")
                break

        try:
            out_file.unlink(missing_ok=True)
        except OSError:
            pass
        with self._lock:
            self.running = False
            self.code = code
            self.ok = code == 0
            self.finished = time.time()

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "running": self.running,
                "kind": self.kind,
                "started": self.started,
                "finished": self.finished,
                "ok": self.ok,
                "code": self.code,
                "elapsed": round((time.time() if self.running else self.finished) - self.started, 1)
                if self.started else 0,
                "output": self.output[-40:],
            }

JOB = JobRunner()

def run_script_blocking(args: list[str], timeout: int = 90):
    command = [
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(LAUNCHER), *args,
    ]
    try:
        done = subprocess.run(
            command, cwd=str(SCRIPTS), capture_output=True,
            timeout=timeout, creationflags=CREATE_NO_WINDOW,
        )
        text = decode_bytes(done.stdout) + decode_bytes(done.stderr)
        return done.returncode, text.strip()
    except subprocess.TimeoutExpired:
        return 1, "操作超时"
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)

# --------------------------------------------------------------------------
# HTTP 服务
# --------------------------------------------------------------------------
PANEL_PORT = 8090
SERVER: ThreadingHTTPServer | None = None

class Handler(BaseHTTPRequestHandler):
    server_version = "llama-panel/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 安静一点
        return

    # ---- 输出 ----
    def _send(self, status: int, body: bytes, content_type: str):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, payload, status: int = 200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _error(self, message: str, status: int = 400):
        self._json({"error": message}, status)

    # ---- 路由 ----
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path in ("/", "/index.html"):
            try:
                body = UI_FILE.read_bytes()
            except OSError:
                return self._error("ui.html 缺失", 500)
            return self._send(200, body, "text/html; charset=utf-8")
        if path in ("/chat", "/chat.html"):
            try:
                body = (ROOT / "web" / "chat.html").read_bytes()
            except OSError:
                return self._error("web\\chat.html 缺失", 500)
            return self._send(200, body, "text/html; charset=utf-8")
        if path == "/favicon.ico":
            return self._send(204, b"", "image/x-icon")

        try:
            if path == "/api/state":
                return self._json(build_state())
            if path == "/api/job":
                return self._json(JOB.snapshot())
            if path == "/api/logs":
                which = (query.get("file") or ["err"])[0]
                lines = max(20, min(1000, as_int((query.get("lines") or ["240"])[0], 240)))
                mapping = {
                    "err": LOGS / "llama-server.err.log",
                    "server": LOGS / "llama-server.log",
                    "guard": LOGS / "guard.log",
                }
                target = mapping.get(which, mapping["err"])
                text = tail_text(target)
                tail = text.splitlines()[-lines:]
                return self._json({"file": str(target), "exists": target.exists(), "lines": tail})
            if path == "/api/sessions":
                data = load_sessions()
                if data is None:
                    return self._json({"exists": False, "data": None, "file": str(SESS_FILE)})
                return self._json({"exists": True, "data": data, "file": str(SESS_FILE)})
            if path == "/api/models/scan":
                return self._json(scan_models(parse_conf()))
            if path == "/api/skins":
                target = SKIN_DIR / "skins.json"
                if not target.exists():
                    return self._json({"version": 0, "default": "night", "models": {}, "skins": {}})
                try:
                    return self._json(json.loads(target.read_text(encoding="utf-8")))
                except ValueError as exc:
                    return self._error(f"skins.json 解析失败: {exc}", 500)
            if path.startswith("/vendor/"):
                rel = urllib.parse.unquote(path[len("/vendor/"):])
                try:
                    target = vendor_file(rel)
                except PermissionError as exc:
                    return self._error(str(exc), 403)
                if not target.is_file():
                    return self._error("not found", 404)
                ctype = VENDOR_MIME.get(target.suffix.lower(), "application/octet-stream")
                return self._send(200, target.read_bytes(), ctype)
            if path.startswith("/skins/"):
                rel = urllib.parse.unquote(path[len("/skins/"):])
                try:
                    target = skin_file(rel)
                except PermissionError as exc:
                    return self._error(str(exc), 403)
                if not target.is_file():
                    return self._error("not found", 404)
                ctype = SKIN_MIME.get(target.suffix.lower(), "application/octet-stream")
                return self._send(200, target.read_bytes(), ctype)
            if path == "/api/tools":
                return self._json(tools_state())
            if path == "/api/fs":
                target = (query.get("path") or [""])[0]
                try:
                    return self._json(fs_list(target))
                except Exception as exc:  # noqa: BLE001
                    return self._json({"path": target, "entries": [], "roots": [], "error": str(exc)}, 400)
            return self._error("not found", 404)
        except FileNotFoundError as exc:
            return self._error(str(exc), 500)
        except Exception as exc:  # noqa: BLE001
            return self._error(f"{type(exc).__name__}: {exc}", 500)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        origin = self.headers.get("Origin")
        allowed = {f"http://127.0.0.1:{PANEL_PORT}", f"http://localhost:{PANEL_PORT}"}
        if origin and origin not in allowed:
            return self._error("origin not allowed", 403)

        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                return self._error("body too large", 413)
            payload = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except Exception:  # noqa: BLE001
            return self._error("invalid json", 400)

        try:
            if path == "/api/open-app":
                exe = str(APP_EXE)
                if not APP_EXE.exists():
                    return self._error("找不到 chat-app\\llama-chat.exe", 500)
                try:
                    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq llama-chat.exe", "/NH"],
                                         capture_output=True, timeout=8, creationflags=CREATE_NO_WINDOW)
                    running = b"llama-chat.exe" in (out.stdout or b"")
                except Exception:
                    running = False
                if not running:
                    subprocess.Popen([exe], cwd=str(APP_EXE.parent), close_fds=True)
                return self._json({"ok": True, "started": not running, "file": exe})
            if path == "/api/sessions":
                if not isinstance(payload, dict) or not isinstance(payload.get("workspaces"), list):
                    return self._error("会话数据格式不对：需要 {workspaces: [...]}", 400)
                size = save_sessions(payload)
                return self._json({"ok": True, "bytes": size, "file": str(SESS_FILE)})
            if path == "/api/reveal":
                raw = str(payload.get("path") or "").strip()
                if not raw:
                    return self._error("缺少 path", 400)
                target = Path(raw)
                if not target.is_file():
                    return self._error("文件不存在：" + raw, 404)
                st = tools_state()
                try:
                    target.resolve().relative_to(Path(st["workspace"]).resolve())
                except Exception:  # noqa: BLE001
                    return self._error("只允许打开工作区内的文件", 403)
                try:
                    subprocess.Popen(["explorer.exe", "/select," + str(target)], close_fds=True)
                except Exception as exc:  # noqa: BLE001
                    return self._error(f"打开资源管理器失败：{exc}", 500)
                log(f"reveal {target}")
                return self._json({"ok": True, "path": str(target)})
            if path == "/api/models/scan":
                return self._json(scan_models(parse_conf()))
            if path == "/api/models/assign":
                role = str(payload.get("role") or "").strip().lower()
                rel = str(payload.get("rel") or "").strip()
                mm_rel = str(payload.get("mmproj") or "").strip()
                if role not in ROLE_FILE_KEY:
                    return self._error(f"未知模型槽位：{role}", 400)
                if not rel and not mm_rel:
                    return self._error("缺少文件", 400)
                updates = {}
                if rel:
                    target = resolve_path(rel)
                    if not target.exists() or target.suffix.lower() != ".gguf":
                        return self._error("文件不存在或不是 .gguf：" + rel, 400)
                    if "mmproj" in target.name.lower() or "projector" in target.name.lower():
                        return self._error("这是视觉投影文件，不能当主模型", 400)
                    updates["model"] = {ROLE_FILE_KEY[role]: rel.replace("/", "\\")}
                if mm_rel:
                    mm_target = resolve_path(mm_rel)
                    if not mm_target.exists():
                        return self._error("投影文件不存在：" + mm_rel, 400)
                    section = "gpu" if role == "base" else role
                    updates[section] = dict(updates.get(section) or {})
                    updates[section]["mmproj"] = mm_rel.replace("/", "\\")
                backup_conf()
                update_conf(updates)
                log(f"model assigned: {role} <- {rel}")
                return self._json({"ok": True, "scan": scan_models(parse_conf())})
            if path == "/api/router/load":
                values = parse_conf()
                port = server_port(values)
                model = str(payload.get("model") or "").strip()
                action = str(payload.get("action") or "load").strip().lower()
                if not model:
                    return self._error("缺少模型名", 400)
                if not health(port):
                    return self._error("llama-server 未运行", 409)
                route = "/models/unload" if action == "unload" else "/models/load"
                try:
                    res = http_json(f"http://127.0.0.1:{port}{route}", 600, {"model": model})
                except Exception as exc:  # noqa: BLE001
                    return self._error(f"{action} 失败：{exc}", 500)
                return self._json({"ok": True, "result": res})
            if path == "/api/router":
                roles = payload.get("roles")
                updates = {"router": {}}
                if "enabled" in payload:
                    updates["router"]["enabled"] = "true" if payload.get("enabled") else "false"
                if "models_max" in payload:
                    updates["router"]["models_max"] = str(max(1, min(8, as_int(payload.get("models_max"), 2))))
                if isinstance(roles, list):
                    clean = [str(r).strip().lower() for r in roles if str(r).strip().lower() in ROLE_FILE_KEY]
                    updates["router"]["roles"] = ",".join(clean) or "base"
                if updates["router"]:
                    update_conf(updates)
                cfg = router_cfg(parse_conf())
                if not payload.get("skip_preset"):
                    write_models_ini(parse_conf(), cfg["roles"])
                return self._json(cfg)
            if path == "/api/chat/config":
                updates = {"chat": {}}
                if "summarize" in payload:
                    updates["chat"]["summarize"] = "true" if payload.get("summarize") else "false"
                if "sum_threshold" in payload:
                    try:
                        th = float(payload.get("sum_threshold"))
                    except (TypeError, ValueError):
                        return self._error("sum_threshold 必须是数字", 400)
                    updates["chat"]["sum_threshold"] = f"{min(0.95, max(0.1, th)):.2f}"
                if "sum_keep" in payload:
                    updates["chat"]["sum_keep"] = str(max(1, min(50, as_int(payload.get("sum_keep"), 4))))
                if updates["chat"]:
                    update_conf(updates)
                return self._json(chat_cfg(parse_conf()))
            if path == "/api/web/config":
                updates = {"web": {}}
                if "enabled" in payload:
                    updates["web"]["enabled"] = "true" if payload.get("enabled") else "false"
                for key in ("engine", "max_results", "max_chars", "timeout", "block_private",
                            "render", "render_timeout", "render_max_kb", "site_api", "search_fallback"):
                    if key in payload:
                        val = payload[key]
                        if key in ("block_private", "site_api", "search_fallback"):
                            val = "true" if val else "false"
                        updates["web"][key] = str(val)
                if updates["web"]:
                    update_conf(updates)
                local_tools.set_web_config(web_cfg(parse_conf()))
                local_tools.clear_search_cache()
                return self._json(web_cfg(parse_conf()))
            if path == "/api/model-name":
                role = str(payload.get("role") or "").strip().lower()
                try:
                    data = save_name(role, str(payload.get("name") or ""))
                except ValueError as exc:
                    return self._error(str(exc), 400)
                log(f"model display name saved for {role}")
                return self._json({"ok": True, "names": data})
            if path == "/api/model-prompt":
                role = str(payload.get("role") or "").strip().lower()
                try:
                    data = save_prompt(role, str(payload.get("text") or ""))
                except ValueError as exc:
                    return self._error(str(exc), 400)
                log(f"model prompt saved for {role}")
                return self._json({"ok": True, "prompts": data})
            if path == "/api/tools/config":
                try:
                    return self._json(apply_tool_config(payload))
                except ValueError as exc:
                    return self._error(str(exc), 400)
            if path == "/api/tools/exec":
                try:
                    return self._json(exec_tool(payload))
                except ValueError as exc:
                    return self._error(str(exc), 400)
            if path == "/api/apply":
                return self._apply(payload)
            if path == "/api/restart":
                if JOB.snapshot()["running"]:
                    return self._error("已有操作在进行中", 409)
                JOB.start("restart", [])
                return self._json({"ok": True, "job": JOB.snapshot()}, 202)
            if path == "/api/stop":
                code, text = run_script_blocking(["-Stop"], timeout=60)
                return self._json({"ok": code == 0, "output": text, "code": code})
            if path == "/api/test":
                return self._test(payload)
            if path == "/api/keepalive":
                return self._keepalive(payload)
            if path == "/api/quit":
                self._json({"ok": True})
                threading.Timer(0.3, shutdown).start()
                return
            return self._error("not found", 404)
        except Exception as exc:  # noqa: BLE001
            return self._error(f"{type(exc).__name__}: {exc}", 500)

    # ---- 业务 ----
    def _apply(self, payload: dict):
        if JOB.snapshot()["running"]:
            return self._error("已有操作在进行中，请稍候", 409)

        values = parse_conf()
        role = str(payload.get("model") or cfg_get(values, "models", "active", "base")).lower()
        if role not in ROLE_SWITCH:
            return self._error(f"未知模型: {role}")

        section = "gpu" if role == "base" else role
        ngl = as_int(payload.get("ngl"), -1)
        ctx = as_int(payload.get("ctx"), -1)
        threads = as_int(payload.get("threads"), -1)
        parallel = as_int(payload.get("parallel"), -1)
        ctk = str(payload.get("ctk") or "").lower()
        ctv = str(payload.get("ctv") or "").lower()
        fa = bool(payload.get("flash_attn"))
        vision = bool(payload.get("vision"))   # 家族过滤在下面统一处理

        if not 0 <= ngl <= 256:
            return self._error("-ngl 需在 0..256 之间")
        if not 512 <= ctx <= 1048576:
            return self._error("上下文需在 512..1048576 之间")
        if not 1 <= threads <= 64:
            return self._error("线程数需在 1..64 之间")
        if not 1 <= parallel <= 16:
            return self._error("并发槽需在 1..16 之间")
        if ctk not in CACHE_TYPES or ctv not in CACHE_TYPES:
            return self._error("KV cache 类型不支持")

        updates = {
            section: {
                "n_gpu_layers": str(ngl),
                "ctx_size": str(ctx),
                "cache_type_k": ctk,
                "cache_type_v": ctv,
            },
            "server": {"threads": str(threads), "parallel": str(parallel)},
            "vision": {"enabled": "true" if vision else "false"},
        }
        # 记住这个模型对视觉投影的意愿（换模型再切回来时恢复）
        try:
            save_vision(role, vision)
        except ValueError:
            pass
        model_rel = cfg_get(values, "model", ROLE_FILE_KEY.get(role, ""), "").lower()
        if not ("qwen" in model_rel and "deepseek" not in model_rel):
            # 非 Qwen 家族没有对应的视觉投影，强制关闭
            updates["vision"]["enabled"] = "false"

        sampling = {}
        for key in SAMPLING_KEYS:
            raw = payload.get(key)
            if raw in (None, ""):
                continue
            text = str(raw).strip()
            try:
                float(text)
            except ValueError:
                return self._error(f"采样参数 {key} 不是数字：{text}")
            sampling[key] = text
        if "temp" in sampling and not 0.0 <= float(sampling["temp"]) <= 2.0:
            return self._error("temperature 需在 0..2 之间")
        if "top_p" in sampling and not 0.0 <= float(sampling["top_p"]) <= 1.0:
            return self._error("top_p 需在 0..1 之间")
        if "top_k" in sampling and not 0 <= int(float(sampling["top_k"])) <= 256:
            return self._error("top_k 需在 0..256 之间")
        if "repeat_last_n" in sampling and not 0 <= int(float(sampling["repeat_last_n"])) <= 8192:
            return self._error("repeat_last_n 需在 0..8192 之间")
        if sampling:
            # 写进该模型自己的段，互不影响
            updates.setdefault(section, {}).update(sampling)

        max_tokens = as_int(payload.get("max_tokens"), -1)
        if max_tokens >= 0:
            if not 16 <= max_tokens <= 32768:
                return self._error("max_tokens 需在 16..32768 之间")
            updates.setdefault(section, {})["max_tokens"] = str(max_tokens)

        backup_conf()
        update_conf(updates)
        # 多模型模式下真正生效的是 preset，改完参数要同步重新生成
        try:
            if router_cfg(parse_conf())["enabled"]:
                write_models_ini(parse_conf(), router_cfg(parse_conf())["roles"])
        except Exception:  # noqa: BLE001
            pass
        if not JOB.start("apply", [ROLE_SWITCH[role]]):
            return self._error("启动任务失败", 409)
        return self._json({"ok": True, "written": updates, "job": JOB.snapshot()}, 202)

    def _keepalive(self, payload: dict):
        if "enabled" not in payload:
            return self._error("缺少 enabled 参数")
        result = set_keepalive(bool(payload.get("enabled")))
        return self._json(result)

    def _test(self, payload: dict):
        values = parse_conf()
        port = server_port(values)
        if not health(port):
            return self._error("llama-server 未运行", 409)
        loaded = loaded_model(port)
        if not loaded or not loaded.get("id"):
            return self._error("拿不到已加载模型", 409)

        prompt = str(payload.get("prompt") or "用一句话介绍你自己。")[:2000]
        max_tokens = max(8, min(512, as_int(payload.get("max_tokens"), 64)))
        started = time.time()
        try:
            result = http_json(
                f"http://127.0.0.1:{port}/v1/chat/completions",
                timeout=300,
                payload={
                    "model": loaded["id"],
                    "messages": [{"role": "user", "content": prompt}],
                    "max_tokens": max_tokens,
                    "temperature": 0.2,
                    "stream": False,
                },
            )
        except Exception as exc:  # noqa: BLE001
            return self._error(f"请求失败: {exc}", 502)

        elapsed = time.time() - started
        usage = result.get("usage") or {}
        timings = result.get("timings") or {}
        completion = usage.get("completion_tokens") or 0
        content = ""
        try:
            message = result["choices"][0]["message"]
            content = message.get("content") or ""
            if not content.strip():
                # R1 这类推理模型在 max_tokens 较小时，正文可能为空，
                # 内容全在 reasoning_content（思考过程）里。
                reasoning = message.get("reasoning_content") or message.get("reasoning") or ""
                if reasoning.strip():
                    content = "（思考过程）" + reasoning.strip()
        except (KeyError, IndexError, TypeError):
            pass
        return self._json({
            "ok": True,
            "model": loaded["id"],
            "elapsed_ms": round(elapsed * 1000),
            "completion_tokens": completion,
            "prompt_tokens": usage.get("prompt_tokens"),
            "tps": round(timings.get("predicted_per_second") or (completion / elapsed if elapsed else 0), 1),
            "prompt_tps": round(timings.get("prompt_per_second") or 0, 1) or None,
            "text": content[:400],
        })

def shutdown():
    global SERVER
    if SERVER:
        SERVER.shutdown()

def main():
    global PANEL_PORT, SERVER
    parser = argparse.ArgumentParser(description="llama.cpp 控制台")
    parser.add_argument("--port", type=int, default=int(os.environ.get("LLAMA_PANEL_PORT", "8090")))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--open", action="store_true", help="启动后自动打开浏览器；已在运行则只打开浏览器")
    args = parser.parse_args()

    PANEL_PORT = args.port
    url = f"http://{args.host}:{PANEL_PORT}"

    if not CONF.exists():
        return fatal(f"找不到配置文件：\n{CONF}")
    if not LAUNCHER.exists():
        log(f"警告: 找不到 {LAUNCHER}，启动/重启会失败")

    # 单实例：已经有一个面板在跑，就只把浏览器叫出来。
    if panel_running(args.host, PANEL_PORT):
        log(f"面板已在运行: {url}")
        if args.open:
            open_browser(url)
        return 0

    try:
        httpd = ThreadingHTTPServer((args.host, PANEL_PORT), Handler)
    except OSError as exc:
        return fatal(
            f"端口 {PANEL_PORT} 无法监听：{exc}\n"
            f"可能被其他程序占用；可用 --port 换一个端口。"
        )

    httpd.daemon_threads = True
    SERVER = httpd
    log(f"配置: {CONF}")
    log(f"服务: {url}")
    log("Ctrl+C 停止")
    if args.open:
        threading.Timer(0.6, lambda: open_browser(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0

if __name__ == "__main__":
    sys.exit(main())

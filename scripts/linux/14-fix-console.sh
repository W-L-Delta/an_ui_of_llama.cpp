#!/usr/bin/env bash
# ============================================================
#  14-fix-console.sh —— 修「打不开控制台」与「工作区路径不存在」
#
#  已知原因（配置里挖出来的）：
#      [tools] workspace = D:\llama工作区
#  这是 Windows 路径，Linux 上不存在，所以控制台选文件夹会报「路径不存在」。
#
#  这个脚本：
#    1. 打印两个 unit 状态 + 面板日志（看控制台到底为什么打不开）
#    2. 逐个探测 HTTP：/  /chat  /api/state  /api/tools  /api/fs
#    3. 把配置里所有 Windows 绝对路径改成 Linux 路径，并建好目录
#    4. 重启面板，再测一遍
# ============================================================
set -u
DEST="$HOME/llama-ui"
CONF="$DEST/scripts/llama.conf.ini"
WORK="$HOME/llama-work"
LOGW="$HOME/llama-work"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 服务状态"
for u in llama-server llama-panel; do
  printf "  %-13s %s / %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)" "$(systemctl is-enabled $u 2>/dev/null)"
done

say "2. 面板日志（最后 30 行）"
journalctl -u llama-panel -n 30 --no-pager 2>/dev/null | sed 's/^/  /' || echo "  取不到日志"

say "3. HTTP 探测"
python3 - <<'PY'
import urllib.request, json
tests = [
    ("控制台首页 /", "http://127.0.0.1:8090/"),
    ("聊天页 /chat", "http://127.0.0.1:8090/chat"),
    ("/api/state", "http://127.0.0.1:8090/api/state"),
    ("/api/tools", "http://127.0.0.1:8090/api/tools"),
    ("/api/fs?path=~", "http://127.0.0.1:8090/api/fs?path=~"),
    ("llama /health", "http://127.0.0.1:8080/health"),
]
for name, url in tests:
    try:
        with urllib.request.urlopen(url, timeout=6) as r:
            body = r.read()
        info = f"{r.status}  {len(body)} 字节"
        if name.endswith("/api/tools") or name == "/api/state":
            try:
                d = json.loads(body.decode())
                info += "  键: " + ",".join(list(d.keys())[:8])
            except Exception:
                pass
        print(f"  {name:18s} OK  {info}")
    except Exception as e:
        print(f"  {name:18s} 失败: {e}")
PY

say "4. 配置里的 Windows 绝对路径"
grep -nE '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*[A-Za-z]:[\\/]' "$CONF" 2>/dev/null | sed 's/^/  /' || echo "  没有"

say "5. 改写为 Linux 路径"
mkdir -p "$WORK"
python3 - "$CONF" "$WORK" "$HOME" <<'PY'
import re, sys, pathlib

conf = pathlib.Path(sys.argv[1])
work = sys.argv[2]
home = sys.argv[3]
win_models = home + "/WinD/llama.cpp/models"

text = conf.read_text(encoding="utf-8")
changed = 0

out_lines = []
for line in text.splitlines():
    m = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(.+?)\s*$", line)
    if m and not line.lstrip().startswith(("#", ";")):
        key, val = m.group(2), m.group(4).strip()
        if re.match(r"^[A-Za-z]:[\\/]", val):
            norm = val.replace("\\", "/")
            if "工作区" in norm or norm.lower().endswith("workspace"):
                new = work
            elif norm.lower().startswith(("d:/llama.cpp", "d:/llamacpp")):
                new = home + "/WinD" + norm[2:]
            elif "/models/" in norm.lower():
                new = win_models + "/" + norm.split("/models/", 1)[1]
            else:
                new = work
            line = f"{m.group(1)}{key} = {new}"
            changed += 1
    out_lines.append(line)
conf.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
print(f"  改写 {changed} 处")
PY
echo "  工作区目录: $WORK"
grep -nE '^\s*(workspace|model|mmproj)\s*=' "$CONF" | head -6 | sed 's/^/  /'

say "6. 重启面板并复测"
sudo systemctl restart llama-panel
sleep 4
python3 - <<'PY'
import urllib.request, json, os
for name, url in (("控制台 /", "http://127.0.0.1:8090/"),
                  ("/api/state", "http://127.0.0.1:8090/api/state"),
                  ("/api/fs?path=~", "http://127.0.0.1:8090/api/fs?path=~")):
    try:
        with urllib.request.urlopen(url, timeout=6) as r:
            b = r.read()
        extra = ""
        if name == "/api/state":
            d = json.loads(b.decode())
            extra = f"  running={d.get('running')}  workspace={d.get('workspace')}"
        print(f"  {name:16s} OK  {len(b)} 字节{extra}")
    except Exception as e:
        print(f"  {name:16s} 失败: {e}")
try:
    with urllib.request.urlopen("http://127.0.0.1:8090/api/state", timeout=6) as r:
        d = json.loads(r.read().decode())
    ws = d.get("workspace")
    print(f"  工作区配置: {ws}   存在: {os.path.isdir(ws) if ws else False}")
except Exception:
    pass
PY

say "7. 面板日志（重启后的最后 15 行）"
journalctl -u llama-panel -n 15 --no-pager 2>/dev/null | sed 's/^/  /' || true

say "完成"
cat <<EOT
  若控制台仍然打不开，把这行结果发我：
      journalctl -u llama-panel -n 50 --no-pager | tail -30

  工作区已改成: $WORK
  在控制台里可以再改成任意存在的目录。
EOT

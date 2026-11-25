#!/usr/bin/env bash
# ============================================================
#  16-apply-ui-patch.sh —— 更新面板与聊天页（修控制台按钮 + 工作区选择）
#
#  两个真实原因：
#    1. chat.html 里「打开控制台」在没有 WebView2 时只弹一句
#       「控制台只能在程序内打开」，然后什么都不做。
#       -> 改成：非 WebView2 环境直接跳到 /（控制台首页）
#    2. 工作区：/api/fs 遇到不存在的路径（比如残留的 D:\llama工作区）直接报
#       「路径不存在」；保存时目录不存在也直接报错。
#       -> 改成：列目录时回落到 home；保存时自动 mkdir -p
#
#  这个脚本把 ~/llama-ui 里的 app.py / ui.html / chat.html 换成新版，
#  同步配置里的 Windows 路径，然后重启面板并验证。
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
WORK="$HOME/llama-work"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 检查更新包"
for f in panel/app.py panel/ui.html web/chat.html; do
  if [ -f "$PKG/$f" ]; then printf "  [OK]   %s\n" "$f"; else printf "  [缺失] %s\n" "$f"; exit 1; fi
done

say "2. 备份并替换"
mkdir -p "$DEST/panel" "$DEST/web"
for f in panel/app.py panel/ui.html web/chat.html; do
  cp -f "$DEST/$f" "$DEST/$f.bak.$(date +%s)" 2>/dev/null || true
  cp -f "$PKG/$f" "$DEST/$f"
  echo "  更新 $f"
done

say "3. 修工作区路径"
mkdir -p "$WORK"
CONF="$DEST/scripts/llama.conf.ini"
python3 - "$CONF" "$WORK" "$HOME" <<'PY'
import re, sys, pathlib
conf = pathlib.Path(sys.argv[1]); work = sys.argv[2]; home = sys.argv[3]
if not conf.exists():
    print("  配置不存在，跳过"); raise SystemExit(0)
lines, changed = [], 0
for line in conf.read_text(encoding="utf-8").splitlines():
    m = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(.+?)\s*$", line)
    if m and not line.lstrip().startswith(("#", ";")):
        key, val = m.group(2), m.group(4).strip()
        if re.match(r"^[A-Za-z]:[\\/]", val):
            norm = val.replace("\\", "/")
            if key == "workspace" or "工作区" in norm:
                new = work
            elif norm.lower().startswith("d:/llama.cpp"):
                new = home + "/WinD" + norm[2:]
            elif "/models/" in norm.lower():
                new = home + "/WinD/llama.cpp/models/" + norm.split("/models/", 1)[1]
            else:
                new = work
            line = f"{m.group(1)}{key} = {new}"
            changed += 1
    lines.append(line)
conf.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"  改写 {changed} 处 Windows 路径")
PY
grep -nE '^\s*workspace\s*=' "$CONF" | sed 's/^/  /' || echo "  （配置里没有 workspace，面板会用默认 $DEST/workspace）"

say "4. 重启面板"
sudo systemctl restart llama-panel
sleep 4

say "5. 验证"
python3 - "$HOME" <<'PY'
import json, os, sys, urllib.request, urllib.parse
home = sys.argv[1]
def get(url):
    with urllib.request.urlopen(url, timeout=6) as r:
        return r.status, r.read()
tests = [("控制台 /", "http://127.0.0.1:8090/"),
         ("/chat", "http://127.0.0.1:8090/chat"),
         ("/api/state", "http://127.0.0.1:8090/api/state"),
         ("/api/fs?path=" + urllib.parse.quote(home), "http://127.0.0.1:8090/api/fs?path=" + urllib.parse.quote(home)),
         ("/api/fs?path=" + urllib.parse.quote("D:\\nonexist"), "http://127.0.0.1:8090/api/fs?path=" + urllib.parse.quote("D:\\nonexist"))]
for name, url in tests:
    try:
        code, body = get(url)
        extra = ""
        d = None
        try:
            d = json.loads(body.decode())
        except Exception:
            pass
        if name == "/api/state" and d:
            extra = f"  workspace={d.get('workspace')}"
        if "api/fs" in name and d:
            extra = f"  path={d.get('path')}  fell_back={d.get('fell_back')}"
        print(f"  {name[:42]:42s} {code}  {len(body)} 字节{extra}")
    except Exception as e:
        print(f"  {name[:42]:42s} 失败: {e}")
PY

say "6. 工作区写入测试"
python3 - "$WORK" <<'PY'
import json, sys, urllib.request
work = sys.argv[1]
payload = json.dumps({"level": "off", "workspace": work}).encode()
req = urllib.request.Request("http://127.0.0.1:8090/api/tools",
                             data=payload, headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        d = json.loads(r.read().decode())
    print("  写入工作区: OK   workspace =", d.get("workspace"))
except Exception as e:
    print("  写入工作区失败:", e)
PY

say "完成"
cat <<EOT
  现在「打开控制台」在独立窗口里会直接跳到控制台首页；
  选工作区时若路径无效会自动回到主目录，保存时会自动创建目录。

  工作区: $WORK
  记得重启外壳窗口（关掉再开）才会用上新的 chat.html。
EOT

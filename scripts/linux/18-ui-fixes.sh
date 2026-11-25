#!/usr/bin/env bash
# ============================================================
#  18-ui-fixes.sh —— 修四个问题
#
#  1. 壁纸 / 左上角图标没显示：skin_file() 里把 "/" 换成 "\\"，
#     在 Linux 上变成文件名里的反斜杠 -> 404。改用 os.sep。
#  2. 顶部按钮和标签栏重复：隐藏 Notebook 标签栏，只留顶部按钮。
#  3. 设置里的「打开控制台」在 Linux 上是死路：非 WebView2 环境直接隐藏该入口。
#  4. 保活开关「切换失败」：Linux 下服务是系统级 systemd，面板无权也无需切换，
#     改为只读展示（开关置灰，状态读 systemctl）。
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 关掉外壳窗口（后面要换文件）"
pkill -f 'llama-ui/shell/llama_chat.py' 2>/dev/null && echo "  已关闭" || echo "  没有在运行"
rm -f "$DEST/shell/shell.lock"

say "2. 更新文件"
for f in "shell/llama_chat.py" "panel/app.py" "panel/ui.html" "web/chat.html" "web/skins/skins.json"; do
  if [ -f "$PKG/$f" ]; then
    mkdir -p "$(dirname "$DEST/$f")"
    cp -f "$PKG/$f" "$DEST/$f"
    echo "  $f"
  else
    echo "  [缺失] $f"
  fi
done
# 壁纸与图标也补齐（之前可能漏拷）
if [ -d "$PKG/web/skins" ]; then
  mkdir -p "$DEST/web/skins"
  cp -a "$PKG/web/skins/." "$DEST/web/skins/"
  echo "  web/skins/ ($(find "$DEST/web/skins" -type f | wc -l) 个文件)"
fi

say "3. 重启面板"
sudo systemctl restart llama-panel
sleep 4

say "4. 验证皮肤资源（关键）"
python3 - <<'PY'
import urllib.request
base = "http://127.0.0.1:8090"
for path in ("/api/skins", "/skins/qwen/bg.jpg", "/skins/deepseek/bg.jpg",
             "/skins/icons/qwen.png", "/skins/icons/default.png"):
    try:
        req = urllib.request.Request(base + path)
        with urllib.request.urlopen(req, timeout=8) as r:
            body = r.read()
        print(f"  {path:28s} {r.status}  {len(body)} 字节  {r.headers.get('Content-Type')}")
    except Exception as e:
        print(f"  {path:28s} 失败: {e}")
PY

say "5. 验证保活与扫描"
python3 - <<'PY'
import json, urllib.request
def get(url):
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.loads(r.read().decode())
try:
    st = get("http://127.0.0.1:8090/api/state")
    ka = st.get("keepalive") or {}
    print(f"  保活: enabled={ka.get('enabled')} readonly={ka.get('readonly')} ({ka.get('note','')[:40]})")
except Exception as e:
    print("  /api/state 失败:", e)
try:
    sc = get("http://127.0.0.1:8090/api/models/scan")
    files = sc.get("files") or []
    print(f"  扫描: {len(files)} 个 gguf")
    for f in files[:6]:
        print(f"    - {f['name']}  {f['size']/1024**3:.2f} GB  {f['configured_as'] or '未配置'}")
except Exception as e:
    print("  /api/models/scan 失败:", e)
PY

say "6. 实测外壳（6 秒）"
rm -f "$DEST/shell/shell.log"
timeout 6 "$DEST/shell/launch.sh"; rc=$?
echo "  退出码: $rc （124 = 正常）"
tail -5 "$DEST/shell/shell.log" 2>/dev/null | sed 's/^/    /'

say "完成"
cat <<EOT
  现在应该：
    · 聊天页有 Qwen 壁纸与左上角图标（若模型是 qwen 家族）
    · 只有顶部一排按钮，没有重复的标签栏
    · 设置里不再有「打开控制台」入口
    · 保活开关置灰，显示 systemd 状态

  重新打开窗口（桌面图标）看效果。
EOT

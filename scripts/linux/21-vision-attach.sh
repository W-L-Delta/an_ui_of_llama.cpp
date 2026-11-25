#!/usr/bin/env bash
# ============================================================
#  21-vision-attach.sh —— 修「图片变链接 / 模型说看不到图」
#
#  现象与根因：
#    1. 用户从文件管理器复制图片后粘贴，WebKit 只给 file:// 路径，
#       浏览器无权读文件 -> 路径被当普通文本粘进输入框，模型只看到一串路径。
#       修法：面板新增 /api/fs/attach 代读（仅图片、限家目录/工作区、12MB 上限），
#       聊天页识别 file:// 或本地图片路径后自动附加为图片。
#    2. 控制台「视觉投影」显示开启，但模型仍自称文本模型：
#       start-llama.sh 里 mmproj 仍按旧方式拼 $ROOT/<相对路径>，
#       Linux 上模型在 WinD 盘 -> 文件不存在 -> 根本没传 --mmproj。
#       修法：mmproj 也用 resolve_model() 解析。
#    3. 「重复」：模型看不到图时反复 list/read 试探，属于连带现象；
#       图片能正常附加后就不再出现。
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 更新文件"
for f in "panel/app.py" "web/chat.html" "scripts/start-llama.sh"; do
  cp -f "$PKG/$f" "$DEST/$f" && echo "  $f"
done
chmod +x "$DEST/scripts/start-llama.sh"

say "2. 视觉投影是否真的传给了 llama-server"
VISION="$(grep -E '^\s*enabled\s*=' "$DEST/scripts/llama.conf.ini" | head -1)"
echo "  [vision] 段首行 enabled: $VISION"
grep -nE '^\s*(mmproj|model|qwen36)\s*=' "$DEST/scripts/llama.conf.ini" | sed 's/^/  /'
echo "  当前 llama-server 命令行里的 mmproj："
ps -o args= -C llama-server 2>/dev/null | tr ' ' '\n' | grep -A1 -- '--mmproj' | tr '\n' ' ' | sed 's/^/    /'
echo

say "3. 重启面板与服务（让新的 mmproj 解析生效）"
sudo systemctl restart llama-panel
sudo -n systemctl restart llama-server 2>/dev/null || sudo systemctl restart llama-server
python3 - <<'PY'
import time, urllib.request
for i in range(200):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=2) as r:
            if r.status == 200:
                print(f"  llama-server 就绪（{i} 秒）")
                break
    except Exception:
        pass
    time.sleep(1)
else:
    print("  200 秒未就绪")
PY

say "4. 再次检查 mmproj 是否出现在命令行"
python3 - <<'PY'
import subprocess
try:
    out = subprocess.run(["ps", "-o", "args=", "-C", "llama-server"], capture_output=True, text=True, timeout=10).stdout
except Exception as e:
    out = ""
    print("  读取 ps 失败:", e)
line = out.strip().splitlines()[0] if out.strip() else ""
args = line.split()
if "--mmproj" in args:
    i = args.index("--mmproj")
    print("  ✅ 已带 --mmproj:", args[i + 1] if i + 1 < len(args) else "(缺值)")
else:
    print("  ❌ 命令行里没有 --mmproj —— 视觉投影未生效")
    print("     请确认 [vision] enabled = true，且该模型的 mmproj 文件存在")
print("  端口检查:", "OK" if "8080" in line else "未见 --port")
PY

say "5. 测试 /api/fs/attach 代读图片"
python3 - <<'PY'
import base64, json, pathlib, urllib.parse, urllib.request

# 造一张 2x2 的 PNG 作为测试图
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYkBChgYGBgYAAAA//8DAJ0BBQr0m8mAAAAAAElFTkSuQmCC"
)
test = pathlib.Path.home() / "测试图片.png"
test.write_bytes(png)
url = "http://127.0.0.1:8090/api/fs/attach?path=" + urllib.parse.quote(str(test))
try:
    with urllib.request.urlopen(url, timeout=15) as r:
        d = json.loads(r.read().decode())
    print(f"  ✅ {d['name']}  {d['size']} 字节  {d['mime']}  url 前缀: {d['url'][:30]}…")
except Exception as e:
    print("  ❌ 失败:", e)
# 越权测试：家目录外
try:
    with urllib.request.urlopen("http://127.0.0.1:8090/api/fs/attach?path=/etc/hostname", timeout=10) as r:
        print("  ⚠️ 越权读取竟然成功（应当被拒绝）")
except Exception as e:
    print("  ✅ 越权被拒绝（/etc/hostname）")
PY

say "6. 状态"
for u in llama-server llama-panel; do
  printf "  %-13s %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)"
done
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  显存: /'

say "完成"
cat <<EOT
  现在：
    · 在文件管理器里复制图片 -> 在聊天框粘贴，会直接变成缩略图
    · 拖拽图片到窗口任意位置同样可以
    · 控制台开「视觉投影」后重启，llama-server 会真的带上 --mmproj
      （第 4 节能看到）

  验证视觉：发一条带图的「这张图里是什么？」，模型应该能描述内容。
EOT

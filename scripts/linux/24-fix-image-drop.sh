#!/usr/bin/env bash
# ============================================================
#  24-fix-image-drop.sh
#
#  上次报告暴露两件事：
#    1. /api/fs/attach 返回 404 —— 因为 21 那步没跑，Linux 上的 panel/app.py
#       还是旧版本，根本没有这个接口（23 只更新了 chat.html）
#    2. 把图片拖进窗口，WebKit 直接把整个窗口导航到 file:// 图片，
#       界面卡在那张图上，只能靠「控制台」标签切走，切不回聊天
#
#  本脚本：
#    · 更新 panel/app.py（带 attach 接口）+ web/chat.html + shell/llama_chat.py
#    · 外壳增加 decide-policy：拦掉任何 file:// 导航（兜底）
#    · 聊天页拖放：WebKit 只给 text/uri-list 时也阻止默认导航
#    · 实测 attach 接口 + 直接用 API 验证模型能否看图
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 关外壳 + 更新文件"
pkill -f 'llama-ui/shell/llama_chat.py' 2>/dev/null && echo "  已关闭外壳" || true
rm -f "$DEST/shell/shell.lock"
for f in "panel/app.py" "web/chat.html" "shell/llama_chat.py"; do
  cp -f "$PKG/$f" "$DEST/$f" && echo "  $f"
done
chmod +x "$DEST/shell/llama_chat.py"

say "2. 重启面板"
sudo systemctl restart llama-panel
sleep 4

say "3. 接口是否已存在"
python3 - <<'PY'
import json, os, urllib.parse, urllib.request
print("  /api/fs/attach ...")
target = "/home/w-l-delta/下载/eaa17543b71036b54bfc95c2be48dbbc.jpeg"
print("  目标文件存在:", os.path.isfile(target))
url = "http://127.0.0.1:8090/api/fs/attach?path=" + urllib.parse.quote(target)
try:
    with urllib.request.urlopen(url, timeout=30) as r:
        d = json.loads(r.read().decode())
    print(f"  ✅ 代读成功: {d['name']}  {d['size']} 字节  {d['mime']}  dataURL {len(d['url'])} 字符")
except Exception as e:
    print("  ❌ 仍然失败:", e)
    # 输出面板日志尾巴，便于定位
    import subprocess
    print("  面板日志尾部:")
    out = subprocess.run(["journalctl", "-u", "llama-panel", "-n", "12", "--no-pager"],
                         capture_output=True, text=True, timeout=20).stdout
    for line in out.strip().splitlines()[-12:]:
        print("    " + line)
PY

say "4. 模型能否看图（端到端）"
python3 - <<'PY'
import base64, json, os, pathlib, urllib.parse, urllib.request
cand = "/home/w-l-delta/下载/eaa17543b71036b54bfc95c2be48dbbc.jpeg"
if not os.path.isfile(cand):
    cand = str(pathlib.Path.home() / "测试图片.png")
    if not os.path.isfile(cand):
        png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYkBChgYGBgYAAAA//8DAJ0BBQr0m8mAAAAAAElFTkSuQmCC")
        pathlib.Path(cand).write_bytes(png)
url = "http://127.0.0.1:8090/api/fs/attach?path=" + urllib.parse.quote(cand)
try:
    with urllib.request.urlopen(url, timeout=30) as r:
        att = json.loads(r.read().decode())
except Exception as e:
    print("  取图失败，跳过视觉测试:", e); raise SystemExit(0)

payload = json.dumps({
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": "这张图片里是什么？用一句话回答。"},
        {"type": "image_url", "image_url": {"url": att["url"]}},
    ]}],
    "max_tokens": 120, "stream": False,
}).encode()
req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", data=payload,
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        j = json.loads(r.read().decode())
    ans = ((j.get("choices") or [{}])[0].get("message", {}).get("content") or "").strip()
    print("  回答:", (ans or "(空)").replace("\n", " ")[:200])
    low = ans.lower()
    if not ans:
        print("  ⚠️ 回答为空")
    elif any(k in ans for k in ("看不到", "无法查看", "无法识别", "文本模型", "无法读取")) or "cannot see" in low:
        print("  ❌ 模型仍说看不到图")
    else:
        print("  ✅ 模型给出了带内容的回答（视觉链路通了）")
except Exception as e:
    print("  请求失败:", e)
PY

say "5. 外壳自检（含 file:// 拦截）"
python3 "$DEST/shell/llama_chat.py" --check | sed 's/^/  /'

say "完成"
cat <<EOT
  重新打开窗口后：
    · 拖图片进窗口 -> 变成缩略图附件，不会再被导航到图片本身
    · 剪贴板里复制图片 -> Ctrl+V 变缩略图
    · 若拖放仍有异常，看 ~/llama-ui/shell/shell.log 里有没有「拦截 file:// 导航」
EOT

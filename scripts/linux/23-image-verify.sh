#!/usr/bin/env bash
# ============================================================
#  23-image-verify.sh —— 图片：附加 + 视觉识别，两步都验证
#
#  报告结论（上一份）：
#    · --mmproj 已经传进去了 ✅（视觉的后端条件满足）
#    · 但聊天里粘贴的是一整段文字夹着路径，页面没识别出来，
#      于是路径被当普通文本发给模型 -> 模型只能说自己看不到图
#
#  本脚本：
#    1. 更新 chat.html（粘贴“文字+图片路径”时自动提取路径并附加图片）
#    2. 用 /api/fs/attach 实测读取用户那张图片
#    3. 直接用 API 发一条带图的请求，验证模型能不能真的“看图”
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 更新 chat.html"
cp -f "$PKG/web/chat.html" "$DEST/web/chat.html" && echo "  已更新"

say "2. 重启面板"
sudo systemctl restart llama-panel
sleep 4

say "3. 用面板代读那张图片"
python3 - <<'PY'
import json, os, urllib.parse, urllib.request
candidates = [
    "/home/w-l-delta/下载/eaa17543b71036b54bfc95c2be48dbbc.jpeg",
    "/home/w-l-delta/下载",
]
target = candidates[0]
print("  目标:", target, " 存在:", os.path.isfile(target))
if os.path.isfile(target):
    url = "http://127.0.0.1:8090/api/fs/attach?path=" + urllib.parse.quote(target)
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            d = json.loads(r.read().decode())
        print(f"  ✅ 代读成功: {d['name']}  {d['size']} 字节  {d['mime']}")
        print(f"     data URL 长度: {len(d['url'])}")
    except Exception as e:
        print("  ❌ 代读失败:", e)
else:
    print("  （该文件不在，跳过；用 /api/fs 列一下下载目录）")
    url = "http://127.0.0.1:8090/api/fs?path=" + urllib.parse.quote("/home/w-l-delta/下载")
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            d = json.loads(r.read().decode())
        imgs = [e["name"] for e in d.get("entries", []) if e["name"].lower().endswith((".png", ".jpg", ".jpeg", ".webp"))]
        print("   下载目录里的图片:", imgs[:5])
    except Exception as e:
        print("   列目录失败:", e)
PY

say "4. 直接测「模型能不能看图」"
python3 - <<'PY'
import base64, json, os, pathlib, urllib.parse, urllib.request

# 找一张可用图片：优先用户的，其次自己造
cand = "/home/w-l-delta/下载/eaa17543b71036b54bfc95c2be48dbbc.jpeg"
if not os.path.isfile(cand):
    cand = str(pathlib.Path.home() / "测试图片.png")
    if not os.path.isfile(cand):
        png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYkBChgYGBgYAAAA//8DAJ0BBQr0m8mAAAAAAElFTkSuQmCC")
        pathlib.Path(cand).write_bytes(png)

url = "http://127.0.0.1:8090/api/fs/attach?path=" + urllib.parse.quote(cand)
try:
    with urllib.request.urlopen(url, timeout=20) as r:
        att = json.loads(r.read().decode())
except Exception as e:
    print("  取图失败:", e); raise SystemExit(0)

payload = json.dumps({
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "这张图片里是什么？用一句话回答。"},
            {"type": "image_url", "image_url": {"url": att["url"]}},
        ],
    }],
    "max_tokens": 120, "stream": False,
}).encode()
req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", data=payload,
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        j = json.loads(r.read().decode())
    m = (j.get("choices") or [{}])[0].get("message", {})
    ans = (m.get("content") or "").strip()
    print("  图片:", os.path.basename(cand))
    print("  回答:", (ans or "(空)").replace("\n", " ")[:200])
    low = ans.lower()
    if ("看不到" in ans or "无法查看" in ans or "无法识别" in ans or "文本模型" in ans
            or "cannot see" in low or "can't see" in low):
        print("  ❌ 模型仍然说看不到图 —— mmproj 或图片格式没被接受")
    elif ans:
        print("  ✅ 模型给出了基于图片内容/画面的回答（视觉链路通了）")
    else:
        print("  ⚠️ 回答为空，换个说法再试")
except Exception as e:
    print("  请求失败:", e)
PY

say "5. 状态"
ps -o args= -C llama-server 2>/dev/null | head -1 | tr ' ' '\n' | grep -c -- '--mmproj' | sed 's/^/  --mmproj 出现次数: /'
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  显存: /'

say "完成"
cat <<EOT
  在聊天页里这样操作即可：
    · 先打字，再把图片文件「复制」后 Ctrl+V —— 会自动变成缩略图
    · 或直接把图片拖进窗口
    · 也可以粘贴一整段「文字 + 图片路径」，脚本会把路径挑出来附加成图片

  第 4 节若显示 ✅，说明视觉链路通了；若 ❌，说明是模型/投影的问题，不是页面。
EOT

#!/usr/bin/env bash
# ============================================================
#  25-image-debug.sh —— 修「拖放/粘贴图片仍不生效」并现场取证
#
#  背景（上一份报告）：
#    · /api/fs/attach 已经正常（能代读那张 jpeg）
#    · 但「回答为空」不是视觉坏了：Windows 上同样的请求也是空 content，
#      因为 max_tokens=120 全被思考过程吃掉（finish_reason=length）。
#      真正要确认的是：页面到底有没有收到「粘贴/拖放里的图片」。
#
#  本脚本：
#    1. 更新 panel/app.py、web/chat.html、shell/llama_chat.py
#       · 面板新增 POST /api/debug/log（把页面侧事件写进 ui-debug.log）
#       · 聊天页在 paste / drop 时上报 types / files / uri，便于定位
#       · 外壳关闭 WebKit 页面缓存，并给 URL 加时间戳（防止加载旧页面）
#    2. 重启面板、清空旧调试日志
#    3. 等 40 秒：请你现在去窗口里粘贴/拖一张图片
#    4. 打印 ui-debug.log，看浏览器到底给了什么
#    5. 用 max_tokens=512 重测视觉，确认模型是否真的看得到图
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
DBG="$DEST/panel/data/ui-debug.log"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 关外壳 + 更新文件"
pkill -f 'llama-ui/shell/llama_chat.py' 2>/dev/null && echo "  已关闭外壳" || true
rm -f "$DEST/shell/shell.lock"
for f in "panel/app.py" "web/chat.html" "shell/llama_chat.py"; do
  cp -f "$PKG/$f" "$DEST/$f" && echo "  $f"
done
chmod +x "$DEST/shell/llama_chat.py"

say "2. 重启面板并清空调试日志"
sudo systemctl restart llama-panel
sleep 4
rm -f "$DBG"
echo "  调试日志: $DBG"

say "3. 请现在这样做（脚本等 40 秒）"
cat <<'EOT'
     a) 在桌面上双击「llama.cpp 本地对话」打开窗口
     b) 在文件管理器里复制一张图片（Ctrl+C），到聊天框按 Ctrl+V
        —— 或者直接把图片拖进聊天区域
     c) 等 3 秒，不用发送
EOT
for i in $(seq 1 40); do
  sleep 1
  [ -f "$DBG" ] && [ "$(wc -l < "$DBG")" -ge 1 ] && { echo "  收到日志（${i}s）"; break; }
done

say "4. 页面侧事件日志（关键）"
if [ -f "$DBG" ]; then
  tail -20 "$DBG" | sed 's/^/  /'
else
  echo "  没有收到任何日志 —— 说明页面根本没执行到 paste/drop 处理器"
  echo "  可能仍在用旧页面：确认窗口是关掉后重新打开的（不是一直开着的那个）"
fi

say "5. 视觉复测（max_tokens=512，避免被思考吃光）"
python3 - <<'PY'
import base64, json, os, pathlib, urllib.parse, urllib.request
cand = "/home/w-l-delta/下载/eaa17543b71036b54bfc95c2be48dbbc.jpeg"
if not os.path.isfile(cand):
    cand = str(pathlib.Path.home() / "测试图片.png")
url = "http://127.0.0.1:8090/api/fs/attach?path=" + urllib.parse.quote(cand)
try:
    with urllib.request.urlopen(url, timeout=30) as r:
        att = json.loads(r.read().decode())
except Exception as e:
    print("  取图失败:", e); raise SystemExit(0)

payload = json.dumps({
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": "这张图片里是什么？用一句话回答。"},
        {"type": "image_url", "image_url": {"url": att["url"]}},
    ]}],
    "max_tokens": 512, "stream": False,
}).encode()
req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", data=payload,
                             headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=300) as r:
    j = json.loads(r.read().decode())
ch = (j.get("choices") or [{}])[0]
m = ch.get("message", {})
content = (m.get("content") or "").strip()
reason = (m.get("reasoning_content") or "").strip()
print("  finish_reason:", ch.get("finish_reason"))
print("  content  :", (content or "(空)").replace("\n", " ")[:200])
print("  reasoning:", (reason or "(空)").replace("\n", " ")[:200])
text = content or reason
if not text:
    print("  ❌ 完全没输出")
elif any(k in text for k in ("看不到", "无法查看", "无法识别", "无法读取")):
    print("  ❌ 模型说看不到图")
else:
    print("  ✅ 模型描述了图片内容（视觉通了；content 为空只是被思考占满，增大 max_tokens 即可）")
PY

say "6. 状态"
for u in llama-server llama-panel; do
  printf "  %-13s %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)"
done

say "完成"
cat <<EOT
  请把这份报告发我，重点看第 4 节：
    · 有 paste types=...  -> 页面收到了，问题在识别逻辑，我按 types 修
    · 完全没有日志        -> 页面还是旧的，需要确认窗口确实重开过

  另外：视觉本身大概率是好的（Windows 上同样请求 content 也是空，
  因为 max_tokens 太小、被思考过程吃光）。第 5 节用 512 再看一次。
EOT

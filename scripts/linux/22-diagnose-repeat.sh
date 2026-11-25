#!/usr/bin/env bash
# ============================================================
#  22-diagnose-repeat.sh —— 查「Linux 上模型反复回答第一个问题」
#
#  同时修掉：工作区选择框里点文件夹会跳回 home（分隔符被硬编码成 \\）
#
#  这个脚本不改采样参数，只做取证：
#    1. llama-server 完整命令行（看 --temp/--presence-penalty 有没有真的传进去）
#    2. /props（服务端实际生效的采样与模板）
#    3. 配置里 [sampling] 与角色段
#    4. 两轮 API 对话：第一轮问 A，第二轮带上历史问 B，看是否复读 A
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 更新 chat.html（修文件夹选择跳回 home）"
cp -f "$PKG/web/chat.html" "$DEST/web/chat.html" && echo "  已更新"

say "2. llama-server 完整命令行"
ps -o args= -C llama-server 2>/dev/null | head -1 | tr ' ' '\n' | sed 's/^/    /' | head -60

say "3. 采样相关参数是否都在命令行里"
ARGS="$(ps -o args= -C llama-server 2>/dev/null | head -1)"
for k in --temp --top-p --top-k --min-p --presence-penalty --frequency-penalty --repeat-penalty --repeat-last-n --jinja --cache-reuse --reasoning-format --mmproj; do
  if printf '%s' "$ARGS" | grep -q -- "$k"; then
    printf "  ✅ %s\n" "$k"
  else
    printf "  ❌ %s （没传）\n" "$k"
  fi
done

say "4. 配置里的采样值"
grep -nE '^\s*(temp|top_p|top_k|min_p|presence_penalty|frequency_penalty|repeat_penalty|repeat_last_n|dry_multiplier)\s*=' "$DEST/scripts/llama.conf.ini" | sed 's/^/  /'

say "5. /props 里服务端实际生效的参数"
python3 - <<'PY'
import json, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:8080/props", timeout=10) as r:
        d = json.loads(r.read().decode())
    gen = (d.get("default_generation_settings") or {})
    params = gen.get("params") or {}
    print("  model:", d.get("model_path"))
    print("  n_ctx:", gen.get("n_ctx"))
    for k in ("temp", "top_p", "top_k", "min_p", "presence_penalty",
              "frequency_penalty", "repeat_penalty", "repeat_last_n"):
        if k in params:
            print(f"  {k:18s} = {params[k]}")
    tpl = (d.get("chat_template") or "")
    print("  chat_template:", ("有（%d 字符）" % len(tpl)) if tpl else "❌ 没有")
except Exception as e:
    print("  读取 /props 失败:", e)
PY

say "6. 两轮对话测试（关键）"
python3 - <<'PY'
import json, urllib.request

BASE = "http://127.0.0.1:8080"

def chat(messages, max_tokens=120):
    payload = json.dumps({"messages": messages, "max_tokens": max_tokens, "stream": False}).encode()
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=payload,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        j = json.loads(r.read().decode())
    m = (j.get("choices") or [{}])[0].get("message", {})
    return (m.get("content") or "").strip(), (m.get("reasoning_content") or "").strip()

q1 = "用一句话回答：1+1 等于几？"
a1, r1 = chat([{"role": "user", "content": q1}])
print("  第 1 轮问:", q1)
print("  第 1 轮答:", (a1 or r1 or "(空)").replace("\n", " ")[:120])

q2 = "用一句话回答：中国的首都是哪座城市？"
msgs = [
    {"role": "user", "content": q1},
    {"role": "assistant", "content": a1 or "(略)"},
    {"role": "user", "content": q2},
]
a2, r2 = chat(msgs)
print("  第 2 轮问:", q2)
print("  第 2 轮答:", (a2 or r2 or "(空)").replace("\n", " ")[:120])

low = (a2 + r2).lower()
if "1+1" in low or "等于 2" in low or "等于2" in low or "二" in low and "北京" not in (a2 + r2):
    print("  ❌ 第 2 轮答的不是第 2 个问题 —— 复读已复现")
elif "北京" in (a2 + r2):
    print("  ✅ 第 2 轮正确回答第 2 个问题（API 层没有复读）")
else:
    print("  ⚠️ 第 2 轮回答既不是北京也不像复读，请看上面原文")
PY

say "7. 服务与显存"
for u in llama-server llama-panel; do
  printf "  %-13s %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)"
done
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  显存: /'

say "完成"
cat <<EOT
  把这份报告给 AI：
    · 第 3 节看哪些采样参数没传（❌）
    · 第 5 节看服务端实际生效的 temp / presence_penalty
    · 第 6 节是判定：API 层是否复读

  若第 6 节 ✅ 但聊天页仍复读，说明问题在页面侧的 messages 组装，
  而不是采样参数；若第 6 节 ❌，就是服务端参数问题。
EOT

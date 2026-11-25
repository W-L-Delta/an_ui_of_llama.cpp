#!/usr/bin/env bash
# ============================================================
#  19-linux-fixes.sh —— 三个 Linux 版问题
#
#  1. 控制台右下角「关闭面板」会连服务一起停：Linux 版直接不显示该按钮
#     （面板由 systemd 守护，不该从页面里关）
#  2. 切换模型第二次报「没有找到文件」：start-llama.sh 增加 resolve_model()，
#     兼容反斜杠相对路径 / 过期绝对路径 / Windows 盘挂载点，失败时打印尝试过的路径
#  3. 拖拽或粘贴图片变成链接：粘贴增加 clipboardData.files 兜底；
#     拖放改为整个窗口接收并 preventDefault，不让 WebKit 把图片当链接打开
#
#  另外保留：保活开关在 Linux 下只读（显示 systemd 状态）
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 关外壳、更新文件"
pkill -f 'llama-ui/shell/llama_chat.py' 2>/dev/null && echo "  已关闭外壳" || true
rm -f "$DEST/shell/shell.lock"
for f in "panel/app.py" "panel/ui.html" "web/chat.html" "scripts/start-llama.sh"; do
  if [ -f "$PKG/$f" ]; then
    mkdir -p "$(dirname "$DEST/$f")"
    cp -f "$PKG/$f" "$DEST/$f"
    echo "  $f"
  else
    echo "  [缺失] $f"
  fi
done
chmod +x "$DEST/scripts/start-llama.sh"

say "2. 重启面板"
sudo systemctl restart llama-panel
sleep 4

say "3. 校验 platform 与保活只读"
python3 - <<'PY'
import json, urllib.request
with urllib.request.urlopen("http://127.0.0.1:8090/api/state", timeout=10) as r:
    d = json.loads(r.read().decode())
ka = d.get("keepalive") or {}
print(f"  platform = {d.get('platform')}")
print(f"  keepalive.enabled={ka.get('enabled')}  readonly={ka.get('readonly')}")
print(f"  workspace = {d.get('workspace')}")
PY

say "4. 连续切换两次模型（复现第 2 个问题）"
python3 - <<'PY'
import json, time, urllib.request

def get(path):
    with urllib.request.urlopen("http://127.0.0.1:8090" + path, timeout=15) as r:
        return json.loads(r.read().decode())

def post(path, payload, timeout=240):
    req = urllib.request.Request("http://127.0.0.1:8090" + path,
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def wait_ready(seconds=180):
    for i in range(seconds):
        try:
            with urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=2) as r:
                if r.status == 200:
                    return True, i
        except Exception:
            pass
        time.sleep(1)
    return False, seconds

st = get("/api/state")
cur = st.get("active") or "base"
order = [r for r in ("base", "deepseek", "qwen36") if r != cur]
print("  当前:", cur, " 依次切到:", order[:2])

for i, role in enumerate(order[:2], 1):
    params = {"model": role, "ngl": 35, "ctx": 32768, "threads": 8, "parallel": 1,
              "ctk": "q4_0", "ctv": "q4_0", "flash_attn": True, "vision": False}
    try:
        r = post("/api/apply", params)
        print(f"  第 {i} 次切到 {role}: 受理={r.get('ok')}")
    except Exception as e:
        print(f"  第 {i} 次切到 {role}: 请求失败 {e}")
        continue
    ok, secs = wait_ready()
    s2 = get("/api/state")
    print(f"    就绪={ok}({secs}s)  loaded={(s2.get('loaded') or {}).get('id')}  active={s2.get('active')}")
PY

say "5. 配置里的模型路径（确认没有被写坏）"
grep -nE '^\s*(model|qwen36|deepseek|active)\s*=' "$DEST/scripts/llama.conf.ini" | sed 's/^/  /'

say "6. start-llama.sh 路径解析自检"
cd "$DEST" || exit 1
for role in base qwen36 deepseek; do
  out="$(bash scripts/start-llama.sh --status 2>&1 | head -3)"
  printf "  --status: %s\n" "$(echo "$out" | head -1)"
  break
done

say "完成"
cat <<EOT
  现在：
    · Linux 版不再显示「关闭面板」
    · 切换模型失败时会打印尝试过的所有路径
    · 拖拽 / 粘贴图片会变成略缩图而不是链接

  重开外壳窗口后测试拖拽图片。
EOT

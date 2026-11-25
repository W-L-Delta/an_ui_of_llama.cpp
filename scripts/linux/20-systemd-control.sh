#!/usr/bin/env bash
# ============================================================
#  20-systemd-control.sh —— 让面板通过 systemd 控制服务
#
#  报告结论：
#    第 1 次切到 base：受理=True，但 0 秒就"就绪"，loaded 仍是 qwen36；
#    第 2 次请求直接 409（上一个 job 还没结束）。
#
#  原因：在 Linux 上 llama-server 是 systemd 的进程，而面板却去调
#  start-llama.sh 来「停旧启新」——脚本按 PID 文件找不到 systemd 的实例，
#  新实例又抢不到 8080，于是 job 卡住、模型没换。
#
#  修法：
#    · 面板在 Linux 下改为 `sudo -n systemctl {start|stop|restart} llama-server`
#    · 切换模型时先写 [models] active，再 restart
#    · 需要给这几个 systemctl 动词放行（本脚本装 /etc/sudoers.d/llama-panel）
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
USER_NAME="$(id -un)"
SUDO_FILE="/etc/sudoers.d/llama-panel"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 更新 panel/app.py"
cp -f "$PKG/panel/app.py" "$DEST/panel/app.py"
echo "  已更新"

say "2. 安装 sudoers 放行（只允许这四个 systemctl 动作）"
TMP="$(mktemp)"
cat > "$TMP" <<EOT
# 允许面板（$USER_NAME）在无密码情况下控制 llama-server 服务
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/systemctl start llama-server, /usr/bin/systemctl stop llama-server, /usr/bin/systemctl restart llama-server, /usr/bin/systemctl is-active llama-server, /usr/bin/systemctl is-enabled llama-server
EOT
if sudo visudo -cf "$TMP" >/dev/null 2>&1; then
  sudo install -m 0440 -o root -g root "$TMP" "$SUDO_FILE"
  echo "  已写入 $SUDO_FILE"
else
  echo "  校验失败，未安装（sudoers 语法问题）"; rm -f "$TMP"; exit 1
fi
rm -f "$TMP"
echo "  自检："
sudo -n systemctl is-active llama-server >/dev/null 2>&1 \
  && echo "    sudo -n systemctl is-active  OK" \
  || echo "    sudo -n 仍然不可用（检查 sudoers 与 /usr/bin/systemctl 路径）"

say "3. 重启面板"
sudo systemctl restart llama-panel
sleep 4

say "4. 连续切换两次模型（这次按 active 判断，不再被旧进程骗）"
python3 - <<'PY'
import json, time, urllib.request

BASE = "http://127.0.0.1:8090"

def get(path, timeout=20):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        return json.loads(r.read().decode())

def post(path, payload, timeout=300):
    req = urllib.request.Request(BASE + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def wait_active(role, seconds=300):
    last = None
    for i in range(seconds):
        try:
            d = get("/api/state", timeout=8)
            last = d
            job = get("/api/job", timeout=8)
            if d.get("active") == role and not job.get("running") and d.get("running"):
                return True, i, d
        except Exception:
            pass
        time.sleep(1)
    return False, seconds, last

st = get("/api/state")
cur = st.get("active") or "base"
order = [r for r in ("base", "deepseek", "qwen36") if r != cur]
print(f"  当前 active={cur}   依次切到: {order[:2]}")

for i, role in enumerate(order[:2], 1):
    params = {"model": role, "ngl": 35, "ctx": 32768, "threads": 8, "parallel": 1,
              "ctk": "q4_0", "ctv": "q4_0", "flash_attn": True, "vision": False}
    try:
        r = post("/api/apply", params)
        print(f"  第 {i} 次切到 {role}: 受理={r.get('ok')}")
    except Exception as e:
        print(f"  第 {i} 次切到 {role}: 请求失败 {e}")
        try:
            print("     job 输出:", get("/api/job").get("output", [])[-6:])
        except Exception:
            pass
        continue
    ok, secs, d = wait_active(role)
    if ok:
        print(f"    ✅ {secs}s 后 active={d.get('active')} loaded={(d.get('loaded') or {}).get('id')}")
    else:
        print(f"    ❌ {secs}s 未切换成功，当前 active={(d or {}).get('active')}")
        try:
            out = get("/api/job").get("output", [])
            print("     job 输出（最后 8 行）:")
            for line in out[-8:]:
                print("       " + line)
        except Exception:
            pass
PY

say "5. 状态"
for u in llama-server llama-panel; do
  printf "  %-13s %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)"
done
grep -nE '^\s*active\s*=' "$DEST/scripts/llama.conf.ini" | sed 's/^/  /'

say "完成"
cat <<EOT
  现在面板在 Linux 上通过 systemd 控制服务：
    · 切换模型：写 [models] active → systemctl restart llama-server
    · 重启 / 停止按钮同样走 systemctl
    · sudoers 只放行了这 4 个动作，不能做别的事

  若切换仍失败，把第 4 节打印的 job 输出发我。
EOT

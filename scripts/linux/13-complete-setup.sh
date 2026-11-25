#!/usr/bin/env bash
# ============================================================
#  13-complete-setup.sh —— 按正确顺序补齐：08 → 10 → 12
#
#  上一份报告的结论：09 在前置检查就退出了，因为 ~/llama-ui 里没有
#  panel/、scripts/、bin/cuda/llama-server —— 说明 08（装 UI）从来没跑过。
#  （10/11 只是往 ~/llama-ui/shell 里写文件，不会装 UI 本体。）
#
#  所以这里按顺序执行：
#    08  装 UI（复制 panel/web/scripts，生成 Linux 配置，放 llama-server 包装）
#    10  装外壳（GTK/WebKit 依赖 + llama_chat.py）—— 因为 08 会清空目录
#    12  修桌面条目 + 装 systemd 服务 + 全面验证
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }
step() {
  printf "\n\033[35m>>>>>>>>>> %s <<<<<<<<<<\033[0m\n" "$1"
  bash "$HERE/$1"
  rc=$?
  if [ $rc -ne 0 ]; then
    printf "\n\033[31m!!! %s 失败（退出码 %s），后续步骤停止\033[0m\n" "$1" "$rc"
    exit $rc
  fi
}

step "08-install-ui.sh"
step "10-install-shell.sh"
step "12-fix-all.sh"

say "全部完成 —— 最终确认"
for u in llama-server llama-panel; do
  printf "  %-13s %s / %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)" "$(systemctl is-enabled $u 2>/dev/null)"
done
python3 - <<'PY'
import json, urllib.request
checks = [("llama-server", "http://127.0.0.1:8080/health"),
          ("llama-panel", "http://127.0.0.1:8090/api/state")]
for name, url in checks:
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            body = r.read().decode()
        if name == "llama-panel":
            d = json.loads(body)
            print(f"  {name}: OK   running={d.get('running')}   loaded={(d.get('loaded') or {}).get('id')}")
        else:
            print(f"  {name}: OK   {body[:40]}")
    except Exception as e:
        print(f"  {name}: 失败 {e}")
PY
echo
echo "  桌面图标: $(ls -1 "$HOME/桌面/llama-chat.desktop" 2>/dev/null || echo 未创建)"
echo "  启动脚本: $HOME/llama-ui/shell/launch.sh"
echo "  日志    : $HOME/llama-ui/shell/shell.log"

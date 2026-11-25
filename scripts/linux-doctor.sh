#!/usr/bin/env bash
# ============================================================
#  linux-doctor.sh —— llama.cpp 环境的「体检」脚本
#  用法： bash linux-doctor.sh
#  它只读取信息，不安装、不修改任何东西
# ============================================================
set -u
ok()   { printf "  \033[32m[OK]\033[0m   %s\n" "$*"; }
warn() { printf "  \033[33m[注意]\033[0m %s\n" "$*"; }
bad()  { printf "  \033[31m[缺失]\033[0m %s\n" "$*"; }
sec()  { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

sec "1. 系统"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  ok "系统: ${PRETTY_NAME:-unknown}"
else
  warn "读不到 /etc/os-release"
fi
ok "内核: $(uname -r)   架构: $(uname -m)"
ok "当前用户: $(whoami)   主目录: $HOME"

sec "2. 显卡驱动"
if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi >/dev/null 2>&1; then
    ok "nvidia-smi 可用"
    nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv,noheader | sed 's/^/        /'
  else
    bad "nvidia-smi 存在但执行失败（驱动装了但没加载，常见于刚装完没重启）"
  fi
else
  bad "没有 nvidia-smi —— NVIDIA 驱动没装"
fi
if ls /dev/nvidia0 >/dev/null 2>&1; then ok "设备节点 /dev/nvidia0 存在"; else bad "缺少 /dev/nvidia0"; fi

sec "3. CUDA 运行时"
if command -v nvcc >/dev/null 2>&1; then ok "nvcc: $(nvcc --version | tail -1)"; else warn "没有 nvcc（不是必须，预编译包只要驱动）"; fi
if ldconfig -p 2>/dev/null | grep -q libcuda.so.1; then ok "libcuda.so.1 已注册"; else bad "找不不到 libcuda.so.1"; fi

sec "4. 磁盘空间"
df -h / /home 2>/dev/null | sed 's/^/        /'

sec "5. Windows 分区（NTFS）"
if command -v lsblk >/dev/null 2>&1; then
  lsblk -f 2>/dev/null | grep -Ei 'ntfs|bitlocker' | sed 's/^/        /' || warn "没有找到 NTFS 分区"
else
  warn "没有 lsblk"
fi
if mount 2>/dev/null | grep -qi 'type ntfs'; then
  ok "已有 NTFS 分区挂载:"
  mount | grep -i 'type ntfs' | sed 's/^/        /'
else
  warn "当前没有挂载任何 NTFS 分区（后面要用 Windows 上的模型就得先挂载）"
fi

sec "6. 是否已经装过 llama.cpp"
found=""
for p in "$HOME/llama.cpp" /opt/llama.cpp "$HOME/Downloads/llama.cpp"; do
  [ -d "$p" ] && { ok "目录存在: $p"; found=1; }
done
if command -v llama-server >/dev/null 2>&1; then ok "PATH 里有 llama-server: $(command -v llama-server)"; found=1; fi
[ -z "$found" ] && warn "没找到 llama.cpp 目录（还没装）"

sec "7. 端口占用"
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -qE ':(8080|8090)\b'; then
    ok "8080 / 8090 有监听:"
    ss -ltnp 2>/dev/null | grep -E ':(8080|8090)\b' | sed 's/^/        /'
  else
    ok "8080 / 8090 都空着（没在跑）"
  fi
else
  warn "没有 ss 命令"
fi

sec "8. 浏览器与基础工具"
for c in curl python3 tmux; do
  if command -v $c >/dev/null 2>&1; then ok "$c: $(command -v $c)"; else warn "缺少 $c"; fi
done

sec "9. 内存"
free -h 2>/dev/null | sed 's/^/        /'

sec "10. 能否访问外网（下载模型/构建要用）"
if curl -sS -I --max-time 8 https://github.com >/dev/null 2>&1; then
  ok "github.com 可访问"
else
  warn "github.com 访问失败或超时（可能需要代理）"
fi

printf "\n\033[36m== 结论 ==\033[0m\n"
printf "  把上面从「== 1. 系统 ==」到最后的内容，整体复制发给 AI 即可。\n\n"

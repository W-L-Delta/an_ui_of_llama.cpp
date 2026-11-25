#!/usr/bin/env bash
# ============================================================
#  01-gpu-check.sh —— 显卡驱动诊断（只读，不修改）
#  用法： bash 01-gpu-check.sh
#  输出会同时显示在终端，可配合 tee 存到共享盘
# ============================================================
set -u
sec() { printf "\n===== %s =====\n" "$*"; }
note() { printf "  -> %s\n" "$*"; }

sec "系统"
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
echo "内核: $(uname -r)  架构: $(uname -m)"

sec "显卡硬件"
if command -v lspci >/dev/null 2>&1; then
  lspci | grep -i -E 'vga|3d|display' || echo "没识别到显卡（异常）"
else
  note "没有 lspci（缺 pciutils）"
fi

sec "已安装的 NVIDIA 包"
dpkg -l 2>/dev/null | grep -E '^ii +nvidia-(driver|dkms|utils|kernel|firmware)' | awk '{print $2, $3}' || echo "没有相关包"

sec "驱动版本（内核模块）"
if [ -r /proc/driver/nvidia/version ]; then
  cat /proc/driver/nvidia/version
else
  echo "无 /proc/driver/nvidia/version  ->  内核模块没加载"
fi

sec "模块加载状态"
lsmod 2>/dev/null | grep -i -E 'nvidia|nouveau' || echo "nvidia 和 nouveau 都没加载"

sec "当前内核的 DKMS 模块"
if [ -d "/lib/modules/$(uname -r)/updates/dkms" ]; then
  ls "/lib/modules/$(uname -r)/updates/dkms" | head -20
else
  echo "没有 /lib/modules/$(uname -r)/updates/dkms  ->  驱动没为当前内核构建"
fi

sec "Secure Boot 状态"
if command -v mokutil >/dev/null 2>&1; then
  mokutil --sb-state 2>&1
else
  echo "没有 mokutil 命令"
fi

sec "内核日志（显卡相关，最后 15 条）"
if sudo -n true 2>/dev/null; then
  sudo dmesg | grep -i -E 'nvidia|nvrm|nouveau|NVRM' | tail -15
else
  echo "（需要 sudo 才能读 dmesg，下面这行会问密码）"
  sudo dmesg 2>/dev/null | grep -i -E 'nvidia|nvrm|nouveau|NVRM' | tail -15
fi

sec "Ubuntu 推荐驱动"
if command -v ubuntu-drivers >/dev/null 2>&1; then
  ubuntu-drivers devices 2>/dev/null | head -20
else
  echo "没有 ubuntu-drivers（可 sudo apt install ubuntu-drivers-common）"
fi

sec "分区（含 Windows 盘）"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null

sec "结论提示"
cat <<'EOT'
  NVIDIA-SMI 若报 "No devices were found"：
    - "模块加载状态"里只有 nouveau     -> 在用开源驱动，需装 NVIDIA 驱动
    - 两个都没有                      -> 内核模块没加载（DKMS 构建失败 / Secure Boot 拦截）
    - Secure Boot 显示 enabled        -> 需要给模块签名或关闭 Secure Boot
EOT
printf "\n诊断完成。若用 tee 保存，报告文件就在共享盘上，回到 Windows 可以直接看。\n"

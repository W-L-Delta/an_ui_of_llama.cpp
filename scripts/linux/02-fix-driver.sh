#!/usr/bin/env bash
# ============================================================
#  02-fix-driver.sh —— 修显卡驱动
#
#  诊断结论（来自 dmesg）：
#     NVRM: installed in this system requires use of the NVIDIA open kernel modules.
#     NVRM: GPU 0000:01:00.0: RmInitAdapter failed! (0x22:0x56:1017)
#  => 你的 RTX 5060 (Blackwell GB206) 必须用「开源内核模块」版本，
#     现在装的是闭源 nvidia-driver-595，所以认不到卡。
#
#  这个脚本会：
#     1. 已经在用 open 版 -> 只做验证
#     2. 没装 open 版     -> 安装 nvidia-driver-595-open（会替换闭源版）
# ============================================================
set -u
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "当前状态"
if nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi 已经能用了，说明显卡正常。"
  nvidia-smi
  echo
  echo "无需再操作。"
  exit 0
fi
echo "nvidia-smi 仍不可用："
nvidia-smi 2>&1 | head -5

open_installed=""
for p in nvidia-kernel-source-595-open nvidia-dkms-595-open nvidia-driver-595-open; do
  if dpkg -l "$p" 2>/dev/null | grep -q '^ii'; then open_installed="$p"; break; fi
done

if [ -n "$open_installed" ]; then
  say "开源模块已安装（$open_installed），但还没生效"
  echo "原因通常是：装完没重启，或者装的时候内核模块没编译。"
  echo "请先重启： sudo reboot"
  echo "重启后再跑同一条命令（run.sh）复查。"
  exit 0
fi

say "准备安装开源内核模块版本"
cat <<'EOT'
将执行：
    sudo apt-get update
    sudo apt-get install -y nvidia-driver-595-open

影响：
  - 会卸载闭源的 nvidia-driver-595，换成 -open 版本
  - 版本号仍是 595.84，只是内核模块换了实现
  - 需要下载约 300-600 MB，几分钟
  - 装完必须重启
EOT
printf "\n继续吗？输入 y 回车，其他任意键取消："
read -r ans
case "$ans" in
  y|Y) ;;
  *) echo "已取消，什么都没改。"; exit 1 ;;
esac

say "开始安装（需要输入 sudo 密码，输入时屏幕不显示字符）"
sudo apt-get update || { echo "apt update 失败，先检查网络"; exit 1; }
if sudo apt-get install -y nvidia-driver-595-open; then
  say "安装完成"
  echo "下一步：重启系统"
  echo "    sudo reboot"
  echo "重启后回到 Ubuntu，再跑同一条 run.sh（会自动跳到验证）"
else
  echo
  echo "安装失败。常见原因："
  echo "  - 有其他 apt 进程在跑（稍等再试）"
  echo "  - 网络问题（重试即可）"
  exit 1
fi

#!/usr/bin/env bash
# ============================================================
#  03-fix-watttoolkit.sh —— 修 Linux 下 Watt Toolkit 打不开
#
#  常见原因只有三个：
#    1. AppImage 没有执行权限（chmod +x 就好）
#    2. 缺 libfuse2（AppImage 的运行依赖）
#    3. 用了 root 运行（Chromium 内核要 --no-sandbox）
#
#  本脚本只做检测 + 加执行权限，不会自动启动程序
# ============================================================
set -u
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "搜索 Watt Toolkit / Steam++ 相关文件"
found=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  found=1
  printf "  找到: %s\n" "$f"
  if [ -d "$f" ]; then
    printf "        类型: 目录（解压版）\n"
    ls -1 "$f" | head -8 | sed 's/^/          /'
  else
    printf "        类型: %s  权限: %s\n" "$(file -b --mime-type "$f" 2>/dev/null || echo 未知)" "$(stat -c %A "$f")"
  fi
done < <(find "$HOME" -maxdepth 3 \( -iname '*watt*' -o -iname '*steam++*' -o -iname '*steamplusplus*' \) 2>/dev/null | head -20)

if [ -z "$found" ]; then
  echo "  没找到。你可能下在别的位置，或者文件名不含 watt/steam++。"
  echo "  先用这个看看最近下载了什么："
  echo "      ls -lt ~/Downloads | head"
  exit 0
fi

say "检查 AppImage 运行依赖"
if dpkg -l 2>/dev/null | grep -qE '^ii  libfuse2'; then
  echo "  libfuse2 已安装"
else
  echo "  缺 libfuse2（AppImage 需要它）"
  echo "  修复命令： sudo apt install -y libfuse2"
fi

say "怎么启动"
cat <<'EOT'
  如果是 .AppImage 文件：
      chmod +x 文件路径
      ./文件路径
    若仍报 FUSE 错误，用免 FUSE 方式：
      ./文件路径 --appimage-extract-and-run

  如果是解压出来的目录：
      cd 目录
      chmod +x Watt* Steam* 2>/dev/null
      ./Watt...     （或者看图标的实际文件名）

  如果提示 "Running as root without --no-sandbox is not supported"：
      不要用 sudo 运行它；用普通用户跑即可
EOT

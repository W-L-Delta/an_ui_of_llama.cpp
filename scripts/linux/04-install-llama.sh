#!/usr/bin/env bash
# ============================================================
#  04-install-llama.sh —— 从共享盘安装 llama.cpp（Linux, CUDA）
#
#  Windows 侧已经下好两个包，放在：
#     D:\llama.cpp\dist\linux\
#         llama-b12681-bin-ubuntu-cuda-13.5-x64.tar.gz   (214 MB)
#         cudart-llama-b12681-bin-ubuntu-cuda-13.5-x64.tar.gz (424 MB)
#
#  本脚本把它们解压到 ~/llama.cpp，并把 CUDA 运行时库放到程序旁边，
#  最后跑一次 --list-devices 验证显卡能被 llama.cpp 认到。
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/linux"
DEST="$HOME/llama.cpp"
MAIN="llama-b12681-bin-ubuntu-cuda-13.5-x64.tar.gz"
CUDART="cudart-llama-b12681-bin-ubuntu-cuda-13.5-x64.tar.gz"

say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "检查安装包"
for f in "$MAIN" "$CUDART"; do
  if [ -f "$PKG/$f" ]; then
    printf "  [OK]   %s  (%s MB)\n" "$f" "$(awk -v b="$(stat -c %s "$PKG/$f")" 'BEGIN{printf "%.1f", b/1048576}')"
  else
    printf "  [缺失] %s\n" "$f"
    echo "  期望位置: $PKG"
    exit 1
  fi
done

say "解压到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$PKG/$MAIN"   -C "$DEST" || { echo "主包解压失败"; exit 1; }
tar -xzf "$PKG/$CUDART" -C "$DEST" || { echo "CUDA 运行时解压失败"; exit 1; }
# 把 CUDA 运行时库复制到程序目录旁边，避免依赖系统 CUDA
cp -f "$DEST"/cudart-*/*.so* "$DEST"/llama-b12681/ 2>/dev/null
echo "  完成"

BIN="$DEST/llama-b12681"
say "版本"
( cd "$BIN" && LD_LIBRARY_PATH="$BIN" ./llama-server --version 2>&1 | head -3 )

say "是否识别到 CUDA 显卡"
( cd "$BIN" && LD_LIBRARY_PATH="$BIN" ./llama-server --list-devices 2>&1 | head -20 )

say "完成"
cat <<EOT
  程序目录: $BIN
  用法示例（先别急着跑，下一步会给完整启动命令）：
      cd $BIN
      LD_LIBRARY_PATH=$BIN ./llama-server -m /home/\$USER/WinD/llama.cpp/models/Qwen3.5-9B-Q4_K_M.gguf -ngl 35 -c 8192 --port 8080
EOT

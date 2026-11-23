#!/usr/bin/env bash
# ============================================================
#  llama-local-chat · Linux 一键安装（clone + setup）
#
#  一条命令：
#     curl -fsSL https://raw.githubusercontent.com/W-L-Delta/an_ui_of_llama.cpp/linux/scripts/install-linux.sh | bash
#
#  参数会透传给 setup-linux.sh，例如：
#     ... | bash -s -- --backend vulkan
#
#  环境变量：
#     LLAMA_DIR    装到哪（默认 ~/llama-local）
#     LLAMA_REPO   仓库地址
#     LLAMA_BRANCH 分支（默认 linux）
# ============================================================
set -euo pipefail

REPO="${LLAMA_REPO:-https://github.com/W-L-Delta/an_ui_of_llama.cpp.git}"
BRANCH="${LLAMA_BRANCH:-linux}"
DIR="${LLAMA_DIR:-$HOME/llama-local}"

say()  { printf '%s\n' "$*"; }
die()  { printf '  XX  %s\n' "$*" >&2; exit 1; }

command -v git   >/dev/null || die "需要 git（apt install git）"
command -v curl  >/dev/null || die "需要 curl"

if [ -d "$DIR/.git" ]; then
  say "  已有仓库，更新到最新：$DIR"
  git -C "$DIR" fetch origin "$BRANCH" --depth 1
  git -C "$DIR" checkout "$BRANCH"
  git -C "$DIR" pull --ff-only origin "$BRANCH" || true
else
  say "  克隆到 $DIR（分支 $BRANCH）"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$DIR"
fi

exec bash "$DIR/scripts/setup-linux.sh" "$@"

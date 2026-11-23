#!/usr/bin/env bash
# ============================================================
#  llama-local-chat · Linux 安装（在已 clone 的仓库里运行）
#
#  做四件事：
#    1. 检查依赖（python3 / curl）
#    2. 按显卡下载 llama.cpp 预编译包到 bin/<backend>/
#    3. 生成 scripts/llama.conf.ini（路径改成 Linux 风格）
#    4. 安装 systemd 用户服务 + 桌面入口
#
#  用法：
#     ./scripts/setup-linux.sh               自动判断显卡
#     ./scripts/setup-linux.sh --backend cuda
#     ./scripts/setup-linux.sh --backend vulkan|cpu|rocm
#     ./scripts/setup-linux.sh --no-service  不动 systemd
#     ./scripts/setup-linux.sh --dry-run     只打印计划
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${LLAMA_CPP_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BACKEND="auto"
INSTALL_SERVICE=1
DRY=0
MIRROR="${LLAMA_MIRROR:-https://gh-proxy.com/}"

while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="${2:-auto}"; shift 2 ;;
    --no-service) INSTALL_SERVICE=0; shift ;;
    --dry-run) DRY=1; shift ;;
    --mirror) MIRROR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { printf '    OK  %s\n' "$*"; }
warn() { printf '    !!  %s\n' "$*"; }
die()  { printf '    XX  %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ 1. 依赖
step 1 "检查环境"
command -v python3 >/dev/null || die "需要 python3（面板是纯标准库的，装上就行）"
ok "python3 $(python3 -c 'import sys;print(".".join(map(str,sys.version_info[:3])))')"
command -v curl >/dev/null || die "需要 curl"
ok "curl"
command -v tar >/dev/null || die "需要 tar"
ok "tar"

HAS_NV=0; command -v nvidia-smi >/dev/null 2>&1 && HAS_NV=1
HAS_AMD=0; command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qiE 'vga.*(amd|ati)' && HAS_AMD=1
HAS_VK=0
[ -n "$(ls /usr/lib/x86_64-linux-gnu/libvulkan.so* 2>/dev/null)" ] && HAS_VK=1
command -v vulkaninfo >/dev/null 2>&1 && HAS_VK=1

if [ "$BACKEND" = "auto" ]; then
  if [ "$HAS_NV" = "1" ]; then BACKEND="cuda"
  elif [ "$HAS_AMD" = "1" ] && [ -d /opt/rocm ]; then BACKEND="rocm"
  elif [ "$HAS_VK" = "1" ]; then BACKEND="vulkan"
  else BACKEND="cpu"; fi
fi
ok "计算后端：$BACKEND"
[ "$BACKEND" = "cuda" ] && [ "$HAS_NV" = "0" ] && warn "选了 cuda 但没找到 nvidia-smi"
[ "$BACKEND" = "vulkan" ] && [ "$HAS_VK" = "0" ] && warn "没检测到 Vulkan 运行时（可能要装 mesa-vulkan-drivers）"

# ------------------------------------------------------------ 2. 下载 llama.cpp
step 2 "准备 llama.cpp"
BIN_DIR="$ROOT/bin/$BACKEND"
SERVER_BIN="$BIN_DIR/llama-server"

if [ -x "$SERVER_BIN" ]; then
  ok "已存在：$SERVER_BIN"
else
  command -v jq >/dev/null && HAVE_JQ=1 || HAVE_JQ=0
  say "    查询最新版本…"
  API="https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15"
  JSON="$( [ "$DRY" = "1" ] && echo '' || curl -fsSL --max-time 40 -H 'User-Agent: llama-local-setup' "$API" )"

  if [ "$DRY" = "1" ]; then
    say "    （dry-run：跳过下载）"
  else
    # 选版本：第一个带对应 Ubuntu 包的 release
    case "$BACKEND" in
      cuda)   PAT='-bin-ubuntu-cuda-12\.8-x64\.tar\.gz$' ;;
      vulkan) PAT='-bin-ubuntu-vulkan-x64\.tar\.gz$' ;;
      rocm)   PAT='-bin-ubuntu-rocm-[0-9.]+-x64\.tar\.gz$' ;;
      *)      PAT='-bin-ubuntu-x64\.tar\.gz$' ;;
    esac

    read -r TAG URL < <(python3 - "$JSON" "$PAT" <<'PY'
import json, re, sys
data = json.loads(sys.argv[1]); pat = sys.argv[2]
for rel in data:
    for a in rel.get("assets", []):
        if re.search(pat, a["name"]):
            print(rel["tag_name"], a["browser_download_url"]); raise SystemExit
raise SystemExit(0)
PY
)
    [ -n "${TAG:-}" ] || die "近 15 个版本里没有 Linux $BACKEND 包，试试 --backend vulkan 或 cpu"
    say "    版本 $TAG"

    mkdir -p "$BIN_DIR"
    TMP="$(mktemp -d)"
    fetch() {
      local url="$1" out="$2" p
      for p in "" "$MIRROR"; do
        local u="$url"; [ -n "$p" ] && u="${p%/}/$url"
        say "    下载 $(basename "$out")（${p:-直连}）…"
        if curl -fL --max-time 1800 -o "$out" "$u"; then return 0; fi
      done
      return 1
    }
    fetch "$URL" "$TMP/llama.tar.gz" || die "下载失败"
    say "    解压…"
    tar -xzf "$TMP/llama.tar.gz" -C "$BIN_DIR" --strip-components=1 2>/dev/null \
      || tar -xzf "$TMP/llama.tar.gz" -C "$BIN_DIR"

    # CUDA 还需要 cudart
    if [ "$BACKEND" = "cuda" ]; then
      CU_URL="$(python3 - "$JSON" <<'PY'
import json, re, sys
for rel in json.loads(sys.argv[1]):
    for a in rel.get("assets", []):
        if re.search(r'^cudart-.*-bin-ubuntu-cuda-12\.8-x64\.tar\.gz$', a["name"]):
            print(a["browser_download_url"]); raise SystemExit
PY
)"
      if [ -n "$CU_URL" ]; then
        fetch "$CU_URL" "$TMP/cudart.tar.gz" && tar -xzf "$TMP/cudart.tar.gz" -C "$BIN_DIR"
      fi
    fi

    chmod +x "$BIN_DIR"/llama-* 2>/dev/null || true
    rm -rf "$TMP"
    [ -x "$SERVER_BIN" ] || die "解压后没找到 llama-server，检查 bin/$BACKEND 内容"
    ok "$("$SERVER_BIN" --version 2>&1 | head -n1)"
  fi
fi

# ------------------------------------------------------------ 3. 配置
step 3 "生成配置"
CONF="$ROOT/scripts/llama.conf.ini"
if [ -f "$CONF" ]; then
  ok "已存在，保留不动：scripts/llama.conf.ini"
else
  SRC="$ROOT/scripts/llama.conf.example.ini"
  [ -f "$SRC" ] || die "缺少 scripts/llama.conf.example.ini"
  if [ "$DRY" = "1" ]; then
    say "    （dry-run：将生成 scripts/llama.conf.ini）"
  else
    sed -e 's#models\\#models/#g' \
        -e "s#^workspace .*#workspace  = $HOME/llama-workspace#" \
        "$SRC" > "$CONF"
    mkdir -p "$HOME/llama-workspace"
    ok "已生成 scripts/llama.conf.ini（workspace = ~/llama-workspace）"
  fi
fi
mkdir -p "$ROOT/models"
GGUF_COUNT=$(find "$ROOT/models" -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')
if [ "$GGUF_COUNT" = "0" ]; then
  warn "models/ 里还没有 .gguf，放一个模型进去（配置里 [model] 指向它）"
else
  ok "已发现 $GGUF_COUNT 个 gguf"
fi

# ------------------------------------------------------------ 4. 服务与入口
if [ "$INSTALL_SERVICE" = "1" ] && [ "$DRY" = "0" ]; then
  step 4 "安装 systemd 用户服务与桌面入口"

  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  sed -e "s#%h/llama-local#$ROOT#g" \
      "$ROOT/scripts/llama-server.service" > "$UNIT_DIR/llama-server.service"
  ok "已写入 $UNIT_DIR/llama-server.service"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || warn "daemon-reload 失败（可能不是 systemd 会话）"
    say "    启用服务（开机自启）…"
    systemctl --user enable llama-server 2>/dev/null && ok "已 enable" || warn "enable 失败"
    say "    提示：若想不登录也运行，执行  sudo loginctl enable-linger $USER"
  else
    warn "没有 systemctl，跳过服务安装"
  fi

  DESK_DIR="$HOME/.local/share/applications"
  mkdir -p "$DESK_DIR"
  sed -e "s#\$HOME/llama-local#$ROOT#g" \
      "$ROOT/scripts/llama-local.desktop" > "$DESK_DIR/llama-local.desktop"
  ok "已写入 $DESK_DIR/llama-local.desktop"
fi

cat <<EOF

安装完成。

  放模型：    把 .gguf 放进 $ROOT/models，改 $CONF 的 [model]
  起服务：    $ROOT/scripts/start-llama.sh
              （或用 systemd：systemctl --user start llama-server）
  开界面：    $ROOT/scripts/open-panel.sh
              （或从应用菜单点「llama.cpp 对话与控制台」）
  看状态：    $ROOT/scripts/start-llama.sh --status
EOF

#!/usr/bin/env bash
# ============================================================
#  08-install-ui.sh —— 装控制台面板 + 网页聊天（Linux 版）
#
#  做的事：
#    1. 停掉 07 里手动起的 llama-server（避免端口冲突）
#    2. 把 Windows 盘上的 UI 包复制到 ~/llama-ui
#    3. 生成 Linux 用的配置（把 models\xxx 改成指向 Windows 盘的真实路径）
#    4. 放一个 bin/cuda/llama-server 包装脚本，让启动器找得到
#    5. 用 scripts/start-llama.sh 启动服务（它自己会等就绪）
#    6. 后台起面板（8090）并验证
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
LLAMA_BIN="$HOME/llama.cpp/llama-b12681"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 检查 UI 包"
[ -d "$PKG" ] || { echo "  找不到 $PKG"; exit 1; }
echo "  来源: $PKG"

say "2. 停掉手动启动的服务"
if [ -f "$HOME/llama-server.pid" ]; then
  kill "$(cat "$HOME/llama-server.pid")" 2>/dev/null && echo "  已停手动实例"
fi
pkill -f 'llama-b12681/llama-server' 2>/dev/null
sleep 2
pgrep -af 'llama-server' || echo "  当前无实例"

say "3. 复制到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$PKG/." "$DEST/"
chmod +x "$DEST"/scripts/*.sh 2>/dev/null
echo "  完成: $(find "$DEST" -type f | wc -l) 个文件"

say "4. 生成 Linux 配置"
WIN_MODELS="$HOME/WinD/llama.cpp/models"
if [ ! -d "$WIN_MODELS" ]; then
  echo "  找不到模型目录 $WIN_MODELS"
  exit 1
fi
python3 - "$DEST" "$WIN_MODELS" <<'PY'
import pathlib, re, sys
dest = pathlib.Path(sys.argv[1]); win_models = sys.argv[2]
src = dest / "scripts" / "llama.conf.windows.ini"
out = dest / "scripts" / "llama.conf.ini"
if not src.exists():
    print("  缺少 llama.conf.windows.ini"); raise SystemExit(1)
lines = []
changed = 0
for line in src.read_text(encoding="utf-8-sig").splitlines():
    m = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$", line)
    if m and not line.lstrip().startswith(("#", ";")):
        key, val = m.group(2), m.group(3)
        if "\\" in val or val.startswith("models/"):
            norm_abs = val.replace("\\", "/")
            if len(norm_abs) > 2 and norm_abs[1] == ":":
                # 绝对 Windows 路径：D:\xxx -> 映射到 Linux
                if "工作区" in norm_abs:
                    new = str(pathlib.Path.home() / "llama-work")
                elif norm_abs.lower().startswith("d:/llama.cpp"):
                    new = str(pathlib.Path.home() / "WinD" / norm_abs[3:])
                elif "/models/" in norm_abs.lower():
                    new = win_models + "/" + norm_abs.split("/models/", 1)[1]
                else:
                    new = str(pathlib.Path.home() / "llama-work")
                line = f"{m.group(1)}{key} = {new}"
                changed += 1
                lines.append(line)
                continue
            if val.replace("\\", "/").startswith("models/"):
                new = win_models + "/" + val.replace("\\", "/")[len("models/"):]
            elif val.replace("\\", "/").startswith("scripts/"):
                new = str(dest / val.replace("\\", "/"))
            else:
                new = win_models + "/" + val.replace("\\", "/")
            line = f"{m.group(1)}{key} = {new}"
            changed += 1
    lines.append(line)
out.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"  改写 {changed} 处路径")
PY

# 关掉多模型模式（Linux 上先按单模型跑通）
python3 - "$DEST/scripts/llama.conf.ini" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
s = re.sub(r"(?m)^(\s*enabled\s*=\s*)true(\s*)$", r"\1false\2", s, count=1)
p.write_text(s, encoding="utf-8")
print("  已确保 [router] enabled = false")
PY

echo "  模型路径检查："
grep -E '^\s*(model|mmproj|preset)\s*=' "$DEST/scripts/llama.conf.ini" | head -6 | sed 's/^/    /'
for f in $(grep -E '^\s*model\s*=' "$DEST/scripts/llama.conf.ini" | cut -d= -f2- | tr -d ' '); do
  [ -f "$f" ] && echo "    [OK] $f" || echo "    [缺失] $f"
done

say "5. 放 llama-server 包装（启动器按 bin/cuda 找）"
mkdir -p "$DEST/bin/cuda"
cat > "$DEST/bin/cuda/llama-server" <<EOS
#!/bin/sh
export LD_LIBRARY_PATH="$LLAMA_BIN\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$LLAMA_BIN/llama-server" "\$@"
EOS
chmod +x "$DEST/bin/cuda/llama-server"
"$DEST/bin/cuda/llama-server" --version 2>&1 | head -2 | sed 's/^/    /'

say "6. 启动 llama-server（走项目自带启动脚本）"
cd "$DEST" || exit 1
bash scripts/start-llama.sh 2>&1 | tail -15

say "7. 启动控制台面板（8090）"
pkill -f 'llama-ui/panel/app.py' 2>/dev/null
sleep 1
setsid --fork env bash -lc "cd '$DEST' && exec python3 panel/app.py --port 8090" >> "$DEST/panel/panel.out" 2>&1
sleep 3
python3 - <<'PY'
import time, urllib.request, json
ok = False
for i in range(40):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8090/api/state", timeout=2) as r:
            if r.status == 200:
                d = json.loads(r.read().decode())
                ok = True
                print(f"  面板就绪（{i} 秒）")
                print(f"  服务运行: {d.get('running')}   已加载: {(d.get('loaded') or {}).get('id')}")
                m = d.get("models") or {}
                print(f"  识别到模型: {list(m.keys())}")
                break
    except Exception:
        pass
    time.sleep(1)
if not ok:
    print("  面板启动失败，看 ~/llama-ui/panel/panel.out")
PY

say "完成"
cat <<EOT
  控制台:  http://127.0.0.1:8090      （参数调整 / 模型切换 / 皮肤）
  聊天:    http://127.0.0.1:8090/chat （你 Windows 上用的那套界面）
  自带 UI: http://127.0.0.1:8080      （llama.cpp 原生页面）

  停止面板: pkill -f 'llama-ui/panel/app.py'
  停止服务: bash ~/llama-ui/scripts/start-llama.sh --stop
EOT

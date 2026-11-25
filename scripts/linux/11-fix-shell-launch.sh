#!/usr/bin/env bash
# ============================================================
#  11-fix-shell-launch.sh —— 修「图标点了没反应 / 桌面放不上快捷方式」
#
#  两个真实原因：
#    1. 桌面目录不是 ~/Desktop，中文系统是 ~/桌面（用 xdg-user-dir 取）
#    2. 图标点击后没有窗口，是因为进程静默报错（Terminal=false 看不到）
#       -> 改成带日志的启动方式，并让程序把异常写进 shell.log
# ============================================================
set -u
DEST="$HOME/llama-ui"
SHELL_DIR="$DEST/shell"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 找出真正的桌面目录"
DESKTOP_DIR=""
if command -v xdg-user-dir >/dev/null 2>&1; then
  DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null)"
fi
[ -z "${DESKTOP_DIR:-}" ] && [ -d "$HOME/Desktop" ] && DESKTOP_DIR="$HOME/Desktop"
[ -z "${DESKTOP_DIR:-}" ] && [ -d "$HOME/桌面" ] && DESKTOP_DIR="$HOME/桌面"
echo "  桌面目录: ${DESKTOP_DIR:-（未找到）}"

say "2. 重写外壳程序（带日志、带自检）"
mkdir -p "$SHELL_DIR"
cat > "$SHELL_DIR/llama_chat.py" <<'PYEOF'
#!/usr/bin/env python3
# ============================================================
#  llama_chat.py —— 独立窗口外壳（GTK3 + WebKit2）
#  带日志：任何异常都会写到同目录的 shell.log，不再"静默失败"
#  自检： python3 llama_chat.py --check
# ============================================================
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "shell.log")
URL = "http://127.0.0.1:8090/chat"
TITLE = "llama.cpp 本地对话"

# NVIDIA 混合显卡 / Wayland 上 WebKit 的常见修复
os.environ.setdefault("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")


def log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(msg.rstrip() + "\n")
    except OSError:
        pass


def check():
    print("DISPLAY        =", os.environ.get("DISPLAY"))
    print("WAYLAND_DISPLAY=", os.environ.get("WAYLAND_DISPLAY"))
    print("XDG_SESSION_TYPE=", os.environ.get("XDG_SESSION_TYPE"))
    try:
        import gi
        print("pygobject      = OK")
    except Exception as e:
        print("pygobject      = 失败:", e)
        return 2
    try:
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk
        print("GTK            =", Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version())
    except Exception as e:
        print("GTK            = 失败:", e)
        return 2
    for ver in ("4.1", "4.0"):
        try:
            gi.require_version("WebKit2", ver)
            from gi.repository import WebKit2  # noqa: F401
            print("WebKit2        =", ver)
            break
        except Exception as e:
            print("WebKit2", ver, "= 不可用:", e)
    else:
        return 2
    try:
        ok = Gtk.init_check(sys.argv[:1])
        print("Gtk.init_check =", "OK" if (ok[0] if isinstance(ok, tuple) else ok) else "失败（没有可用显示）")
    except Exception as e:
        print("Gtk.init_check = 异常:", e)
    return 0


def main():
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk

        WebKit = None
        for ver in ("4.1", "4.0"):
            try:
                gi.require_version("WebKit2", ver)
                from gi.repository import WebKit2 as WebKit  # noqa: F401
                break
            except Exception:
                continue
        if WebKit is None:
            log("错误：找不到 WebKit2（装 gir1.2-webkit2-4.1）")
            return 2

        log("启动：DISPLAY=%s WAYLAND_DISPLAY=%s" % (os.environ.get("DISPLAY"), os.environ.get("WAYLAND_DISPLAY")))

        win = Gtk.Window(title=TITLE)
        win.set_default_size(1280, 860)
        icon = os.path.join(HERE, "icon.png")
        if os.path.isfile(icon):
            try:
                win.set_icon_from_file(icon)
            except Exception as e:
                log("设置图标失败（忽略）: %r" % (e,))

        web = WebKit.WebView()
        web.load_uri(URL)

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.props.title = TITLE

        btn_reload = Gtk.Button(label="刷新")
        btn_reload.connect("clicked", lambda *_: web.reload())
        header.pack_start(btn_reload)

        btn_console = Gtk.Button(label="控制台")
        btn_console.connect("clicked", lambda *_: web.load_uri("http://127.0.0.1:8090/"))
        header.pack_end(btn_console)

        win.set_titlebar(header)
        win.add(web)
        win.connect("destroy", Gtk.main_quit)
        win.show_all()
        log("窗口已显示")
        Gtk.main()
        log("窗口关闭")
        return 0
    except Exception:
        log("崩溃：\n" + traceback.format_exc())
        return 1


if __name__ == "__main__":
    if "--check" in sys.argv:
        raise SystemExit(check())
    raise SystemExit(main())

PYEOF
chmod +x "$SHELL_DIR/llama_chat.py"
if [ -f "$DEST/web/skins/icons/default.png" ]; then
  cp -f "$DEST/web/skins/icons/default.png" "$SHELL_DIR/icon.png"
  echo "  图标已复制"
else
  echo "  没找到默认图标（不影响启动）"
fi

say "3. 自检（会打印显示环境与 GTK/WebKit 状态）"
python3 "$SHELL_DIR/llama_chat.py" --check
check_rc=$?
echo "  自检退出码: $check_rc"

say "4. 写桌面条目（Exec 带日志重定向）"
mkdir -p "$HOME/.local/share/applications"
DESKTOP_FILE="$HOME/.local/share/applications/llama-chat.desktop"
cat > "$DESKTOP_FILE" <<EOT
[Desktop Entry]
Type=Application
Name=llama.cpp 本地对话
Comment=本地离线对话（独立窗口）
Exec=/usr/bin/bash -lc '/usr/bin/python3 $SHELL_DIR/llama_chat.py >> $SHELL_DIR/shell.log 2>&1'
Icon=$SHELL_DIR/icon.png
Terminal=false
Categories=Utility;Network;Chat;
Keywords=llama;chat;AI;
StartupWMClass=llama_chat.py
EOT
chmod +x "$DESKTOP_FILE"
echo "  $DESKTOP_FILE"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$DESKTOP_FILE" && echo "  条目校验通过" || echo "  条目校验有警告（一般仍可用）"
fi
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

say "5. 放到桌面"
if [ -n "${DESKTOP_DIR:-}" ] && [ -d "${DESKTOP_DIR}" ]; then
  cp -f "$DESKTOP_FILE" "$DESKTOP_DIR/llama-chat.desktop"
  chmod +x "$DESKTOP_DIR/llama-chat.desktop"
  if command -v gio >/dev/null 2>&1; then
    gio set "$DESKTOP_DIR/llama-chat.desktop" metadata::trusted true 2>/dev/null || true
  fi
  echo "  已复制到 $DESKTOP_DIR/llama-chat.desktop"
else
  echo "  没有桌面目录，跳过"
fi

say "6. 加入左侧程序坞（Dock）"
if command -v gsettings >/dev/null 2>&1; then
  cur="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "[]")"
  case "$cur" in
    *llama-chat.desktop*) echo "  已在 Dock 里" ;;
    *)
      new="$(printf '%s' "$cur" | sed "s/\]$/, 'llama-chat.desktop']/")"
      gsettings set org.gnome.shell favorite-apps "$new" 2>/dev/null \
        && echo "  已加入 Dock：$new" || echo "  加入 Dock 失败（可手动右键图标→添加到收藏）"
      ;;
  esac
fi

say "7. 直接试一次（5 秒后自动关闭窗口）"
echo "  如果你的图形会话正常，这里会闪一下窗口，属正常现象"
timeout 5 python3 "$SHELL_DIR/llama_chat.py" > /dev/null 2>&1
rc=$?
echo "  退出码: $rc  （124 = 超时结束，说明窗口活着；1/2 = 启动失败）"
if [ -f "$SHELL_DIR/shell.log" ]; then
  echo "  日志最后 20 行："
  tail -20 "$SHELL_DIR/shell.log" | sed 's/^/    /'
fi

say "完成"
cat <<EOT
  如果图标仍然没反应，请把这段发给 AI：
      cat $SHELL_DIR/shell.log

  手动启动（能看到实时报错）：
      python3 $SHELL_DIR/llama_chat.py
EOT

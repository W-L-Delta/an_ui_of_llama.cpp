#!/usr/bin/env python3
# ============================================================
#  llama_chat.py —— 独立窗口外壳 v2（GTK3 + WebKit2）
#
#  相比 v1 的改动：
#    · 单实例：重复点击图标不会开第二个窗口（用文件锁）
#    · 统一图标：设置 WM class = llama-chat，Dock 里就是这个图标
#    · 两个标签页：聊天 / 控制台 各自独立，互不顶掉
#    · 控制台页首次切换时才加载，省内存
#  自检： python3 llama_chat.py --check
# ============================================================
import fcntl
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "shell.log")
LOCK = os.path.join(HERE, "shell.lock")
CHAT_URL = "http://127.0.0.1:8090/chat"
CONSOLE_URL = "http://127.0.0.1:8090/"
TITLE = "llama.cpp 本地对话"
WMCLASS = "llama-chat"

os.environ.setdefault("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")


def log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(msg.rstrip() + "\n")
    except OSError:
        pass


def already_running():
    """返回 True 表示已有实例在跑（这次直接退出，避免开第二个窗口）"""
    fh = open(LOCK, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    globals()["_LOCK_HANDLE"] = fh  # 保持引用，进程存活期间锁才有效
    return False


def check():
    print("DISPLAY         =", os.environ.get("DISPLAY"))
    print("WAYLAND_DISPLAY =", os.environ.get("WAYLAND_DISPLAY"))
    print("XDG_SESSION_TYPE=", os.environ.get("XDG_SESSION_TYPE"))
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk
        print("GTK             =", Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version())
    except Exception as e:
        print("GTK             = 失败:", e)
        return 2
    for ver in ("4.1", "4.0"):
        try:
            gi.require_version("WebKit2", ver)
            from gi.repository import WebKit2  # noqa: F401
            print("WebKit2         =", ver)
            return 0
        except Exception:
            continue
    print("WebKit2         = 不可用")
    return 2


def main():
    if already_running():
        log("已有实例在运行，本次启动直接退出")
        return 0
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk, GLib

        WebKit = None
        for ver in ("4.1", "4.0"):
            try:
                gi.require_version("WebKit2", ver)
                from gi.repository import WebKit2 as WebKit  # noqa: F401
                break
            except Exception:
                continue
        if WebKit is None:
            log("错误：找不到 WebKit2")
            return 2

        # 关掉 WebKit 的页面缓存，避免面板更新了页面却仍显示旧版
        try:
            ctx = WebKit.WebContext.get_default()
            ctx.set_cache_model(WebKit.CacheModel.DOCUMENT_VIEWER)
            settings = WebKit.Settings.get_default()
            settings.set_enable_page_cache(False)
        except Exception as e:
            log("关闭页面缓存失败（忽略）: %r" % (e,))

        GLib.set_prgname(WMCLASS)
        GLib.set_application_name(TITLE)

        log("启动 DISPLAY=%s WAYLAND_DISPLAY=%s" % (os.environ.get("DISPLAY"), os.environ.get("WAYLAND_DISPLAY")))

        win = Gtk.Window(title=TITLE)
        win.set_default_size(1280, 860)
        win.set_wmclass(WMCLASS, WMCLASS)   # 让 Dock/任务栏认出这是同一个应用
        icon = os.path.join(HERE, "icon.png")
        if os.path.isfile(icon):
            try:
                win.set_icon_from_file(icon)
            except Exception as e:
                log("设置图标失败（忽略）: %r" % (e,))

        def make_view():
            v = WebKit.WebView()

            def on_create(_view, action):
                try:
                    req = action.get_request()
                    uri = req.get_uri() if req else ""
                except Exception:
                    uri = ""
                if uri:
                    log("窗口内跳转: " + uri)
                    _view.load_uri(uri)
                return None

            def on_fail(_view, _evt, uri, error):
                log("加载失败 %s: %s" % (uri, getattr(error, "message", error)))

            def on_decide(view, decision, decision_type):
                """兜底：页面里任何 file:// 导航一律拒绝，避免拖入图片把窗口带跑"""
                try:
                    if decision_type != WebKit.PolicyDecisionType.NAVIGATION_ACTION:
                        return False
                    action = decision.get_navigation_action()
                    uri = action.get_request().get_uri() if action else ""
                    if uri.startswith("file://") or uri.startswith("file:"):
                        log("拦截 file:// 导航: " + uri)
                        decision.ignore()
                        return True
                except Exception as exc:
                    log("decide-policy 异常: %r" % (exc,))
                return False

            try:
                v.connect("create", on_create)
                v.connect("load-failed", on_fail)
                v.connect("decide-policy", on_decide)
            except Exception as e:
                log("挂载信号失败: %r" % (e,))
            return v

        chat = make_view()
        chat.load_uri(CHAT_URL + "?t=" + str(int(time.time())))
        console = make_view()
        console_state = {"loaded": False}

        nb = Gtk.Notebook()
        nb.set_tab_pos(Gtk.PositionType.TOP)
        nb.set_show_tabs(False)   # 用顶部的「聊天 / 控制台」按钮切换，标签栏省掉
        nb.append_page(chat, Gtk.Label(label="聊天"))
        nb.append_page(console, Gtk.Label(label="控制台"))

        def on_switch(_nb, _page, idx):
            if idx == 1 and not console_state["loaded"]:
                console.load_uri(CONSOLE_URL)
                console_state["loaded"] = True
                log("加载控制台")

        nb.connect("switch-page", on_switch)

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.props.title = TITLE

        def btn(label, fn):
            b = Gtk.Button(label=label)
            b.connect("clicked", lambda *_: fn())
            header.pack_start(b)

        def reload_current():
            idx = nb.get_current_page()
            (console if idx == 1 else chat).reload()

        btn("刷新", reload_current)
        btn("聊天", lambda: nb.set_current_page(0))
        btn("控制台", lambda: nb.set_current_page(1))

        win.set_titlebar(header)
        win.add(nb)
        win.connect("destroy", Gtk.main_quit)
        win.show_all()
        log("窗口已显示")
        Gtk.main()
        log("窗口关闭")
        return 0
    except Exception:
        log("崩溃:\n" + traceback.format_exc())
        return 1


if __name__ == "__main__":
    if "--check" in sys.argv:
        raise SystemExit(check())
    raise SystemExit(main())

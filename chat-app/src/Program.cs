// llama-chat.exe —— llama.cpp 的本地对话窗口（WinForms + WebView2）
//
// 设计：
//   * 界面复用 panel 提供的 /chat 页面（纯本地 http://127.0.0.1:8090），
//     跨域、会话存储、目录浏览都由 panel 的接口负责，这里只做壳。
//   * 启动时若 8090 没在跑，自动拉起 pythonw panel\app.py（隐藏窗口）。
//   * 若 8080 的 llama-server 没在跑，用 windowless-runner 触发一次 -EnsureRunning。
//   * 单向指向控制台：菜单「控制台」和页面里的按钮都只在默认浏览器里打开 8090，
//     控制台不回指本程序。
//
// 编译（PowerShell 5.1 自带 csc.exe）：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /platform:x64
//     /out:chat-app\llama-chat.exe
//     /win32manifest:chat-app\app.manifest
//     /r:Microsoft.Web.WebView2.Core.dll /r:Microsoft.Web.WebView2.WinForms.dll
//     /r:System.Windows.Forms.dll /r:System.Drawing.dll
//     chat-app\src\Program.cs

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace LlamaChat
{
    internal static class Program
    {
        // 项目根目录：从 exe 所在目录向上找，直到发现 panel/app.py
        internal static string FindRoot()
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar));
            for (int i = 0; i < 5 && dir != null; i++, dir = dir.Parent)
            {
                if (File.Exists(Path.Combine(dir.FullName, "panel", "app.py"))) return dir.FullName;
            }
            return AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        }

        internal static readonly string Root = FindRoot();
        internal static readonly string PanelRoot = Path.Combine(Root, "panel");
        internal const string ChatUrl = "http://127.0.0.1:8090/chat";
        internal const string ConsoleUrl = "http://127.0.0.1:8090";
        internal const string StateUrl = "http://127.0.0.1:8090/api/state";
        internal const string HealthUrl = "http://127.0.0.1:8080/health";
        internal static readonly string Runner = Path.Combine(Root, "bin", "windowless-runner.exe");
        internal static readonly string StartScript = Path.Combine(Root, "scripts", "start-llama.ps1");

        internal static bool StartConsole;

        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            foreach (string a in args)
            {
                if (string.Equals(a, "--console", StringComparison.OrdinalIgnoreCase)) StartConsole = true;
            }
            Application.Run(new MainForm());
        }

        private static ConsoleForm consoleForm;

        // 程序内打开控制台（同一个进程里的第二个 WebView2 窗口）
        internal static void OpenConsole()
        {
            EnsurePanel();
            if (consoleForm == null || consoleForm.IsDisposed)
            {
                consoleForm = new ConsoleForm();
                consoleForm.FormClosed += delegate { consoleForm = null; };
                consoleForm.Show();
            }
            else
            {
                if (consoleForm.WindowState == FormWindowState.Minimized)
                    consoleForm.WindowState = FormWindowState.Normal;
                consoleForm.Activate();
            }
        }

        internal static string StateDir
        {
            get
            {
                string dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "llama-chat");
                Directory.CreateDirectory(dir);
                return dir;
            }
        }

        internal static bool Ping(string url, int timeoutMs = 1200)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Timeout = timeoutMs;
                req.Proxy = null;
                req.Method = "GET";
                using (var resp = (HttpWebResponse)req.GetResponse())
                {
                    return (int)resp.StatusCode == 200;
                }
            }
            catch
            {
                return false;
            }
        }

        internal static string FindPythonw()
        {
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string dir in path.Split(';'))
            {
                if (string.IsNullOrWhiteSpace(dir)) continue;
                try
                {
                    string candidate = Path.Combine(dir.Trim(), "pythonw.exe");
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
            }
            string known = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                @"Programs\Python\Python314\pythonw.exe");
            return File.Exists(known) ? known : null;
        }

        internal static void OpenExternal(string url)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch { }
        }

        // 面板没起来就拉起它（隐藏控制台）
        internal static void EnsurePanel()
        {
            if (Ping(StateUrl)) return;
            string pythonw = FindPythonw();
            if (pythonw == null) return;
            try
            {
                var psi = new ProcessStartInfo(pythonw,
                    "\"" + Path.Combine(PanelRoot, "app.py") + "\" --port 8090")
                {
                    WorkingDirectory = PanelRoot,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                Process.Start(psi);
            }
            catch { return; }

            for (int i = 0; i < 60; i++)
            {
                System.Threading.Thread.Sleep(250);
                if (Ping(StateUrl)) return;
            }
        }

        // llama-server 没起来就触发一次保活脚本（不阻塞窗口）
        internal static void EnsureService()
        {
            if (Ping(HealthUrl)) return;
            if (!File.Exists(Runner)) return;
            try
            {
                var psi = new ProcessStartInfo(Runner,
                    "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" +
                    StartScript + "\" -EnsureRunning")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                Process.Start(psi);
            }
            catch { }
        }
    }

    // 让非客户区（标题栏/边框）跟着应用主题走：Win11 的 DWM 暗色 + 自定义颜色
    internal static class Dwm
    {
        [DllImport("dwmapi.dll", PreserveSig = true)]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        private const int DWMWA_BORDER_COLOR = 34;
        private const int DWMWA_CAPTION_COLOR = 35;
        private const int DWMWA_TEXT_COLOR = 36;

        private static int Ref(int r, int g, int b) { return r | (g << 8) | (b << 16); }

        private static int ParseHex(string hex, int dr, int dg, int db)
        {
            if (!string.IsNullOrEmpty(hex) && hex[0] == '#' && hex.Length >= 7)
            {
                int v;
                if (int.TryParse(hex.Substring(1, 6), System.Globalization.NumberStyles.HexNumber, null, out v))
                {
                    return Ref((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
                }
            }
            return Ref(dr, dg, db);
        }

        public static void ApplyColors(IntPtr hwnd, string caption, string text, string border)
        {
            if (hwnd == IntPtr.Zero) return;
            try
            {
                int on = 1;
                DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int));
                int c = ParseHex(caption, 17, 21, 28);
                int t = ParseHex(text, 216, 223, 233);
                int b = ParseHex(border, 30, 38, 50);
                DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, ref c, sizeof(int));
                DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, ref t, sizeof(int));
                DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref b, sizeof(int));
            }
            catch { }
        }

        public static void ApplyDark(IntPtr hwnd)
        {
            ApplyColors(hwnd, null, null, null);
        }
    }
    // 窗口尺寸/位置的持久化（主窗口和控制台各存一份）
    internal static class WindowMemory
    {
        private static string FileFor(string name)
        {
            return Path.Combine(Program.StateDir, name + ".txt");
        }

        public static void Restore(Form f, string name, bool defaultMaximized)
        {
            bool applied = false;
            try
            {
                string file = FileFor(name);
                if (File.Exists(file))
                {
                    string[] p = File.ReadAllText(file).Split(',');
                    int w, h, x, y, state = 0;
                    if (p.Length >= 4 && int.TryParse(p[0], out w) && int.TryParse(p[1], out h)
                        && int.TryParse(p[2], out x) && int.TryParse(p[3], out y))
                    {
                        if (p.Length > 4) int.TryParse(p[4], out state);
                        if (state == 2)
                        {
                            f.WindowState = FormWindowState.Maximized;
                            applied = true;
                        }
                        else if (w > 0 && h > 0)
                        {
                            Rectangle wa = Screen.FromPoint(new Point(x, y)).WorkingArea;
                            var rect = new Rectangle(x, y, Math.Min(w, wa.Width), Math.Min(h, wa.Height));
                            bool visible = false;
                            foreach (Screen sc in Screen.AllScreens)
                            {
                                if (sc.WorkingArea.IntersectsWith(rect)) { visible = true; break; }
                            }
                            if (visible)
                            {
                                f.StartPosition = FormStartPosition.Manual;
                                f.Bounds = rect;
                                applied = true;
                            }
                        }
                    }
                }
            }
            catch { }
            // 没有记录（首次运行）才用默认布局
            if (!applied && defaultMaximized) f.WindowState = FormWindowState.Maximized;
        }

        public static void Save(Form f, string name)
        {
            try
            {
                Rectangle r = f.WindowState == FormWindowState.Normal ? f.Bounds : f.RestoreBounds;
                if (r.Width <= 0 || r.Height <= 0) return;
                File.WriteAllText(FileFor(name), string.Format("{0},{1},{2},{3},{4}",
                    r.Width, r.Height, r.Left, r.Top, (int)f.WindowState));
            }
            catch { }
        }

        // 关闭时保存；拖动/缩放停手 0.7 秒后也存一次（防止异常退出丢尺寸）
        public static void Track(Form f, string name)
        {
            var timer = new System.Windows.Forms.Timer { Interval = 700 };
            timer.Tick += delegate { timer.Stop(); Save(f, name); };
            f.Resize += delegate { timer.Stop(); timer.Start(); };
            f.Move += delegate { timer.Stop(); timer.Start(); };
            f.FormClosing += delegate { timer.Stop(); Save(f, name); };
        }
    }


    internal sealed class MainForm : Form
    {
        private readonly WebView2 view;
        private readonly MenuStrip menu;

        public MainForm()
        {
            Text = "llama.cpp 对话";
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(1280, 860);
            MinimumSize = new Size(900, 600);
            BackColor = Color.FromArgb(11, 14, 20);
            DoubleBuffered = true;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            menu = new MenuStrip
            {
                BackColor = Color.FromArgb(17, 21, 28),
                ForeColor = Color.FromArgb(216, 223, 233),
                Renderer = new DarkMenuRenderer(Color.FromArgb(17, 21, 28), Color.FromArgb(216, 223, 233)),
            };
            menu.Items.Add("刷新", null, delegate
            {
                if (view != null && view.CoreWebView2 != null) view.CoreWebView2.Reload();
            });
            menu.Items.Add("退出", null, delegate { Close(); });

            view = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(11, 14, 20) };
            Controls.Add(view);
            Controls.Add(menu);
            MainMenuStrip = menu;

            WindowMemory.Restore(this, "window", false);
            HandleCreated += delegate { Dwm.ApplyDark(Handle); };
            Load += async (s, e) => await BootAsync();
            WindowMemory.Track(this, "window");
        }

        private async System.Threading.Tasks.Task BootAsync()
        {
            try
            {
                string dataDir = Path.Combine(Program.StateDir, "WebView2");
                Directory.CreateDirectory(dataDir);
                // 关掉后台节流：窗口被遮挡/最小化时也要能及时换肤
                var options = new CoreWebView2EnvironmentOptions(
                    "--disable-background-timer-throttling --disable-renderer-backgrounding " +
                    "--disable-backgrounding-occluded-windows");
                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, dataDir, options);
                await view.EnsureCoreWebView2Async(env);

                view.CoreWebView2.Settings.IsStatusBarEnabled = false;
                view.CoreWebView2.Settings.AreDevToolsEnabled = true;
                view.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
                view.CoreWebView2.NewWindowRequested += delegate (object s, CoreWebView2NewWindowRequestedEventArgs e)
                {
                    e.Handled = true;
                    Program.OpenExternal(e.Uri);
                };

                // 页面把当前皮肤的标题栏颜色发过来，跟着换（含切换模型时的渐变终点色）
                view.CoreWebView2.WebMessageReceived += delegate (object s, CoreWebView2WebMessageReceivedEventArgs e)
                {
                    string raw = null;
                    try { raw = e.TryGetWebMessageAsString(); } catch { }
                    if (string.IsNullOrEmpty(raw)) return;
                    if (raw.IndexOf("\"open-console\"", StringComparison.Ordinal) >= 0)
                    {
                        Program.OpenConsole();
                        return;
                    }
                    if (raw.IndexOf("\"theme\"", StringComparison.Ordinal) < 0) return;
                    string cap = HexValue(raw, "caption");
                    string txt = HexValue(raw, "text");
                    Dwm.ApplyColors(Handle, cap, txt, HexValue(raw, "border"));
                    ApplyMenuTheme(cap, txt);
                };

                Program.EnsurePanel();
                Program.EnsureService();
                StartPanelWatchdog();
                view.CoreWebView2.Navigate(Program.ChatUrl);
                if (Program.StartConsole)
                {
                    await System.Threading.Tasks.Task.Delay(600);
                    Program.OpenConsole();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "启动失败：" + ex.Message, "llama.cpp 对话",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static Color ColorFromHex(string hex, Color fallback)
        {
            if (string.IsNullOrEmpty(hex) || hex[0] != '#' || hex.Length < 7) return fallback;
            int v;
            if (!int.TryParse(hex.Substring(1, 6), System.Globalization.NumberStyles.HexNumber, null, out v))
                return fallback;
            return Color.FromArgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
        }

        private void ApplyMenuTheme(string captionHex, string textHex)
        {
            Color bg = ColorFromHex(captionHex, Color.FromArgb(17, 21, 28));
            Color fg = ColorFromHex(textHex, Color.FromArgb(216, 223, 233));
            menu.BackColor = bg;
            menu.ForeColor = fg;
            menu.Renderer = new DarkMenuRenderer(bg, fg);
            BackColor = bg;
            menu.Invalidate();
        }

        private static string HexValue(string json, string key)
        {
            string pat = "\"" + key + "\":\"";
            int i = json.IndexOf(pat, StringComparison.Ordinal);
            if (i < 0) return null;
            i += pat.Length;
            int j = json.IndexOf('"', i);
            return j > i ? json.Substring(i, j - i) : null;
        }

        // 面板看门狗：面板进程没了就重新拉起，否则工具调用会全部失败
        private System.Windows.Forms.Timer panelTimer;
        private int panelFails;

        private void StartPanelWatchdog()
        {
            panelTimer = new System.Windows.Forms.Timer { Interval = 15000 };
            panelTimer.Tick += delegate
            {
                System.Threading.Tasks.Task.Run(delegate
                {
                    bool ok = Program.Ping(Program.StateUrl);
                    try
                    {
                        BeginInvoke((Action)delegate
                        {
                            if (ok) { panelFails = 0; return; }
                            panelFails++;
                            if (panelFails >= 2)
                            {
                                panelFails = 0;
                                Program.EnsurePanel();
                            }
                        });
                    }
                    catch { }
                });
            };
            panelTimer.Start();
        }

    }


    // 程序内的 llama.cpp 控制台（再开一个 WebView2，指向面板 8090）
    internal sealed class ConsoleForm : Form
    {
        private readonly WebView2 view;

        public ConsoleForm()
        {
            Text = "llama.cpp 控制台";
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(1280, 860);
            MinimumSize = new Size(900, 600);
            WindowMemory.Restore(this, "console", true);   // 首次铺满，之后按上次的尺寸
            WindowMemory.Track(this, "console");
            BackColor = Color.FromArgb(11, 14, 20);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            HandleCreated += delegate { Dwm.ApplyDark(Handle); };

            view = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(11, 14, 20) };
            Controls.Add(view);
            Load += async (s, e) => await BootAsync();
        }

        private async System.Threading.Tasks.Task BootAsync()
        {
            try
            {
                string dataDir = Path.Combine(Program.StateDir, "WebView2");
                Directory.CreateDirectory(dataDir);
                var options = new CoreWebView2EnvironmentOptions(
                    "--disable-background-timer-throttling --disable-renderer-backgrounding " +
                    "--disable-backgrounding-occluded-windows");
                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, dataDir, options);
                await view.EnsureCoreWebView2Async(env);

                view.CoreWebView2.Settings.IsStatusBarEnabled = false;
                view.CoreWebView2.NewWindowRequested += delegate (object s, CoreWebView2NewWindowRequestedEventArgs e)
                {
                    e.Handled = true;
                    Program.OpenExternal(e.Uri);
                };

                // 面板里的「对话」按钮是给浏览器用的；程序内这个窗口本身就是对话端，隐藏掉
                await view.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                    "window.addEventListener('DOMContentLoaded',function(){" +
                    "var s=document.createElement('style');" +
                    "s.textContent='#btnApp{display:none!important}';" +
                    "document.head.appendChild(s);});");

                view.CoreWebView2.Navigate("http://127.0.0.1:8090/");
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "控制台打开失败：" + ex.Message, "llama.cpp 控制台",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }

    internal sealed class DarkMenuRenderer : ToolStripProfessionalRenderer
    {
        public DarkMenuRenderer(Color bg, Color fg) : base(new DarkColors(bg, fg)) { }

        private sealed class DarkColors : ProfessionalColorTable
        {
            private readonly Color bg;
            private readonly Color fg;

            public DarkColors(Color bg, Color fg) { this.bg = bg; this.fg = fg; }

            public override Color MenuItemSelected { get { return Blend(bg, fg, 0.10); } }
            public override Color MenuItemBorder { get { return Blend(bg, fg, 0.22); } }
            public override Color MenuItemPressedGradientBegin { get { return Blend(bg, fg, 0.16); } }
            public override Color MenuItemPressedGradientEnd { get { return Blend(bg, fg, 0.16); } }
            public override Color MenuStripGradientBegin { get { return bg; } }
            public override Color MenuStripGradientEnd { get { return bg; } }

            private static Color Blend(Color a, Color b, double t)
            {
                return Color.FromArgb(
                    (int)(a.R + (b.R - a.R) * t),
                    (int)(a.G + (b.G - a.G) * t),
                    (int)(a.B + (b.B - a.B) * t));
            }
        }
    }
}

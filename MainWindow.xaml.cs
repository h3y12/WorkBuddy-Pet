using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using WinForms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace WbPet
{
    public partial class MainWindow : Window
    {
        private readonly bool _headless;
        private readonly bool _watchWorkBuddy;
        private readonly string _statePath;
        private readonly string _configPath;
        private readonly DispatcherTimer _timer;
        private readonly PetConfig _cfg;

        private WinForms.NotifyIcon? _tray;
        private static Stream? _trayIconStream;
        private long _lastEventSeq = -1;
        private DateTime _doneUntil = DateTime.MinValue;
        private bool _eventIsError;
        private string _eventTitle = "";
        private string _stateName = "";
        private DateTime _lastStateWrite = DateTime.MinValue;
        private DateTime _lastCollectorAttempt = DateTime.MinValue;
        private Process? _collector;
        private string _collectorError = "";

        private DateTime _lastProcCheck = DateTime.MinValue;
        private DateTime _graceUntil = DateTime.MinValue;
        private int _missCount;
        private int _lastPendingCount = -1;
        private SettingsWindow? _settings;

        private static readonly Brush WorkingBrush = new SolidColorBrush(Color.FromRgb(0x2F, 0x6F, 0xEB));
        private static readonly Brush DoneBrush = new SolidColorBrush(Color.FromRgb(0x1B, 0x8A, 0x53));
        private static readonly Brush IdleBrush = new SolidColorBrush(Color.FromRgb(0x6B, 0x72, 0x80));
        private static readonly Brush ErrorBrush = new SolidColorBrush(Color.FromRgb(0xC0, 0x39, 0x39));
        private static readonly Brush UnreadBrush = new SolidColorBrush(Color.FromRgb(0xC8, 0x7A, 0x1E));

        public MainWindow() : this(false) { }

        public MainWindow(bool headless, string? statePath = null)
        {
            _headless = headless;
            InitializeComponent();
            Mascot.Source = LoadMascot();

            _watchWorkBuddy = !headless &&
                              !Environment.GetCommandLineArgs().Contains("--stay", StringComparer.OrdinalIgnoreCase);

            _statePath = statePath ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "WbPet", "state.json");
            _configPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "WbPet", "config.json");

            _cfg = headless ? new PetConfig() : PetConfig.Load(_configPath);
            if (headless)
            {
                // 出图自检时可以用环境变量临时改缩放，验证大号不裁字
                if (double.TryParse(Environment.GetEnvironmentVariable("WBPET_SNAP_TEXT"), out var ts) && ts > 0)
                    _cfg.TextScale = Math.Clamp(ts, 0.5, 2.0);
                if (double.TryParse(Environment.GetEnvironmentVariable("WBPET_SNAP_PET"), out var ps) && ps > 0)
                    _cfg.PetScale = Math.Clamp(ps, 0.5, 2.0);
            }
            ApplyConfig();

            Root.MouseLeftButtonDown += Root_MouseLeftButtonDown;
            Loaded += OnWindowLoaded;
            Closed += OnWindowClosed;
            IsVisibleChanged += (_, _) =>
            {
                if (_headless) return;
                if (IsVisible) ApplyPose(_stateName); else StopAnimations();
            };

            _timer = new DispatcherTimer(DispatcherPriority.Background)
            {
                Interval = TimeSpan.FromMilliseconds(350)
            };
            _timer.Tick += (_, _) => Tick();

            if (!headless)
            {
                CreateTray();
                _timer.Start();
            }
        }

        /// <summary>优先用本地放进去的形象（mascot.local.png），没有就用仓库自带的占位图。</summary>
        private static ImageSource? LoadMascot()
        {
            foreach (var uri in new[]
                     {
                         "pack://application:,,,/WbPet;component/Assets/mascot.local.png",
                         "pack://application:,,,/WbPet;component/Assets/mascot.png"
                     })
            {
                try
                {
                    var res = Application.GetResourceStream(new Uri(uri));
                    if (res == null) continue;
                    var bmp = new BitmapImage();
                    bmp.BeginInit();
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.StreamSource = res.Stream;
                    bmp.EndInit();
                    bmp.Freeze();
                    return bmp;
                }
                catch { }
            }
            return null;
        }

        internal FrameworkElement RootElement => Root;

        // ---------------- 配置 ----------------

        private void ApplyConfig()
        {
            double f = Math.Clamp(_cfg.FontSize, 10, 18) / 11.0;

            StatusText.FontSize = 12.5 * f;
            ExtraText.FontSize = 10.5 * f;
            TitleText.FontSize = 11 * f;
            TitleText.MaxWidth = 220 * f;
            UsageText.FontSize = 10.5 * f;
            StatusDot.Width = StatusDot.Height = 7 * f;
            Bubble.Padding = new Thickness(11 * f, 8 * f, 11 * f, 9 * f);
            Bubble.CornerRadius = new CornerRadius(13 * f);
            Bubble.Opacity = Math.Clamp(_cfg.PanelOpacity / 100.0, 0.2, 1.0);

            PetScale.ScaleX = PetScale.ScaleY = Math.Clamp(_cfg.PetScale, 0.4, 1.0);
            Topmost = _cfg.Topmost;
            MenuTopmost.IsChecked = _cfg.Topmost;
            MenuLaunchWb.IsChecked = _cfg.LaunchWorkBuddy;
            Bubble.Visibility = _cfg.ShowPanel ? Visibility.Visible : Visibility.Collapsed;
            MenuTogglePanel.Header = _cfg.ShowPanel ? "收起状态面板" : "展开状态面板";
        }

        /// <summary>缩放后窗口会往右下长，贴边时把它拉回来。</summary>
        private void ClampToScreen()
        {
            if (!IsVisible) return;
            var wa = SystemParameters.WorkArea;
            double w = ActualWidth > 1 ? ActualWidth : (double.IsNaN(Width) ? 236 : Width);
            double h = ActualHeight > 1 ? ActualHeight : (double.IsNaN(Height) ? 320 : Height);
            if (Left + w > wa.Right) Left = Math.Max(wa.Left, wa.Right - w);
            if (Top + h > wa.Bottom) Top = Math.Max(wa.Top, wa.Bottom - h);
        }

        private void OnWindowLoaded(object sender, RoutedEventArgs e)
        {
            if (_headless) return;
            EnsureCollector();
            if (_cfg.LaunchWorkBuddy && !IsWorkBuddyRunning())
                TryLaunchWorkBuddy();
            PlaceWindow();
        }

        /// <summary>采集器没在跑（state.json 太旧）就顺手拉起来；单例端口保证不会重复。</summary>
        private void EnsureCollector()
        {
            if (_headless || DateTime.UtcNow - _lastCollectorAttempt < TimeSpan.FromSeconds(15)) return;
            _lastCollectorAttempt = DateTime.UtcNow;
            try
            {
                if (File.Exists(_statePath) &&
                    DateTime.UtcNow - File.GetLastWriteTimeUtc(_statePath) < TimeSpan.FromSeconds(6))
                    return;
                if (_collector != null && !_collector.HasExited) return;
                _collector?.Dispose();
                _collector = null;

                var script = FindCollectorScript();
                if (script == null) { _collectorError = "发布目录缺少 collector.py，请完整解压程序包"; Log(_collectorError); return; }

                var pythonw = FindPythonw();
                if (pythonw == null) { _collectorError = "需要 Python 3.10+；请设置 WBPET_PYTHON 或提供 python\\pythonw.exe"; Log(_collectorError); return; }

                var psi = new ProcessStartInfo
                {
                    FileName = pythonw,
                    WorkingDirectory = Path.GetDirectoryName(script)!,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                psi.ArgumentList.Add(script);
                psi.ArgumentList.Add("--parent");
                psi.ArgumentList.Add(Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
                _collector = Process.Start(psi);
                _collectorError = "";
                Log($"拉起采集器 pid={_collector?.Id} python={pythonw}");
            }
            catch (Exception ex)
            {
                _collectorError = "采集器启动失败，详情见 pet.log";
                Log("拉起采集器失败: " + ex.Message);
            }
        }

        private void TryLaunchWorkBuddy()
        {
            try
            {
                var path = FindWorkBuddy();
                if (path == null) { Log("找不到 WorkBuddy.exe，无法拉起"); return; }
                Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
                _graceUntil = DateTime.Now.AddSeconds(120);   // 等它起来，别把自己判死
                Log("拉起 WorkBuddy: " + path);
            }
            catch (Exception ex)
            {
                Log("拉起 WorkBuddy 失败: " + ex.Message);
            }
        }

        private static string? FindWorkBuddy()
        {
            foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
            {
                try
                {
                    using var key = hive.OpenSubKey(
                        @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\WorkBuddy.exe");
                    if (key?.GetValue(null) is string v)
                    {
                        v = v.Trim('"');
                        if (File.Exists(v)) return v;
                    }
                }
                catch { }
            }

            var list = new List<string>();
            foreach (var pf in new[]
                     {
                         Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                         Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86)
                     })
            {
                if (!string.IsNullOrEmpty(pf))
                    list.Add(Path.Combine(pf, "WorkBuddy", "WorkBuddy.exe"));
            }
            foreach (var d in DriveInfo.GetDrives())
            {
                try
                {
                    if (d.IsReady && d.DriveType == DriveType.Fixed)
                        list.Add(Path.Combine(d.RootDirectory.FullName, "Program Files", "WorkBuddy", "WorkBuddy.exe"));
                }
                catch { }
            }
            list.Add(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", "WorkBuddy", "WorkBuddy.exe"));

            return list.Find(File.Exists);
        }

        private static string? FindCollectorScript()
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            for (int i = 0; i < 4 && dir != null; i++, dir = dir.Parent)
            {
                var p = Path.Combine(dir.FullName, "collector.py");
                if (File.Exists(p)) return p;
            }
            return null;
        }

        private static string? FindPythonw()
        {
            var configured = Environment.GetEnvironmentVariable("WBPET_PYTHON");
            if (!string.IsNullOrWhiteSpace(configured))
                return File.Exists(configured) ? Path.GetFullPath(configured) : null;
            foreach (var name in new[] { "pythonw.exe", "python.exe" })
            {
                var bundled = Path.Combine(AppContext.BaseDirectory, "python", name);
                if (File.Exists(bundled)) return bundled;
            }
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "")
                     .Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                foreach (var name in new[] { "pythonw.exe", "python.exe" })
                {
                    try
                    {
                        var p = Path.Combine(dir.Trim('"').Trim(), name);
                        if (File.Exists(p)) return p;
                    }
                    catch { }
                }
            }
            const string fallbackName = "pythonw.exe";
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var candidates = new[]
            {
                Path.Combine(local, "Programs", "Python", "Python314", fallbackName),
                Path.Combine(local, "Programs", "Python", "Python313", fallbackName),
                Path.Combine(local, "Programs", "Python", "Python312", fallbackName),
                Path.Combine(local, "Programs", "Python", "Python311", fallbackName),
                Path.Combine(local, "Programs", "Python", "Python310", fallbackName),
                @"C:\Python313\" + fallbackName,
                @"C:\Python312\" + fallbackName,
                @"C:\ProgramData\anaconda3\" + fallbackName,
            };
            foreach (var c in candidates) if (File.Exists(c)) return c;
            return null;
        }

        private static void Log(string msg)
        {
            try
            {
                var dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WbPet");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "pet.log"),
                    $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {msg}{Environment.NewLine}");
            }
            catch { }
        }

        private void PlaceWindow()
        {
            double w = ActualWidth > 1 ? ActualWidth : (double.IsNaN(Width) ? 236 : Width);
            double h = ActualHeight > 1 ? ActualHeight : (double.IsNaN(Height) ? 320 : Height);
            double left = _cfg.HasPosition ? _cfg.Left : SystemParameters.WorkArea.Right - w - 24;
            double top = _cfg.HasPosition ? _cfg.Top : SystemParameters.WorkArea.Top + 96;

            var wa = SystemParameters.WorkArea;
            if (left < wa.Left - w + 60 || left > wa.Right - 60) left = wa.Right - w - 24;
            if (top < wa.Top - 20 || top > wa.Bottom - 80) top = wa.Top + 96;

            Left = left;
            Top = top;
            SaveConfig();
        }

        private void SaveConfig()
        {
            if (_headless) return;
            try
            {
                if (IsVisible && WindowState == WindowState.Normal)
                {
                    _cfg.Left = Left;
                    _cfg.Top = Top;
                    _cfg.HasPosition = true;
                }
                _cfg.Save(_configPath);
            }
            catch { }
        }

        // ---------------- 托盘 ----------------

        private void CreateTray()
        {
            try
            {
                var res = Application.GetResourceStream(new Uri("pack://application:,,,/WbPet;component/Assets/pet.ico"));
                Drawing.Icon icon;
                if (res != null)
                {
                    _trayIconStream = res.Stream;
                    icon = new Drawing.Icon(_trayIconStream, WinForms.SystemInformation.SmallIconSize);
                }
                else
                {
                    icon = Drawing.SystemIcons.Application;
                }

                var menu = new WinForms.ContextMenuStrip();
                menu.Items.Add("显示 / 隐藏", null, (_, _) => ToggleWindow());
                menu.Items.Add("退出", null, (_, _) => ExitApp());

                _tray = new WinForms.NotifyIcon
                {
                    Icon = icon,
                    Text = "WorkBuddy 桌宠",
                    Visible = true,
                    ContextMenuStrip = menu
                };
                _tray.DoubleClick += (_, _) => ToggleWindow();
            }
            catch { }
        }

        private void ToggleWindow()
        {
            if (IsVisible)
            {
                Hide();
            }
            else
            {
                Show();
                Activate();
            }
        }

        private void ExitApp()
        {
            Log("退出桌宠");
            _tray?.Dispose();
            _timer.Stop();
            Application.Current.Shutdown();
        }

        private void OnWindowClosed(object? sender, EventArgs e)
        {
            SaveConfig();
            _tray?.Dispose();
            _timer.Stop();
            StopAnimations();
            _collector?.Dispose(); // Python 自己检测父进程退出，不终止其他实例的采集器。
        }

        // ---------------- 主循环 ----------------

        private void Tick()
        {
            EnsureCollector();
            // 生命周期：WorkBuddy 关掉后跟着退（约 6 秒宽限，够它重启）
            if (_watchWorkBuddy && (DateTime.Now - _lastProcCheck).TotalSeconds >= 2)
            {
                _lastProcCheck = DateTime.Now;
                if (IsWorkBuddyRunning())
                {
                    _missCount = 0;
                }
                else if (++_missCount >= 3 && DateTime.Now > _graceUntil)
                {
                    ExitApp();
                    return;
                }
            }

            if (_doneUntil != DateTime.MinValue && DateTime.Now > _doneUntil)
            {
                _doneUntil = DateTime.MinValue;
                _stateName = "";
                _lastStateWrite = DateTime.MinValue;
            }
            PollState();
        }

        private static bool IsWorkBuddyRunning()
        {
            try
            {
                var processes = Process.GetProcessesByName("WorkBuddy");
                try { return processes.Length > 0; }
                finally { foreach (var process in processes) process.Dispose(); }
            }
            catch
            {
                return true;   // 查不到就当它还活着，别乱退
            }
        }

        private void PollState()
        {
            string text;
            DateTime stateWrite;
            try
            {
                if (!File.Exists(_statePath))
                {
                    SetState("offline", "等待采集器", _collectorError, "", 0);
                    return;
                }
                stateWrite = File.GetLastWriteTimeUtc(_statePath);
                if (DateTime.UtcNow - stateWrite > TimeSpan.FromSeconds(10))
                {
                    ShowUnavailable("采集器超过 10 秒没有更新，正在等待恢复");
                    return;
                }
                if (stateWrite == _lastStateWrite) return;
                text = File.ReadAllText(_statePath);
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
            {
                ShowUnavailable("状态文件暂时无法读取，下一轮会重试");
                return;
            }

            try
            {
                using var doc = JsonDocument.Parse(text);
                var root = doc.RootElement;
                if (root.ValueKind != JsonValueKind.Object)
                    throw new JsonException("State must be an object");

                // 采集器出错时只会留下 stale 标记，这时不要臆断 WorkBuddy 是否在运行
                if (root.TryGetProperty("error", out _) ||
                    (root.TryGetProperty("stale", out var stale) && stale.ValueKind == JsonValueKind.True) ||
                    (root.TryGetProperty("db_ok", out var dbOk) && dbOk.ValueKind == JsonValueKind.False))
                {
                    ShowUnavailable("采集器读不到有效数据库，显示已暂停；详情见 pet.log / state.json");
                    return;
                }

                bool running = root.TryGetProperty("app_running", out var ar) &&
                               ar.ValueKind == JsonValueKind.True;
                bool celebrate = false;

                double used = 0, size = 0, creditsToday = 0, creditsSession = 0;
                string creditsSince = "";
                if (root.TryGetProperty("usage", out var u) && u.ValueKind == JsonValueKind.Object)
                {
                    used = Num(u, "session_used");
                    size = Num(u, "session_size");
                    creditsToday = Num(u, "credits_today");
                    creditsSession = Num(u, "session_credits");
                    creditsSince = Str(u, "credits_since");
                }

                // 完成事件
                if (root.TryGetProperty("event", out var ev) && ev.ValueKind == JsonValueKind.Object)
                {
                    long seq = (long)Num(ev, "seq");
                    if (seq > _lastEventSeq && _lastEventSeq >= 0)
                    {
                        _eventIsError = Str(ev, "type") == "error";
                        _eventTitle = Str(ev, "title");
                        _doneUntil = DateTime.Now.AddSeconds(8);
                        _stateName = "";
                        _lastStateWrite = DateTime.MinValue;
                        celebrate = !_eventIsError;
                        Notify(ev);
                    }
                    if (seq > _lastEventSeq) _lastEventSeq = seq;
                }
                else
                {
                    _lastEventSeq = Math.Max(_lastEventSeq, 0);
                }

                int pendingCount = 0;
                string pendingLabel = "";
                if (root.TryGetProperty("pending", out var pd) && pd.ValueKind == JsonValueKind.Object)
                {
                    pendingCount = (int)Num(pd, "count");
                    pendingLabel = Str(pd, "label");
                }
                if (pendingCount > _lastPendingCount && _lastPendingCount >= 0)
                    NotifyPending(pendingLabel, pendingCount);
                _lastPendingCount = pendingCount;

                int parallel = 0;
                if (root.TryGetProperty("recent", out var rec) && rec.ValueKind == JsonValueKind.Array)
                {
                    foreach (var s in rec.EnumerateArray())
                        if (Str(s, "status") == "working") parallel++;
                }

                string title = "";
                string status = "";
                int unread = 0;
                if (root.TryGetProperty("active", out var a) && a.ValueKind == JsonValueKind.Object)
                {
                    title = Str(a, "title");
                    status = Str(a, "status");
                    unread = (int)Num(a, "unread");
                }

                if (!running)
                {
                    SetState("offline", "WorkBuddy 没开着", title, "", used / Math.Max(size, 1));
                    return;
                }

                string pct = size > 0 ? $"{used / size * 100:0.#}%" : "—";
                string usage = $"上下文 {pct}   ·   已观测到使用 {creditsToday:0.#} 积分";
                string tip = $"本会话 {used:N0} / {size:N0} tokens；会话累计 {creditsSession:0.##} 积分"
                             + (string.IsNullOrEmpty(creditsSince) ? "" : $"；已观测到使用自 {creditsSince} 起累计");
                double ratio = used / Math.Max(size, 1);
                _lastStateWrite = stateWrite; // 仅在完整解析成功后提交，坏 JSON 下一轮还会重试。

                if (pendingCount > 0)
                {
                    string label = string.IsNullOrEmpty(pendingLabel)
                        ? $"{pendingCount} 个操作等你确认"
                        : (pendingCount > 1 ? $"{pendingLabel} 等 {pendingCount} 个" : pendingLabel);
                    SetState("confirm", "等你确认", label, usage, ratio,
                             "WorkBuddy 正等你点确认；确认后这里会自动消失", "?", UnreadBrush, parallel);
                }
                else if (DateTime.Now <= _doneUntil)
                {
                    SetState(_eventIsError ? "error" : "done", _eventIsError ? "任务出错" : "✓ 任务完成",
                             _eventTitle, usage, ratio, tip, _eventIsError ? "!" : "✓",
                             _eventIsError ? ErrorBrush : DoneBrush, parallel);
                    if (celebrate && IsVisible && SystemParameters.ClientAreaAnimation) PlayCelebrate();
                }
                else if (status == "working")
                {
                    SetState("working", "正在干活", title, usage, ratio, tip, "", null, parallel);
                }
                else if (status == "error")
                {
                    SetState("error", "任务出错", title, usage, ratio, tip, "!", ErrorBrush, parallel);
                }
                else if (unread > 0)
                {
                    string n = unread > 9 ? "9+" : unread.ToString();
                    SetState("unread", "有未读结果", title, usage, ratio, tip, n, UnreadBrush, parallel);
                }
                else
                {
                    SetState("idle", title.Length > 0 ? "待命" : "没有任务",
                             title.Length > 0 ? "上次：" + title : "", usage, ratio, tip, "", null, parallel);
                }
            }
            catch (Exception ex) when (ex is JsonException || ex is InvalidOperationException ||
                                       ex is FormatException || ex is OverflowException)
            {
                ShowUnavailable("采集数据暂时无法解析，下一轮会重试");
            }
        }

        private void ShowUnavailable(string detail)
        {
            _doneUntil = DateTime.MinValue;
            _lastStateWrite = DateTime.MinValue;
            SetState("offline", "读数暂时中断", detail, "", 0);
        }

        private static string Str(JsonElement e, string name) =>
            e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";

        private static double Num(JsonElement e, string name)
        {
            if (!e.TryGetProperty(name, out var v)) return 0;
            if (v.ValueKind == JsonValueKind.Number) return v.GetDouble();
            if (v.ValueKind == JsonValueKind.String &&
                double.TryParse(v.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var d)) return d;
            return 0;
        }

        private void NotifyPending(string label, int count)
        {
            try
            {
                if (_tray == null) return;
                _tray.ShowBalloonTip(3000, "WorkBuddy 等你确认",
                    string.IsNullOrWhiteSpace(label) ? $"{count} 个操作待确认" : label,
                    WinForms.ToolTipIcon.Warning);
            }
            catch { }
        }

        private void Notify(JsonElement ev)
        {
            try
            {
                if (_tray == null) return;
                string t = Str(ev, "title");
                string type = Str(ev, "type");
                _tray.ShowBalloonTip(
                    3000,
                    type == "error" ? "WorkBuddy 任务出错" : "WorkBuddy 任务完成",
                    string.IsNullOrWhiteSpace(t) ? "点我看看结果" : t,
                    type == "error" ? WinForms.ToolTipIcon.Warning : WinForms.ToolTipIcon.Info);
            }
            catch { }
        }

        // ---------------- 视觉状态 ----------------

        private void SetState(string name, string status, string title, string usage, double ratio,
                              string tip = "", string badge = "", Brush? badgeBrush = null, int parallel = 0)
        {
            bool changed = name != _stateName;
            _stateName = name;

            StatusText.Text = status;
            StatusText.Foreground = name switch
            {
                "working" => WorkingBrush,
                "done" => DoneBrush,
                "error" => ErrorBrush,
                "unread" => UnreadBrush,
                _ => IdleBrush
            };
            StatusDot.Fill = StatusText.Foreground;

            TitleText.Text = title;
            TitleText.Visibility = string.IsNullOrEmpty(title) ? Visibility.Collapsed : Visibility.Visible;
            UsageText.Text = usage;
            UsageText.Visibility = string.IsNullOrEmpty(usage) ? Visibility.Collapsed : Visibility.Visible;

            ExtraText.Text = parallel > 1 ? $"{parallel} 个并行" : "";
            ExtraText.Visibility = parallel > 1 ? Visibility.Visible : Visibility.Collapsed;

            double r = Math.Max(0, Math.Min(1, ratio));
            UsageCol.Width = new GridLength(r, GridUnitType.Star);
            RestCol.Width = new GridLength(1 - r, GridUnitType.Star);
            UsageFill.Fill = name switch
            {
                "error" => ErrorBrush,
                "done" => DoneBrush,
                "unread" => UnreadBrush,
                _ => new SolidColorBrush(Color.FromRgb(0x7C, 0x8B, 0x9A))
            };

            ToolTip = string.IsNullOrEmpty(tip) ? null : tip;

            bool showBadge = !string.IsNullOrEmpty(badge) && badgeBrush != null;
            Badge.Visibility = showBadge ? Visibility.Visible : Visibility.Collapsed;
            if (showBadge)
            {
                BadgeText.Text = badge;
                BadgeText.FontSize = badge!.Length > 1 ? 11 : (badge == "!" ? 16 : 14);
                BadgeCircle.Fill = badgeBrush!;
                BadgeRing.Opacity = name == "unread" ? 0.55 : 0.92;
            }

            if (changed) ApplyPose(name);
        }

        private void ApplyPose(string name)
        {
            if ((!_headless && !IsVisible) || !SystemParameters.ClientAreaAnimation)
            {
                StopAnimations();
                return;
            }
            bool working = name == "working";
            Dots.Visibility = working ? Visibility.Visible : Visibility.Collapsed;
            if (working) StartDots(); else StopDots();

            switch (name)
            {
                case "working":
                    StartBreathe(1.0, 1.018, 1.6);
                    StartBob(-5.5, 0.85);
                    break;
                case "done":
                    StartBreathe(1.0, 1.01, 2.4);
                    StartBob(0, 0);
                    break;
                case "confirm":
                    StartBreathe(1.0, 1.03, 1.1);
                    StartBob(-6.5, 0.7);
                    break;
                case "unread":
                    StartBreathe(1.0, 1.02, 2.6);
                    StartBob(-3.5, 1.6);
                    break;
                default:
                    StartBreathe(1.0, 1.016, 3.0);
                    StartBob(-3.0, 3.0);
                    break;
            }
        }

        private void StopAnimations()
        {
            StopDots();
            BodyScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            BodyScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            BodyShift.BeginAnimation(TranslateTransform.YProperty, null);
            Shadow.BeginAnimation(OpacityProperty, null);
            BodyScale.ScaleX = BodyScale.ScaleY = 1;
            BodyShift.Y = 0;
            Shadow.Opacity = 1;
            Dots.Visibility = Visibility.Collapsed;
        }

        private void StartBreathe(double from, double to, double seconds)
        {
            var ease = new SineEase { EasingMode = EasingMode.EaseInOut };
            var sy = new DoubleAnimation(from, to, TimeSpan.FromSeconds(seconds))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease };
            var sx = new DoubleAnimation(from, 1 - (to - from) * 0.4, TimeSpan.FromSeconds(seconds))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease };
            Timeline.SetDesiredFrameRate(sy, 20);
            Timeline.SetDesiredFrameRate(sx, 20);
            BodyScale.BeginAnimation(ScaleTransform.ScaleYProperty, sy);
            BodyScale.BeginAnimation(ScaleTransform.ScaleXProperty, sx);
        }

        private void StartBob(double amplitude, double seconds)
        {
            if (amplitude == 0)
            {
                BodyShift.BeginAnimation(TranslateTransform.YProperty, null);
                BodyShift.Y = 0;
                Shadow.BeginAnimation(OpacityProperty, null);
                Shadow.Opacity = 1;
                return;
            }
            var ease = new SineEase { EasingMode = EasingMode.EaseInOut };
            var bob = new DoubleAnimation(0, amplitude, TimeSpan.FromSeconds(seconds))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease };
            Timeline.SetDesiredFrameRate(bob, 20);
            BodyShift.BeginAnimation(TranslateTransform.YProperty, bob);

            var shadow = new DoubleAnimation(1.0, 0.7, TimeSpan.FromSeconds(seconds))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease };
            Timeline.SetDesiredFrameRate(shadow, 20);
            Shadow.BeginAnimation(OpacityProperty, shadow);
        }

        private void StartDots()
        {
            var els = new[] { Dot1, Dot2, Dot3 };
            for (int i = 0; i < els.Length; i++)
            {
                var anim = new DoubleAnimation(0.25, 1.0, TimeSpan.FromMilliseconds(420))
                {
                    AutoReverse = true,
                    RepeatBehavior = RepeatBehavior.Forever,
                    BeginTime = TimeSpan.FromMilliseconds(i * 160)
                };
                Timeline.SetDesiredFrameRate(anim, 20);
                els[i].BeginAnimation(OpacityProperty, anim);
            }
        }

        private void StopDots()
        {
            foreach (var e in new[] { Dot1, Dot2, Dot3 })
            {
                e.BeginAnimation(OpacityProperty, null);
                e.Opacity = 1;
            }
        }

        private void PlayCelebrate()
        {
            var jump = new DoubleAnimationUsingKeyFrames();
            jump.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            jump.KeyFrames.Add(new EasingDoubleKeyFrame(-15, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.22)),
                new QuadraticEase { EasingMode = EasingMode.EaseOut }));
            jump.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.46)),
                new BounceEase { Bounces = 2, Bounciness = 2 }));
            jump.RepeatBehavior = new RepeatBehavior(2);
            BodyShift.BeginAnimation(TranslateTransform.YProperty, jump);
        }

        // ---------------- 交互 ----------------

        private void Root_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton != MouseButton.Left) return;
            try { DragMove(); } catch { }
            SaveConfig();
        }

        private void MenuTogglePanel_Click(object sender, RoutedEventArgs e)
        {
            _cfg.ShowPanel = !_cfg.ShowPanel;
            ApplyConfig();
            SaveConfig();
        }

        private void MenuSettings_Click(object sender, RoutedEventArgs e)
        {
            if (_settings != null && _settings.IsVisible)
            {
                _settings.Activate();
                return;
            }

            _settings = new SettingsWindow(_cfg, () =>
            {
                ApplyConfig();
                SaveConfig();
                Dispatcher.BeginInvoke(new Action(ClampToScreen), DispatcherPriority.Loaded);
            });
            _settings.Owner = this;
            _settings.Closed += (_, _) => _settings = null;
            _settings.Show();
        }

        private void MenuLaunchWb_Click(object sender, RoutedEventArgs e)
        {
            _cfg.LaunchWorkBuddy = MenuLaunchWb.IsChecked == true;
            SaveConfig();
        }

        private void MenuTopmost_Click(object sender, RoutedEventArgs e)
        {
            _cfg.Topmost = MenuTopmost.IsChecked == true;
            Topmost = _cfg.Topmost;
            SaveConfig();
        }

        private void MenuHide_Click(object sender, RoutedEventArgs e) => Hide();

        private void MenuExit_Click(object sender, RoutedEventArgs e) => ExitApp();

        private void PetArea_MouseLeftButtonDown(object sender, MouseButtonEventArgs e) { }

        private void PetArea_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) { }

        // ---------------- 供离屏出图使用 ----------------

        internal void PrepareSnapshot(string state, string status, string title, string usage, double ratio)
        {
            string badge = state switch
            {
                "done" => "✓",
                "unread" => "3",
                "error" => "!",
                "confirm" => "?",
                _ => ""
            };
            Brush? brush = state switch
            {
                "done" => DoneBrush,
                "unread" => UnreadBrush,
                "error" => ErrorBrush,
                "confirm" => UnreadBrush,
                _ => null
            };

            SetState(state, status, title, usage, ratio, "", badge, brush, 0);

            // 冻结动画在中间帧，截图更自然
            BodyScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            BodyShift.BeginAnimation(TranslateTransform.YProperty, null);
            BodyScale.ScaleY = 1.008;
            BodyShift.Y = 0;
            Dots.Visibility = state == "working" ? Visibility.Visible : Visibility.Collapsed;
            if (state == "working")
            {
                Dot1.Opacity = 0.55;
                Dot2.Opacity = 1.0;
                Dot3.Opacity = 0.35;
            }
        }
    }

    public class PetConfig
    {
        public double Left { get; set; }
        public double Top { get; set; }
        public bool HasPosition { get; set; }
        public double Scale { get; set; } = 1.0;          // 旧版整体缩放，保留只为兼容老配置
        public double PetScale { get; set; } = 1.0;       // 角色大小 0.4–1.0
        public double TextScale { get; set; } = 1.0;      // 旧版文本缩放，已由 FontSize 取代
        public double FontSize { get; set; } = 11;        // 字号 10–18
        public double PanelOpacity { get; set; } = 95;    // 面板不透明度 20–100
        public bool Topmost { get; set; } = true;
        public bool ShowPanel { get; set; } = true;
        public bool LaunchWorkBuddy { get; set; } = true;

        public static PetConfig Load(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    var c = JsonSerializer.Deserialize<PetConfig>(File.ReadAllText(path));
                    if (c != null)
                    {
                        c.PetScale = Math.Clamp(c.PetScale <= 0 ? 1.0 : c.PetScale, 0.4, 1.0);
                        c.FontSize = Math.Clamp(c.FontSize <= 0 ? 11 : c.FontSize, 10, 18);
                        c.PanelOpacity = Math.Clamp(c.PanelOpacity <= 0 ? 95 : c.PanelOpacity, 20, 100);
                        return c;
                    }
                }
            }
            catch { }
            return new PetConfig();
        }

        public void Save(string path)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }
    }
}

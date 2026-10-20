using System;
using System.Threading;
using System.Windows;

namespace WbPet
{
    public partial class App : Application
    {
        private Mutex? _mutex;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            // 创建/刷新桌面快捷方式：不开窗口，做完就退
            if (e.Args.Length >= 1 && e.Args[0] == "--shortcut")
            {
                ShortcutHelper.Create();
                Shutdown();
                return;
            }

            if (e.Args.Length >= 2 && e.Args[0] == "--settings-snapshot")
            {
                try { SnapshotRunner.RunSettings(e.Args[1]); }
                catch (Exception ex) { MessageBox.Show(ex.ToString(), "settings snapshot failed"); }
                Shutdown();
                return;
            }

            // 离屏出图：不需要互斥体，也不碰用户配置
            if (e.Args.Length >= 2 && e.Args[0] == "--snapshot")
            {
                try
                {
                    SnapshotRunner.Run(e.Args[1]);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(ex.ToString(), "WbPet snapshot failed");
                }
                Shutdown();
                return;
            }

            _mutex = new Mutex(true, @"Local\WbPet.SingleInstance.v1", out bool isFirst);
            if (!isFirst)
            {
                Shutdown();
                return;
            }

            var win = new MainWindow();
            MainWindow = win;
            win.Show();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _mutex?.Dispose();
            base.OnExit(e);
        }
    }
}

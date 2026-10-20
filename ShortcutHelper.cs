using System;
using System.IO;
using System.Runtime.InteropServices;

namespace WbPet
{
    /// <summary>在当前用户桌面创建/覆盖一个指向本 exe 的快捷方式。</summary>
    internal static class ShortcutHelper
    {
        public static string DesktopLnk =>
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                "WorkBuddy 桌宠.lnk");

        /// <summary>返回快捷方式路径；失败返回 null。</summary>
        public static string? Create()
        {
            try
            {
                string exe = Environment.ProcessPath ?? "";
                if (string.IsNullOrEmpty(exe) || !File.Exists(exe)) return null;

                var type = Type.GetTypeFromProgID("WScript.Shell");
                if (type == null) return null;

                dynamic shell = Activator.CreateInstance(type)!;
                string lnk = DesktopLnk;
                dynamic sc = shell.CreateShortcut(lnk);
                sc.TargetPath = exe;
                sc.WorkingDirectory = Path.GetDirectoryName(exe) ?? "";
                sc.IconLocation = exe + ",0";
                sc.Description = "WorkBuddy 桌宠";
                sc.Save();

                return File.Exists(lnk) ? lnk : null;
            }
            catch (COMException)
            {
                return null;
            }
            catch
            {
                return null;
            }
        }
    }
}

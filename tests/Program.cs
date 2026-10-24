using System;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using WbPet;

internal static class Program
{
    private static int _passed;
    private static readonly BindingFlags Flags = BindingFlags.Instance | BindingFlags.NonPublic;
    private static object? Field(MainWindow w, string name) => typeof(MainWindow).GetField(name, Flags)!.GetValue(w);
    private static void Poll(MainWindow w) => typeof(MainWindow).GetMethod("PollState", Flags)!.Invoke(w, null);
    private static void Check(bool ok, string label)
    {
        if (!ok) throw new Exception(label);
        Console.WriteLine("PASS " + label); _passed++;
    }

    [STAThread]
    private static int Main()
    {
        _ = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        string folder = Path.Combine(Path.GetTempPath(), "wb-smoke-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        string path = Path.Combine(folder, "state.json");
        var w = new MainWindow(true, path);
        void Write(object data)
        {
            File.WriteAllText(path, JsonSerializer.Serialize(data));
            typeof(MainWindow).GetField("_lastStateWrite", Flags)!.SetValue(w, DateTime.MinValue);
        }
        object Good(long seq = 0, string type = "done") => new
        {
            ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), app_running = true, db_ok = true,
            active = new { title = "synthetic task", status = "working", unread = 0 },
            usage = new { session_used = 100, session_size = 1000 },
            @event = new { seq, type, title = "synthetic event" }
        };
        try
        {
            Poll(w);
            Check((string?)Field(w, "_stateName") == "offline", "missing state");
            Write(Good()); Poll(w);
            Check((string?)Field(w, "_stateName") == "working", "healthy state");
            Write(new { stale = true, app_running = true }); Poll(w);
            Check((string?)Field(w, "_stateName") == "offline", "stale marker overrides cached running flag");
            Check(((TextBlock)w.FindName("UsageText")).Visibility == Visibility.Collapsed, "stale usage is hidden");
            Write(Good()); Poll(w);
            File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddSeconds(-20)); Poll(w);
            Check((string?)Field(w, "_stateName") == "offline", "stopped heartbeat");
            File.WriteAllText(path, "{broken"); Poll(w);
            Check((string?)Field(w, "_stateName") == "offline", "malformed JSON");
            Write(Good()); Poll(w);
            Check((string?)Field(w, "_stateName") == "working", "recovery");
            using (var locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                typeof(MainWindow).GetField("_lastStateWrite", Flags)!.SetValue(w, DateTime.MinValue);
                Poll(w);
                Check((string?)Field(w, "_stateName") == "offline", "locked state file does not retain healthy display");
            }
            Write(Good()); Poll(w);
            Write(Good(1, "error")); Poll(w);
            Check((string?)Field(w, "_stateName") == "error", "error does not become green completion");
            Write(Good(2)); Poll(w);
            Check((string?)Field(w, "_stateName") == "done", "completion event");
            Write(new { db_ok = false, app_running = true }); Poll(w);
            Check((string?)Field(w, "_stateName") == "offline", "missing database does not show healthy idle");
            Console.WriteLine($"{_passed} checks passed");
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
        finally { w.Close(); Directory.Delete(folder, true); }
    }
}

using System;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace WbPet
{
    /// <summary>离屏把各状态渲染成一张对照图，用于交付前自检（不显示窗口）。</summary>
    internal static class SnapshotRunner
    {
        private record Case(string State, string Status, string Title, string Usage, double Ratio, string Caption);

        public static void Run(string outPath)
        {
            var cases = new[]
            {
                new Case("idle", "待命", "上次：替换教学大纲动词并参考PPT",
                         "上下文 46.9%   ·   已观测到使用 12.4 积分", 0.469, "① 空闲：轻微起伏，报上次任务与已观测用量"),
                new Case("working", "正在干活", "开发 workbuddy 桌宠的可行性",
                         "上下文 9.5%   ·   已观测到使用 12.4 积分", 0.095, "② 执行中：浮动更快，右上角三个思考点"),
                new Case("done", "✓ 任务完成", "替换教学大纲动词并参考PPT",
                         "上下文 46.9%   ·   已观测到使用 12.4 积分", 0.469, "③ 完成：跳两下、绿勾徽标，另弹托盘通知"),
                new Case("unread", "有未读结果", "调整课程材料与补充教学进度表",
                         "上下文 22.4%   ·   已观测到使用 12.4 积分", 0.224, "④ 未读：琥珀色数字徽标，等你点开结果"),
                new Case("confirm", "等你确认", "workbuddy.db",
                         "上下文 12.0%   ·   已观测到使用 12.4 积分", 0.120, "⑤ 待确认：问号徽标 + 托盘提醒，点掉后自动消失"),
            };

            const double gap = 26;
            const double pad = 26;
            const double captionH = 52;

            var roots = new FrameworkElement[cases.Length];
            var widths = new double[cases.Length];
            var heights = new double[cases.Length];

            // 第一遍：脱窗测量，取最宽的一张作为统一卡片宽度（缩放后宽度会变）
            for (int i = 0; i < cases.Length; i++)
            {
                var c = cases[i];
                var win = new MainWindow(headless: true);
                win.PrepareSnapshot(c.State, c.Status, c.Title, c.Usage, c.Ratio);

                var root = win.RootElement;
                win.Content = null;
                root.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                widths[i] = Math.Max(1, root.DesiredSize.Width);
                heights[i] = Math.Max(1, root.DesiredSize.Height);
                roots[i] = root;
            }

            double cardW = 1;
            foreach (var w in widths) cardW = Math.Max(cardW, w);
            cardW = Math.Ceiling(cardW);

            double maxH = 1;
            foreach (var h in heights) maxH = Math.Max(maxH, h);

            // 第二遍：按统一宽度排版并渲染
            var bitmaps = new RenderTargetBitmap[cases.Length];
            for (int i = 0; i < cases.Length; i++)
            {
                var host = new Border
                {
                    Width = cardW,
                    Background = Brushes.Transparent,
                    Child = roots[i]
                };
                host.Measure(new Size(cardW, double.PositiveInfinity));
                host.Arrange(new Rect(0, 0, cardW, host.DesiredSize.Height));
                host.UpdateLayout();

                var rtb = new RenderTargetBitmap(
                    (int)Math.Ceiling(cardW * 2), (int)Math.Ceiling(host.DesiredSize.Height * 2),
                    192, 192, PixelFormats.Pbgra32);
                rtb.Render(host);
                bitmaps[i] = rtb;
                heights[i] = host.DesiredSize.Height;
            }

            int totalW = (int)Math.Ceiling(pad * 2 + cardW * cases.Length + gap * (cases.Length - 1));
            int totalH = (int)Math.Ceiling(pad * 2 + maxH + captionH);

            var dv = new DrawingVisual();
            using (var dc = dv.RenderOpen())
            {
                var bg = new LinearGradientBrush(
                    Color.FromRgb(0xF2, 0xF4, 0xF7), Color.FromRgb(0xE6, 0xEA, 0xEF), 90);
                dc.DrawRectangle(bg, null, new Rect(0, 0, totalW, totalH));

                for (int i = 0; i < cases.Length; i++)
                {
                    double x = pad + i * (cardW + gap);
                    double y = pad;

                    var card = new Rect(x - 8, y - 8, cardW + 16, maxH + 16);
                    dc.DrawRoundedRectangle(
                        new SolidColorBrush(Color.FromArgb(0x9A, 0xFF, 0xFF, 0xFF)), null, card, 16, 16);

                    dc.DrawImage(bitmaps[i], new Rect(x, y, cardW, heights[i]));

                    var ft = new FormattedText(
                        cases[i].Caption,
                        CultureInfo.GetCultureInfo("zh-CN"),
                        FlowDirection.LeftToRight,
                        new Typeface(new FontFamily("Microsoft YaHei UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
                        11.5,
                        new SolidColorBrush(Color.FromRgb(0x4A, 0x50, 0x59)),
                        1.0)
                    { MaxTextWidth = Math.Max(120, cardW - 4), MaxLineCount = 2, Trimming = TextTrimming.CharacterEllipsis };
                    dc.DrawText(ft, new Point(x, y + maxH + 8));
                }
            }

            var outBmp = new RenderTargetBitmap(totalW * 2, totalH * 2, 192, 192, PixelFormats.Pbgra32);
            outBmp.Render(dv);

            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(outBmp));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath))!);
            using var fs = File.Create(outPath);
            enc.Save(fs);
        }
        /// <summary>把设置窗口离屏渲染一张，供人工核对控件与文案。</summary>
        public static void RunSettings(string outPath)
        {
            var cfg = new PetConfig
            {
                FontSize = 11,
                PanelOpacity = 95,
                PetScale = 1.0
            };
            var win = new SettingsWindow(cfg, () => { });
            var root = (FrameworkElement)win.Content;
            win.Content = null;

            const double w = 330;
            var host = new Border
            {
                Width = w,
                Background = new SolidColorBrush(Color.FromRgb(0xFC, 0xFC, 0xFB)),
                Child = root
            };
            host.Measure(new Size(w, double.PositiveInfinity));
            host.Arrange(new Rect(0, 0, w, host.DesiredSize.Height));
            host.UpdateLayout();

            var rtb = new RenderTargetBitmap(
                (int)Math.Ceiling(w * 2), (int)Math.Ceiling(host.DesiredSize.Height * 2),
                192, 192, PixelFormats.Pbgra32);
            rtb.Render(host);

            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(rtb));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath))!);
            using var fs = File.Create(outPath);
            enc.Save(fs);
        }
    }
}

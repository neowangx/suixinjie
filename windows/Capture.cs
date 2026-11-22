using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Suixinjie
{
    internal enum Tool { Rectangle, Ellipse, Arrow, Pen, Mosaic, Text, Stamp }

    internal sealed class Mark
    {
        private static readonly float[] LineWidths = { 2, 3, 6 };
        private static readonly float[] MosaicWidths = { 14, 24, 40 };
        private static readonly float[] TextSizes = { 14, 18, 26 };
        private static readonly float[] StampSizes = { 22, 30, 42 };

        public Tool Tool { get; }
        private readonly Point[] points;
        private readonly Color color;
        private readonly int size;
        private readonly string text;
        private readonly Rectangle bounds;

        public Mark(Tool tool, Point[] points, Color color, int size, string text = null, Rectangle bounds = default)
        {
            Tool = tool;
            this.points = points;
            this.color = color;
            this.size = size;
            this.text = text;
            this.bounds = bounds;
        }

        public static Font TextFont(int size) => new Font(SystemFonts.MessageBoxFont.FontFamily, TextSizes[size],
                                                          FontStyle.Bold, GraphicsUnit.Pixel);

        public void Draw(Graphics graphics, Bitmap mosaic, Size displaySize)
        {
            using var ink = new SolidBrush(color);
            using var outline = new Pen(ink, LineWidths[size])
                { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            switch (Tool)
            {
                case Tool.Rectangle:
                    graphics.DrawRectangle(outline, bounds);
                    break;
                case Tool.Ellipse:
                    graphics.DrawEllipse(outline, bounds);
                    break;
                case Tool.Arrow:
                    DrawArrow(graphics, outline, ink);
                    break;
                case Tool.Pen:
                    if (points.Length == 1) FillDot(graphics, ink, points[0], outline.Width);
                    else graphics.DrawLines(outline, points);
                    break;
                case Tool.Mosaic:
                    DrawMosaic(graphics, mosaic, displaySize);
                    break;
                case Tool.Text:
                    using (var font = TextFont(size))
                    using (var shade = new SolidBrush(Color.FromArgb(210, Color.Black)))
                    {
                        var anchor = points[0];
                        graphics.DrawString(text, font, shade, new PointF(anchor.X + 1, anchor.Y + 1), StringFormat.GenericTypographic);
                        graphics.DrawString(text, font, ink, anchor, StringFormat.GenericTypographic);
                    }
                    break;
                case Tool.Stamp:
                    using (var font = new Font("Segoe UI Symbol", StampSizes[size], FontStyle.Regular, GraphicsUnit.Pixel))
                    {
                        var extent = graphics.MeasureString(text, font, PointF.Empty, StringFormat.GenericTypographic);
                        var anchor = new PointF(points[0].X - extent.Width / 2, points[0].Y - extent.Height / 2);
                        graphics.DrawString(text, font, ink, anchor, StringFormat.GenericTypographic);
                    }
                    break;
            }
        }

        private static void FillDot(Graphics graphics, Brush brush, Point point, float width) =>
            graphics.FillEllipse(brush, point.X - width / 2, point.Y - width / 2, width, width);

        private void DrawArrow(Graphics graphics, Pen pen, Brush brush)
        {
            Point start = points[0], end = points[1];
            float x = end.X - start.X, y = end.Y - start.Y;
            float length = (float)Math.Sqrt(x * x + y * y);
            if (length == 0) return;
            x /= length;
            y /= length;
            float head = Math.Min(length, 8 + 3 * pen.Width);
            float baseX = end.X - head * x, baseY = end.Y - head * y;
            float wing = head * 0.4f;
            graphics.DrawLine(pen, start, new PointF(baseX + x * head / 4, baseY + y * head / 4));
            graphics.FillPolygon(brush, new[]
            {
                (PointF)end, new PointF(baseX + y * wing, baseY - x * wing),
                new PointF(baseX - y * wing, baseY + x * wing)
            });
        }

        private void DrawMosaic(Graphics graphics, Bitmap mosaic, Size displaySize)
        {
            if (mosaic == null) throw new InvalidOperationException("无法生成马赛克。");
            float width = MosaicWidths[size];
            using var mask = new GraphicsPath(FillMode.Winding);
            if (points.Length == 1)
                mask.AddEllipse(points[0].X - width / 2, points[0].Y - width / 2, width, width);
            else
            {
                mask.AddLines(points);
                using var pen = new Pen(Color.Black, width)
                    { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
                mask.Widen(pen);
            }

            var previous = graphics.Save();
            graphics.SetClip(mask, CombineMode.Intersect);
            graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
            graphics.PixelOffsetMode = PixelOffsetMode.Half;
            graphics.SmoothingMode = SmoothingMode.None;
            graphics.DrawImage(mosaic, new Rectangle(Point.Empty, displaySize), 0, 0,
                               mosaic.Width, mosaic.Height, GraphicsUnit.Pixel);
            graphics.Restore(previous);
        }
    }

    internal static class CaptureImage
    {
        public static Bitmap Grab(Rectangle bounds)
        {
            var image = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppRgb);
            try
            {
                IntPtr screen = GetDC(IntPtr.Zero);
                if (screen == IntPtr.Zero) throw new Win32Exception("无法访问当前桌面。");
                try
                {
                    using var graphics = Graphics.FromImage(image);
                    IntPtr destination = graphics.GetHdc();
                    try
                    {
                        const uint sourceCopyWithLayers = 0x40CC0020;
                        if (!BitBlt(destination, 0, 0, bounds.Width, bounds.Height, screen,
                                    bounds.X, bounds.Y, sourceCopyWithLayers))
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "无法截取当前桌面。");
                    }
                    finally { graphics.ReleaseHdc(destination); }
                }
                finally { ReleaseDC(IntPtr.Zero, screen); }
                return image;
            }
            catch { image.Dispose(); throw; }
        }

        public static Bitmap Pixelate(Bitmap snapshot)
        {
            var mosaic = new Bitmap(Math.Max(1, (snapshot.Width + 11) / 12), Math.Max(1, (snapshot.Height + 11) / 12),
                                    PixelFormat.Format32bppRgb);
            try
            {
                using var graphics = Graphics.FromImage(mosaic);
                graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
                using var attributes = new ImageAttributes();
                attributes.SetWrapMode(WrapMode.TileFlipXY);
                graphics.DrawImage(snapshot, new Rectangle(Point.Empty, mosaic.Size), 0, 0,
                                   snapshot.Width, snapshot.Height, GraphicsUnit.Pixel, attributes);
                return mosaic;
            }
            catch { mosaic.Dispose(); throw; }
        }

        public static Bitmap Render(Bitmap snapshot, Rectangle selection, IEnumerable<Mark> marks, Bitmap mosaic)
        {
            var image = snapshot.Clone(selection, PixelFormat.Format32bppRgb);
            try
            {
                using var graphics = Graphics.FromImage(image);
                graphics.TranslateTransform(-selection.X, -selection.Y);
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                foreach (var mark in marks) mark.Draw(graphics, mosaic, snapshot.Size);
                return image;
            }
            catch { image.Dispose(); throw; }
        }

        public static void Copy(Bitmap image)
        {
            using var png = new MemoryStream();
            image.Save(png, ImageFormat.Png);
            png.Position = 0;
            using var exclusion = new MemoryStream(new byte[] { 0 });
            var data = new DataObject();
            data.SetImage(image);
            data.SetData("PNG", false, png);
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", false, exclusion);
            Clipboard.SetDataObject(data, true, 6, 60);
        }

        public static void Save(Bitmap image, string path)
        {
            var source = Path.Combine(Path.GetDirectoryName(path), "." + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                image.Save(source, ImageFormat.Png);
                if (File.Exists(path)) File.Replace(source, path, null);
                else File.Move(source, path);
            }
            finally { if (File.Exists(source)) File.Delete(source); }
        }

        [DllImport("user32.dll")]
        private static extern IntPtr GetDC(IntPtr window);
        [DllImport("user32.dll")]
        private static extern int ReleaseDC(IntPtr window, IntPtr dc);
        [DllImport("gdi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool BitBlt(IntPtr target, int x, int y, int width, int height,
                                          IntPtr source, int sourceX, int sourceY, uint operation);
    }
}

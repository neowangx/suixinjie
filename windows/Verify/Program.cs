using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Forms;
using Suixinjie;
using Shortcut = Suixinjie.Shortcut;

internal static class Verify
{
    [STAThread]
    private static void Main()
    {
        var reverse = Editor.DragRectangle(new Point(60, 70), new Point(12, 25), false);
        Check(reverse == new Rectangle(12, 25, 48, 45), "reverse drag");
        var square = Editor.DragRectangle(new Point(60, 70), new Point(12, 25), true);
        Check(square == new Rectangle(15, 25, 45, 45), "Shift shape");
        var shortcut = new Shortcut(Keys.D4, Keys.Control | Keys.Shift);
        Check(shortcut.IsValid && shortcut.NativeModifiers == 0x4006 && shortcut.ToString() == "Ctrl + Shift + 4", "hotkey encoding");
        Check(!new Shortcut(Keys.F12, Keys.Alt).IsValid, "reserved hotkey");

        using var snapshot = new Bitmap(360, 216, PixelFormat.Format32bppRgb);
        using (var graphics = Graphics.FromImage(snapshot))
        {
            graphics.Clear(Color.White);
            for (int x = 240; x < 324; x += 4)
                graphics.FillRectangle(Brushes.Black, x, 36, 2, 72);
        }
        using var mosaic = CaptureImage.Pixelate(snapshot);
        var region = new Rectangle(12, 12, 330, 190);
        var marks = new[]
        {
            new Mark(Tool.Rectangle, null, Color.Red, 1, bounds: new Rectangle(20, 24, 36, 24)),
            new Mark(Tool.Ellipse, null, Color.Lime, 1, bounds: new Rectangle(68, 24, 40, 28)),
            new Mark(Tool.Arrow, new[] { new Point(30, 70), new Point(110, 70) }, Color.Red, 1),
            new Mark(Tool.Pen, new[] { new Point(30, 96), new Point(48, 108), new Point(84, 94) }, Color.Blue, 2),
            new Mark(Tool.Text, new[] { new Point(36, 135) }, Color.Red, 1, "Text"),
            new Mark(Tool.Stamp, new[] { new Point(184, 146) }, Color.DarkOrange, 1, "★"),
            new Mark(Tool.Mosaic, new[] { new Point(248, 74), new Point(310, 74) }, Color.Red, 1)
        };
        using var result = CaptureImage.Render(snapshot, region, marks, mosaic);
        Check(result.Size == region.Size, "region image dimensions");
        Color Pixel(int x, int y) => result.GetPixel(x - region.X, y - region.Y);
        Check(Pixel(38, 24).G < 80, "rectangle inside crop");
        Check(Pixel(88, 24).R < 120, "ellipse inside crop");
        Check(Pixel(60, 70).G < 80 && Pixel(94, 74).G < 160, "arrow and head");
        Check(Pixel(48, 108).R < 80, "freehand path");
        Check(Contains(result, region, 36, 135, 60, 30, c => c.R > 185 && c.G < 100), "text composited");
        Check(Contains(result, region, 168, 130, 32, 32, c => c.R > 185 && c.G > 100 && c.B < 100), "stamp composited");
        Check(Math.Abs(Pixel(264, 74).R - Pixel(266, 74).R) < 8, "mosaic obscures stripes");
        Check(Pixel(264, 42).R < 5 && Pixel(266, 42).R > 250, "mosaic is limited to the brush");

        string path = Path.Combine(Path.GetTempPath(), "suixinjie-" + Guid.NewGuid().ToString("N") + ".png");
        try
        {
            CaptureImage.Save(result, path);
            CaptureImage.Save(result, path);
            using var decoded = new Bitmap(path);
            Check(decoded.RawFormat.Guid == ImageFormat.Png.Guid && decoded.Size == region.Size, "PNG save and replace");
        }
        finally { File.Delete(path); }

        using var full = CaptureImage.Render(snapshot, new Rectangle(Point.Empty, snapshot.Size), Array.Empty<Mark>(), null);
        Check(full.Size == snapshot.Size, "full-screen image dimensions");
        Console.WriteLine("PASS: hotkey encoding, crop, all annotation tools, mosaic clipping, and PNG save");
    }

    private static bool Contains(Bitmap image, Rectangle selection, int x, int y, int width, int height, Func<Color, bool> match)
    {
        for (int py = y; py < y + height; py++)
            for (int px = x; px < x + width; px++)
                if (match(image.GetPixel(px - selection.X, py - selection.Y))) return true;
        return false;
    }

    private static void Check(bool condition, string label)
    {
        if (!condition) throw new InvalidOperationException(label);
    }
}

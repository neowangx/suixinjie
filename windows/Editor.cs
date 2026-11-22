using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Suixinjie
{
    internal sealed class Editor : Form
    {
        private static readonly string[] ToolNames = { "矩形", "椭圆", "箭头", "画笔", "马赛克", "文字", "表情" };
        private static readonly string[] ToolIcons = { "□", "◯", "↗", "✎", "▦", "A", "☺" };
        private static readonly Color[] Colors =
        {
            Color.FromArgb(255, 61, 64), Color.DarkOrange, Color.Gold, Color.MediumSeaGreen,
            Color.CornflowerBlue, Color.White, Color.Black
        };
        private static readonly string[] ColorNames = { "红色", "橙色", "黄色", "绿色", "蓝色", "白色", "黑色" };
        private static readonly string[] Stamps = { "✓", "✕", "★", "☺", "♥", "!" };
        private static readonly Color Surface = Color.FromArgb(32, 38, 49);
        private static readonly Color Active = Color.FromArgb(59, 93, 139);
        private static readonly Color Accent = Color.FromArgb(54, 117, 204);

        private readonly Bitmap snapshot;
        private readonly CaptureMode mode;
        private readonly List<Mark> marks = new List<Mark>();
        private readonly Stack<Mark> undone = new Stack<Mark>();
        private readonly List<Point> stroke = new List<Point>();
        private readonly FlowLayoutPanel toolbar, toolsRow, optionsRow, colorRow, stampRow, sizeRow;
        private readonly ToolTip tips = new ToolTip { InitialDelay = 300 };
        private readonly Button[] toolButtons = new Button[ToolNames.Length];
        private readonly Button[] colorButtons = new Button[Colors.Length];
        private readonly Button[] stampButtons = new Button[Stamps.Length];
        private readonly Button[] sizeButtons = new Button[3];
        private readonly Button undoButton, redoButton;
        private readonly float scale;
        private Rectangle selection;
        private Point? origin;
        private Point end;
        private bool square;
        private Tool tool;
        private int colorIndex, stampIndex, sizeIndex = 1;
        private Bitmap mosaic;
        private TextBox textBox;
        private Font editingFont;

        public Editor(Bitmap snapshot, Rectangle display, CaptureMode mode)
        {
            this.snapshot = snapshot;
            this.mode = mode;
            selection = mode == CaptureMode.FullScreen ? new Rectangle(Point.Empty, snapshot.Size) : Rectangle.Empty;
            Text = "随心截编辑";
            FormBorderStyle = FormBorderStyle.None;
            AutoScaleMode = AutoScaleMode.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            Bounds = display;
            DoubleBuffered = true;
            SetStyle(ControlStyles.Opaque, true);
            using (var graphics = CreateGraphics()) scale = Math.Max(1, graphics.DpiX / 96);

            toolbar = Row(FlowDirection.TopDown);
            toolbar.Padding = new Padding(Pixels(5));
            toolbar.BackColor = Surface;
            toolsRow = Row();
            optionsRow = Row();
            colorRow = Row();
            stampRow = Row();
            sizeRow = Row();

            for (int i = 0; i < toolButtons.Length; i++)
            {
                var selected = (Tool)i;
                toolButtons[i] = AddButton(toolsRow, ToolIcons[i], ToolNames[i], () =>
                {
                    FinishText();
                    tool = selected;
                    UpdateToolbar();
                    Cursor = tool == Tool.Text ? Cursors.IBeam : Cursors.Cross;
                });
            }
            toolsRow.Controls.Add(new Panel
            {
                Size = new Size(1, Pixels(19)), Margin = new Padding(Pixels(3), Pixels(6), Pixels(3), 0),
                BackColor = Color.FromArgb(91, 100, 113)
            });
            undoButton = AddButton(toolsRow, "↶", "撤销（Ctrl+Z）", Undo);
            redoButton = AddButton(toolsRow, "↷", "重做（Ctrl+Y）", Redo);
            if (mode == CaptureMode.Region) AddButton(toolsRow, "⌗", "重选", ResetSelection);
            AddButton(toolsRow, "↓", "保存 PNG", () => Complete(true));
            AddButton(toolsRow, "×", "取消（Esc）", Close);
            var copy = AddButton(toolsRow, "✓", "完成并复制（Enter）", () => Complete(false));
            copy.BackColor = Accent;

            for (int i = 0; i < colorButtons.Length; i++)
            {
                var index = i;
                colorButtons[i] = AddButton(colorRow, "●", ColorNames[i], () =>
                {
                    FinishText();
                    colorIndex = index;
                    UpdateToolbar();
                }, 26);
                colorButtons[i].ForeColor = Colors[i];
            }
            for (int i = 0; i < stampButtons.Length; i++)
            {
                var index = i;
                stampButtons[i] = AddButton(stampRow, Stamps[i], "表情 " + Stamps[i], () =>
                {
                    stampIndex = index;
                    UpdateToolbar();
                }, 26);
            }
            for (int i = 0; i < sizeButtons.Length; i++)
            {
                var index = i;
                var label = new[] { "小", "中", "大" }[i];
                sizeButtons[i] = AddButton(sizeRow, label, label + "尺寸", () =>
                {
                    FinishText();
                    sizeIndex = index;
                    UpdateToolbar();
                }, 27);
            }
            optionsRow.Controls.AddRange(new Control[] { colorRow, stampRow, sizeRow });
            toolbar.Controls.AddRange(new Control[] { toolsRow, optionsRow });
            Controls.Add(toolbar);
            Cursor = Cursors.Cross;
            UpdateToolbar();
        }

        private int Pixels(int logical) => (int)Math.Round(logical * scale);

        private static FlowLayoutPanel Row(FlowDirection direction = FlowDirection.LeftToRight) =>
            new FlowLayoutPanel
            {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, FlowDirection = direction,
                WrapContents = false, Margin = Padding.Empty
            };

        private Button AddButton(Control parent, string text, string name, Action action, int width = 30)
        {
            var button = new Button
            {
                Text = text, AccessibleName = name, TabStop = false, UseVisualStyleBackColor = false,
                FlatStyle = FlatStyle.Flat, ForeColor = Color.WhiteSmoke, BackColor = Surface,
                Size = new Size(Pixels(width), Pixels(29)), Margin = new Padding(Pixels(1)), Cursor = Cursors.Default
            };
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.MouseOverBackColor = Active;
            button.Click += (sender, args) => action();
            tips.SetToolTip(button, name);
            parent.Controls.Add(button);
            return button;
        }

        private void UpdateToolbar()
        {
            bool visible = !selection.IsEmpty;
            colorRow.Visible = tool != Tool.Mosaic && tool != Tool.Stamp;
            stampRow.Visible = tool == Tool.Stamp;
            for (int i = 0; i < toolButtons.Length; i++) toolButtons[i].BackColor = (int)tool == i ? Active : Surface;
            for (int i = 0; i < colorButtons.Length; i++)
                colorButtons[i].BackColor = colorIndex == i ? Active : i == Colors.Length - 1 ? Color.Gray : Surface;
            for (int i = 0; i < stampButtons.Length; i++) stampButtons[i].BackColor = stampIndex == i ? Active : Surface;
            for (int i = 0; i < sizeButtons.Length; i++) sizeButtons[i].BackColor = sizeIndex == i ? Active : Surface;
            undoButton.Enabled = marks.Count > 0;
            redoButton.Enabled = undone.Count > 0;
            toolbar.Visible = visible;
            if (visible)
            {
                toolbar.PerformLayout();
                int margin = Pixels(7), width = toolbar.Width, height = toolbar.Height;
                int x = Math.Max(0, Math.Min(selection.Right - width, ClientSize.Width - width - margin));
                int below = selection.Bottom + margin, above = selection.Top - height - margin;
                int y = below + height <= ClientSize.Height ? below : above >= 0 ? above : Math.Max(0, ClientSize.Height - height - margin);
                toolbar.Location = new Point(x, y);
                toolbar.BringToFront();
            }
            Invalidate();
        }

        protected override void OnShown(EventArgs args)
        {
            base.OnShown(args);
            UpdateToolbar();
            Activate();
        }

        protected override void OnPaint(PaintEventArgs args)
        {
            var graphics = args.Graphics;
            graphics.DrawImageUnscaled(snapshot, Point.Empty);
            Rectangle region = selection;
            if (region.IsEmpty && origin.HasValue) region = DragRectangle(origin.Value, end, false);
            if (mode == CaptureMode.Region)
            {
                using var shade = new SolidBrush(Color.FromArgb(110, Color.Black));
                using var outside = new Region(ClientRectangle);
                if (!region.IsEmpty) outside.Exclude(region);
                graphics.FillRegion(shade, outside);
            }
            if (region.IsEmpty) return;
            var restore = graphics.Save();
            graphics.SetClip(region, CombineMode.Intersect);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            foreach (var mark in marks) mark.Draw(graphics, mosaic, snapshot.Size);
            Draft()?.Draw(graphics, mosaic, snapshot.Size);
            graphics.Restore(restore);
            if (mode == CaptureMode.Region)
            {
                using var border = new Pen(Accent, 2);
                graphics.DrawRectangle(border, region);
            }
        }

        protected override void OnMouseDown(MouseEventArgs args)
        {
            base.OnMouseDown(args);
            if (args.Button != MouseButtons.Left) return;
            FinishText();
            if (!selection.IsEmpty)
            {
                if (!selection.Contains(args.Location)) return;
                if (tool == Tool.Text) { StartText(args.Location); return; }
                if (tool == Tool.Stamp) { AddMark(new Mark(tool, new[] { args.Location }, Colors[colorIndex], sizeIndex, Stamps[stampIndex])); return; }
                if (tool == Tool.Mosaic && mosaic == null)
                {
                    try { mosaic = CaptureImage.Pixelate(snapshot); }
                    catch (Exception error) { ShowError(error); return; }
                }
                if (IsStroke) stroke.Add(args.Location);
            }
            origin = end = args.Location;
            square = false;
            Capture = true;
            Invalidate();
        }

        protected override void OnMouseMove(MouseEventArgs args)
        {
            base.OnMouseMove(args);
            if (origin.HasValue) Track(args.Location);
        }

        protected override void OnMouseUp(MouseEventArgs args)
        {
            base.OnMouseUp(args);
            if (args.Button != MouseButtons.Left || !origin.HasValue) return;
            Track(args.Location);
            if (selection.IsEmpty)
            {
                var area = DragRectangle(origin.Value, end, false);
                if (area.Width >= 4 && area.Height >= 4) selection = area;
            }
            else if (Draft() is Mark annotation) AddMark(annotation);
            origin = null;
            stroke.Clear();
            Capture = false;
            UpdateToolbar();
        }

        protected override void OnMouseCaptureChanged(EventArgs args)
        {
            base.OnMouseCaptureChanged(args);
            if (Capture || !origin.HasValue) return;
            origin = null;
            stroke.Clear();
            Invalidate();
        }

        private bool IsStroke => tool == Tool.Pen || tool == Tool.Mosaic;

        private void Track(Point location)
        {
            var rect = selection.IsEmpty ? ClientRectangle : selection;
            end = new Point(Math.Max(rect.Left, Math.Min(rect.Right, location.X)),
                            Math.Max(rect.Top, Math.Min(rect.Bottom, location.Y)));
            square = (ModifierKeys & Keys.Shift) != 0;
            if (!selection.IsEmpty && IsStroke && stroke[stroke.Count - 1] != end) stroke.Add(end);
            Invalidate();
        }

        private Mark Draft()
        {
            if (selection.IsEmpty || !origin.HasValue) return null;
            var start = origin.Value;
            if (IsStroke) return new Mark(tool, stroke.ToArray(), Colors[colorIndex], sizeIndex);
            if (tool == Tool.Arrow)
                return Math.Abs(end.X - start.X) + Math.Abs(end.Y - start.Y) >= 3
                    ? new Mark(tool, new[] { start, end }, Colors[colorIndex], sizeIndex) : null;
            if (tool != Tool.Rectangle && tool != Tool.Ellipse) return null;
            var area = DragRectangle(start, end, square);
            return area.Width >= 3 && area.Height >= 3
                ? new Mark(tool, null, Colors[colorIndex], sizeIndex, bounds: area) : null;
        }

        internal static Rectangle DragRectangle(Point start, Point end, bool square)
        {
            int width = Math.Abs(end.X - start.X), height = Math.Abs(end.Y - start.Y);
            if (square) width = height = Math.Min(width, height);
            return new Rectangle(end.X < start.X ? start.X - width : start.X,
                                 end.Y < start.Y ? start.Y - height : start.Y, width, height);
        }

        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            if (textBox != null)
            {
                if (keyData == Keys.Escape || keyData == Keys.Enter)
                {
                    FinishText(commit: keyData == Keys.Enter);
                    return true;
                }
                if (textBox.Focused) return base.ProcessCmdKey(ref message, keyData);
            }
            switch (keyData)
            {
                case Keys.Escape: Close(); return true;
                case Keys.Enter: Complete(false); return true;
                case Keys.Control | Keys.Z: Undo(); return true;
                case Keys.Control | Keys.Y:
                case Keys.Control | Keys.Shift | Keys.Z: Redo(); return true;
                case Keys.Control | Keys.S: Complete(true); return true;
                default: return base.ProcessCmdKey(ref message, keyData);
            }
        }

        private void StartText(Point location)
        {
            if (selection.Width < 8 || selection.Height < 8) return;
            editingFont = Mark.TextFont(sizeIndex);
            var box = new TextBox
            {
                Font = editingFont, ForeColor = Colors[colorIndex], BackColor = Surface,
                BorderStyle = BorderStyle.FixedSingle, AccessibleName = "输入标注文字"
            };
            int x = Math.Min(location.X, selection.Right - Math.Min(Pixels(70), selection.Width));
            int y = Math.Max(selection.Top, Math.Min(location.Y, selection.Bottom - box.PreferredHeight));
            box.Location = new Point(x, y);
            box.Width = Math.Min(Pixels(240), selection.Right - x);
            textBox = box;
            Controls.Add(box);
            box.BringToFront();
            box.Focus();
        }

        private void FinishText(bool commit = true)
        {
            if (textBox == null) return;
            var box = textBox;
            textBox = null;
            string text = box.Text.Trim();
            var anchor = new Point(box.Left + 2, box.Top + 1);
            Controls.Remove(box);
            box.Dispose();
            editingFont.Dispose();
            editingFont = null;
            Focus();
            if (commit && text.Length > 0) AddMark(new Mark(Tool.Text, new[] { anchor }, Colors[colorIndex], sizeIndex, text));
        }

        private void AddMark(Mark mark)
        {
            marks.Add(mark);
            undone.Clear();
            UpdateToolbar();
        }

        private void Undo()
        {
            FinishText();
            if (marks.Count > 0)
            {
                undone.Push(marks[marks.Count - 1]);
                marks.RemoveAt(marks.Count - 1);
                UpdateToolbar();
            }
        }

        private void Redo()
        {
            FinishText();
            if (undone.Count > 0)
            {
                marks.Add(undone.Pop());
                UpdateToolbar();
            }
        }

        private void ResetSelection()
        {
            FinishText(false);
            selection = Rectangle.Empty;
            marks.Clear();
            undone.Clear();
            Cursor = Cursors.Cross;
            UpdateToolbar();
        }

        private void Complete(bool save)
        {
            if (selection.IsEmpty) return;
            FinishText();
            try
            {
                if (save)
                {
                    using var dialog = new SaveFileDialog
                    {
                        Title = "保存截图", Filter = "PNG 图像 (*.png)|*.png", DefaultExt = "png",
                        FileName = "截图 " + DateTime.Now.ToString("yyyy-MM-dd HH-mm-ss") + ".png"
                    };
                    if (dialog.ShowDialog(this) != DialogResult.OK) return;
                    using var image = CaptureImage.Render(snapshot, selection, marks, mosaic);
                    CaptureImage.Save(image, dialog.FileName);
                }
                else
                {
                    using var image = CaptureImage.Render(snapshot, selection, marks, mosaic);
                    CaptureImage.Copy(image);
                }
                Close();
            }
            catch (Exception error) { ShowError(error); }
        }

        private void ShowError(Exception error) =>
            MessageBox.Show(this, error.Message, "随心截", MessageBoxButtons.OK, MessageBoxIcon.Warning);

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                mosaic?.Dispose();
                tips.Dispose();
            }
            base.Dispose(disposing);
            if (disposing) editingFont?.Dispose();
        }
    }
}

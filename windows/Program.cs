using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

namespace Suixinjie
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            using var instance = new Mutex(false, @"Local\Suixinjie.Tray");
            bool acquired;
            try { acquired = instance.WaitOne(0); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) return;

            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using var tray = new TrayApplication();
                Application.Run(tray);
            }
            catch (Exception error)
            {
                MessageBox.Show(error.Message, "随心截", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            finally { instance.ReleaseMutex(); }
        }
    }

    internal sealed class TrayApplication : ApplicationContext
    {
        private readonly GlobalHotkeys hotkeys = new GlobalHotkeys();
        private readonly ContextMenuStrip menu = new ContextMenuStrip();
        private readonly System.Windows.Forms.Timer delay = new System.Windows.Forms.Timer { Interval = 140 };
        private readonly NotifyIcon tray;
        private readonly Icon icon;
        private readonly ToolStripMenuItem regionItem, fullItem;
        private SettingsForm settings;
        private bool editing;
        private Rectangle screenBounds;
        private CaptureMode nextMode;

        public TrayApplication()
        {
            regionItem = new ToolStripMenuItem("区域截图", null, (sender, args) => Begin(CaptureMode.Region));
            fullItem = new ToolStripMenuItem("全屏截图", null, (sender, args) => Begin(CaptureMode.FullScreen));
            menu.Items.AddRange(new ToolStripItem[]
            {
                regionItem, fullItem, new ToolStripSeparator(),
                new ToolStripMenuItem("设置…", null, (sender, args) => OpenSettings()),
                new ToolStripMenuItem("退出随心截", null, (sender, args) => ExitThread())
            });
            menu.Opening += (sender, args) => RefreshMenu();
            icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            tray = new NotifyIcon
            {
                Text = "随心截", Icon = icon ?? SystemIcons.Application, ContextMenuStrip = menu, Visible = true
            };
            tray.MouseDoubleClick += (sender, args) => { if (args.Button == MouseButtons.Left) Begin(CaptureMode.Region); };
            hotkeys.Pressed += OnHotkey;
            delay.Tick += (sender, args) => { delay.Stop(); Capture(); };
        }

        private void RefreshMenu()
        {
            regionItem.ShortcutKeyDisplayString = hotkeys.IsRegistered(CaptureMode.Region) ? hotkeys[CaptureMode.Region].ToString() : "";
            fullItem.ShortcutKeyDisplayString = hotkeys.IsRegistered(CaptureMode.FullScreen) ? hotkeys[CaptureMode.FullScreen].ToString() : "";
            regionItem.Enabled = fullItem.Enabled = !editing;
        }

        private void OnHotkey(CaptureMode mode)
        {
            if (settings != null) settings.HandleRegisteredShortcut(mode);
            else Begin(mode, fromHotkey: true);
        }

        private void Begin(CaptureMode mode, bool fromHotkey = false)
        {
            if (editing || settings != null) return;
            editing = true;
            screenBounds = Screen.FromPoint(Cursor.Position).Bounds;
            nextMode = mode;
            if (fromHotkey) Capture();
            else delay.Start();
        }

        private void Capture()
        {
            try
            {
                using var image = CaptureImage.Grab(screenBounds);
                using var editor = new Editor(image, screenBounds, nextMode);
                editor.ShowDialog();
            }
            catch (Exception error)
            {
                MessageBox.Show(error.Message, "随心截", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            finally { editing = false; }
        }

        private void OpenSettings()
        {
            if (settings != null || editing) return;
            try
            {
                using var form = new SettingsForm(hotkeys);
                settings = form;
                form.ShowDialog();
            }
            catch (Exception error)
            {
                MessageBox.Show(error.Message, "随心截设置", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            finally { settings = null; }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                delay.Dispose();
                tray.Dispose();
                menu.Dispose();
                hotkeys.Dispose();
                icon?.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}

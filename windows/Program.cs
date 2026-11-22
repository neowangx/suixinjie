using System;
using System.Diagnostics;
using System.Drawing;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Suixinjie
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            if (GitHubUpdater.RunHelper(args, Application.ExecutablePath,
                error => MessageBox.Show(error, "随心截", MessageBoxButtons.OK, MessageBoxIcon.Warning))) return;
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
                GitHubUpdater.ScheduleCleanup(args, Application.ExecutablePath);
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
        private readonly System.Windows.Forms.Timer updateTimer = new System.Windows.Forms.Timer { Interval = 12000 };
        private readonly NotifyIcon tray;
        private readonly Icon icon;
        private readonly ToolStripMenuItem regionItem, fullItem;
        private SettingsForm settings;
        private bool editing;
        private bool checking, prompting, installing;
        private UpdateOffer pendingUpdate;
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
                new ToolStripMenuItem("检查更新…", null, async (sender, args) => await CheckForUpdates(true)),
                new ToolStripMenuItem("退出随心截", null, (sender, args) => { if (!installing) ExitThread(); })
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
            updateTimer.Tick += async (sender, args) =>
            {
                updateTimer.Interval = 60 * 60 * 1000;
                await CheckForUpdates(false);
            };
            updateTimer.Start();
        }

        private void RefreshMenu()
        {
            regionItem.ShortcutKeyDisplayString = hotkeys.IsRegistered(CaptureMode.Region) ? hotkeys[CaptureMode.Region].ToString() : "";
            fullItem.ShortcutKeyDisplayString = hotkeys.IsRegistered(CaptureMode.FullScreen) ? hotkeys[CaptureMode.FullScreen].ToString() : "";
            regionItem.Enabled = fullItem.Enabled = !editing && !prompting && !installing;
        }

        private void OnHotkey(CaptureMode mode)
        {
            if (settings != null) settings.HandleRegisteredShortcut(mode);
            else Begin(mode, fromHotkey: true);
        }

        private void Begin(CaptureMode mode, bool fromHotkey = false)
        {
            if (editing || settings != null || prompting || installing) return;
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
            finally { editing = false; PresentPendingUpdate(); }
        }

        private void OpenSettings()
        {
            if (settings != null || editing || prompting || installing) return;
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
            finally { settings = null; PresentPendingUpdate(); }
        }

        private bool IdleForUpdate => !editing && settings == null && !prompting && !installing;

        private async Task CheckForUpdates(bool manually)
        {
            if (checking || prompting || installing) return;
            checking = true;
            try
            {
                var now = DateTime.UtcNow;
                if (!manually && now - Preferences.LastUpdateCheck < TimeSpan.FromDays(1)) return;
                pendingUpdate = await GitHubUpdater.Latest();
                try { Preferences.LastUpdateCheck = now; }
                catch (UnauthorizedAccessException) { }
                catch (System.Security.SecurityException) { }
                if (manually && pendingUpdate == null && IdleForUpdate)
                    MessageBox.Show("GitHub 上暂时没有可用的 Windows 更新包。", "随心截", MessageBoxButtons.OK,
                                    MessageBoxIcon.Information);
            }
            catch (Exception error)
            {
                if (manually && IdleForUpdate) ShowUpdateError(error);
            }
            finally { checking = false; PresentPendingUpdate(); }
        }

        private async void PresentPendingUpdate()
        {
            if (!IdleForUpdate || pendingUpdate == null) return;
            var offer = pendingUpdate;
            pendingUpdate = null;
            prompting = true;
            var choice = MessageBox.Show("GitHub 上发现随心截 " + offer.Version + "。是否下载并校验更新，然后重启？",
                                        "随心截更新", MessageBoxButtons.YesNo, MessageBoxIcon.Question,
                                        MessageBoxDefaultButton.Button2);
            prompting = false;
            if (choice != DialogResult.Yes) return;
            installing = true;
            try
            {
                using var current = Process.GetCurrentProcess();
                await GitHubUpdater.PrepareAndLaunch(offer, Application.ExecutablePath, current.Id);
                ExitThread();
            }
            catch (Exception error)
            {
                installing = false;
                ShowUpdateError(error);
            }
        }

        private static void ShowUpdateError(Exception error)
        {
            var answer = MessageBox.Show(error.Message + "\n\n打开 GitHub 更新页面？", "无法更新随心截",
                                         MessageBoxButtons.YesNo, MessageBoxIcon.Warning,
                                         MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes) return;
            try { Process.Start(new ProcessStartInfo(GitHubUpdater.ReleasePage) { UseShellExecute = true })?.Dispose(); }
            catch (System.ComponentModel.Win32Exception) { }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                delay.Dispose();
                updateTimer.Dispose();
                tray.Dispose();
                menu.Dispose();
                hotkeys.Dispose();
                icon?.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}

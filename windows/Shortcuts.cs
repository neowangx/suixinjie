using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Suixinjie
{
    internal enum CaptureMode { Region, FullScreen }

    internal readonly struct Shortcut : IEquatable<Shortcut>
    {
        public readonly Keys Key;
        public readonly Keys Modifiers;

        public Shortcut(Keys key, Keys modifiers)
        {
            Key = key;
            Modifiers = modifiers;
        }

        public bool IsValid => (Modifiers & (Keys.Alt | Keys.Control)) != Keys.None
            && (Modifiers & (Keys.Alt | Keys.Control | Keys.Shift)) == Modifiers
            && (int)Key > 0 && (int)Key <= 254
            && Key != Keys.Escape && Key != Keys.PrintScreen && Key != Keys.F12
            && Key != Keys.ControlKey && Key != Keys.ShiftKey && Key != Keys.Menu
            && Key != Keys.LWin && Key != Keys.RWin
            && ((int)Key < (int)Keys.LShiftKey || (int)Key > (int)Keys.RMenu);

        public uint NativeModifiers =>
            ((Modifiers & Keys.Alt) != 0 ? 1u : 0u) |
            ((Modifiers & Keys.Control) != 0 ? 2u : 0u) |
            ((Modifiers & Keys.Shift) != 0 ? 4u : 0u) | 0x4000u;

        public bool Equals(Shortcut other) => Key == other.Key && Modifiers == other.Modifiers;
        public override bool Equals(object obj) => obj is Shortcut other && Equals(other);
        public override int GetHashCode() => (int)(Key | Modifiers);

        public override string ToString()
        {
            var parts = new List<string>();
            if ((Modifiers & Keys.Control) != 0) parts.Add("Ctrl");
            if ((Modifiers & Keys.Alt) != 0) parts.Add("Alt");
            if ((Modifiers & Keys.Shift) != 0) parts.Add("Shift");
            parts.Add((int)Key >= (int)Keys.D0 && (int)Key <= (int)Keys.D9
                ? ((int)Key - (int)Keys.D0).ToString(CultureInfo.InvariantCulture) : Key.ToString());
            return string.Join(" + ", parts);
        }
    }

    internal static class Preferences
    {
        private const string AppKey = @"Software\Suixinjie";
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string AppName = "Suixinjie";

        public static Shortcut Read(CaptureMode mode)
        {
            using (var key = Registry.CurrentUser.OpenSubKey(AppKey))
            {
                if (key?.GetValue(mode.ToString()) is int value)
                {
                    var combined = (Keys)value;
                    var saved = new Shortcut(combined & Keys.KeyCode, combined & Keys.Modifiers);
                    if (saved.IsValid) return saved;
                }
            }
            return new Shortcut(mode == CaptureMode.Region ? Keys.D4 : Keys.D3, Keys.Control | Keys.Shift);
        }

        public static void Write(CaptureMode mode, Shortcut shortcut)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(AppKey))
                key.SetValue(mode.ToString(), (int)(shortcut.Key | shortcut.Modifiers), RegistryValueKind.DWord);
        }

        public static bool StartsWithWindows
        {
            get
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKey))
                    return key?.GetValue(AppName) is string;
            }
            set
            {
                using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (value) key.SetValue(AppName, "\"" + Application.ExecutablePath + "\"");
                    else key.DeleteValue(AppName, false);
                }
            }
        }
    }

    internal sealed class GlobalHotkeys : NativeWindow, IDisposable
    {
        private const int HotKeyMessage = 0x0312;
        private readonly Dictionary<CaptureMode, Shortcut> shortcuts = new Dictionary<CaptureMode, Shortcut>();
        private readonly Dictionary<CaptureMode, int> registrations = new Dictionary<CaptureMode, int>();
        private int nextId;

        public event Action<CaptureMode> Pressed;

        public GlobalHotkeys()
        {
            CreateHandle(new CreateParams { Parent = new IntPtr(-3) });
            foreach (CaptureMode mode in Enum.GetValues(typeof(CaptureMode)))
            {
                var shortcut = Preferences.Read(mode);
                shortcuts.Add(mode, shortcut);
                int id = AllocateId();
                if (RegisterHotKey(Handle, id, shortcut.NativeModifiers, (uint)shortcut.Key))
                    registrations.Add(mode, id);
            }
        }

        public Shortcut this[CaptureMode mode] => shortcuts[mode];
        public bool IsRegistered(CaptureMode mode) => registrations.ContainsKey(mode);

        public string Change(CaptureMode mode, Shortcut shortcut)
        {
            if (!shortcut.IsValid) return "请选择带 Ctrl 或 Alt 的可用组合。";
            var other = mode == CaptureMode.Region ? CaptureMode.FullScreen : CaptureMode.Region;
            if (shortcuts[other].Equals(shortcut)) return "另一种截图方式已使用这个快捷键。";
            if (shortcuts[mode].Equals(shortcut) && IsRegistered(mode)) return null;

            int candidate = AllocateId();
            if (!RegisterHotKey(Handle, candidate, shortcut.NativeModifiers, (uint)shortcut.Key))
                return "该快捷键无法注册，可能已被其他程序或 Windows 占用。";
            try { Preferences.Write(mode, shortcut); }
            catch
            {
                UnregisterHotKey(Handle, candidate);
                throw;
            }
            if (registrations.TryGetValue(mode, out int previous)) UnregisterHotKey(Handle, previous);
            registrations[mode] = candidate;
            shortcuts[mode] = shortcut;
            return null;
        }

        private int AllocateId()
        {
            do { nextId = nextId % 0xBFFF + 1; } while (registrations.ContainsValue(nextId));
            return nextId;
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == HotKeyMessage)
            {
                foreach (var item in registrations)
                {
                    if (item.Value != message.WParam.ToInt32()) continue;
                    Pressed?.Invoke(item.Key);
                    return;
                }
            }
            base.WndProc(ref message);
        }

        public void Dispose()
        {
            foreach (int id in registrations.Values) UnregisterHotKey(Handle, id);
            registrations.Clear();
            DestroyHandle();
        }

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnregisterHotKey(IntPtr window, int id);
    }

    internal sealed class SettingsForm : Form
    {
        private readonly GlobalHotkeys hotkeys;
        private readonly Button[] buttons = new Button[2];
        private readonly Label feedback = new Label { AutoSize = true, MaximumSize = new System.Drawing.Size(370, 0) };
        private CaptureMode? recording;

        public SettingsForm(GlobalHotkeys hotkeys)
        {
            this.hotkeys = hotkeys;
            Text = "随心截设置";
            AutoScaleMode = AutoScaleMode.Dpi;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            StartPosition = FormStartPosition.CenterScreen;
            KeyPreview = true;

            var content = new FlowLayoutPanel
            {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, FlowDirection = FlowDirection.TopDown,
                WrapContents = false, Padding = new Padding(16)
            };
            foreach (CaptureMode mode in Enum.GetValues(typeof(CaptureMode)))
            {
                var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
                var label = new Label { Text = mode == CaptureMode.Region ? "区域截图" : "全屏截图", Width = 78, TextAlign = System.Drawing.ContentAlignment.MiddleLeft, Height = 30 };
                var button = new Button { Width = 160, Height = 30, AccessibleName = label.Text + "快捷键" };
                button.Click += (sender, args) => { recording = mode; RefreshStatus("请按新的组合键，Esc 退出录入。"); };
                row.Controls.Add(label);
                row.Controls.Add(button);
                content.Controls.Add(row);
                buttons[(int)mode] = button;
            }
            content.Controls.Add(feedback);

            var login = new CheckBox { Text = "登录时启动随心截", Checked = Preferences.StartsWithWindows, AutoSize = true };
            login.Click += (sender, args) =>
            {
                try { Preferences.StartsWithWindows = login.Checked; }
                catch (Exception error)
                {
                    login.Checked = !login.Checked;
                    RefreshStatus("无法更新登录启动。" + error.Message);
                }
            };
            content.Controls.Add(login);
            Controls.Add(content);
            RefreshStatus();
        }

        public void HandleRegisteredShortcut(CaptureMode mode)
        {
            if (recording.HasValue && ContainsFocus) Record(hotkeys[mode]);
        }

        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            if (!recording.HasValue) return base.ProcessCmdKey(ref message, keyData);
            var key = keyData & Keys.KeyCode;
            if (key == Keys.Escape) { recording = null; RefreshStatus(); }
            else if (key != Keys.ControlKey && key != Keys.ShiftKey && key != Keys.Menu)
                Record(new Shortcut(key, keyData & Keys.Modifiers));
            return true;
        }

        private void Record(Shortcut shortcut)
        {
            try
            {
                string error = hotkeys.Change(recording.Value, shortcut);
                if (error != null) { RefreshStatus(error); return; }
                recording = null;
                RefreshStatus("快捷键已更新。");
            }
            catch (Exception error) { RefreshStatus("无法保存快捷键。" + error.Message); }
        }

        private void RefreshStatus(string message = null)
        {
            foreach (CaptureMode mode in Enum.GetValues(typeof(CaptureMode)))
            {
                buttons[(int)mode].Text = recording == mode ? "请按快捷键…" : hotkeys[mode].ToString();
                if (!hotkeys.IsRegistered(mode)) buttons[(int)mode].Text += "（不可用）";
            }
            feedback.Text = message ?? "点击快捷键可重新录入。";
        }
    }
}

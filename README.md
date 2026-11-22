# 随心截 · Suixinjie

随心截是一个轻量的 macOS 和 Windows 截图工具。框选区域或截取整屏后，可以直接标注、复制或保存。图像在本机处理。

- macOS 14 或以上使用 Swift、AppKit 和 ScreenCaptureKit，常驻菜单栏。
- [Windows 版](windows/README.md)使用 WinForms 和 GDI，常驻任务栏通知区域，最低兼容目标为 Windows 7 SP1 加 .NET Framework 4.8。

## macOS 构建与启动

需要 macOS 14 或以上，以及 Xcode 或其命令行工具。可在项目目录构建并启动应用。

```sh
./build.sh
open "build/随心截.app"
```

首次抓屏时，在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中添加并启用刚构建的 `随心截.app`，然后退出并重新打开应用。构建脚本默认使用临时签名。如果反复构建，使用 `SIGN_IDENTITY` 指定同一个本地签名身份可帮助 macOS 在更新时识别新版。开关已启用但仍收到权限提示时，可以移除对应旧条目，再添加实际启动的应用。[Apple 屏幕录制授权说明](https://support.apple.com/guide/mac-help/control-access-to-screen-and-system-audio-recording-mchld6aa7d23/mac)

## 使用

菜单栏里的取景框图标可以打开截图、设置和退出菜单。

| 操作 | 默认快捷键 |
| --- | --- |
| 区域截图 | Control + Shift + 4 |
| 截取指针所在显示器 | Control + Shift + 3 |
| 完成并复制 | Return |
| 撤销 / 重做 | Command + Z / Shift + Command + Z |
| 取消 | Esc |

- 工具栏提供矩形、椭圆、箭头、画笔、马赛克、文字和表情，以及配套的颜色或尺寸选项。按住 Shift 拖动矩形或椭圆可画正方形或正圆。
- 输入文字后，先按 Return 确认文字，再按 Return 完成并复制。保存按钮可选择 PNG 文件的位置。
- 在设置里可以重新录入两组全局快捷键，或打开登录启动。登录启动默认关闭。
- 若远程控制软件拦截快捷键，可从被控 Mac 的菜单栏发起截图。

## 本机验证

退出常驻应用后运行 `./verify.sh`。它用合成图验证裁剪、标注、撤销、剪贴板与 PNG，并检查快捷键注册。验收进程已有屏幕录制权限时，还会在内存中验证真机抓屏的像素尺寸。

## 许可证

[MIT](LICENSE)

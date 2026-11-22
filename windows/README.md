# 随心截 Windows 版

支持区域和全屏截图、可自定义的全局快捷键、登录时启动、矩形、椭圆、箭头、画笔、马赛克、文字和表情、撤销和重做。完成后复制到剪贴板，也可以独立保存 PNG。

## 运行

从 [最新发行版](https://github.com/neowangx/suixinjie/releases/latest) 下载 `Suixinjie-windows.zip` 并解压。

运行 `Suixinjie.exe` 后，在任务栏通知区域右键点随心截图标。左键双击也可以开始区域截图。便携版适用普通用户权限，登录启动由应用设置控制，默认关闭。

| 操作 | 默认快捷键 |
| --- | --- |
| 区域截图 | Ctrl + Shift + 4 |
| 截取指针所在显示器 | Ctrl + Shift + 3 |
| 完成并复制 | Enter |
| 保存 PNG | Ctrl + S |
| 撤销 / 重做 | Ctrl + Z / Ctrl + Y |
| 取消 | Esc |

输入文字时第一次按 Enter 提交文字，再按一次复制截图。对于远程控制中被拦截的快捷键，可从被控 Windows 的任务栏菜单发起截图。

托盘菜单中也可手动「检查更新…」。后台发现可用的正式更新后会先询问。自动安装需要 `Suixinjie.exe` 的所在目录可写，且设备能使用 Windows 的受信任证书通过 TLS 1.2 访问 GitHub。目录不可写时可以手动下载替换。

## 构建与兼容性

在有 .NET SDK 的开发机执行以下命令。运行产物使用 .NET Framework 4.8，构建所需的 SDK 和 Windows 运行时各自独立。

```powershell
dotnet build windows/Suixinjie.csproj -c Release
```

产物位于 `windows/bin/Release/net48/`。启动前可一并保留 `Suixinjie.exe` 和 `Suixinjie.exe.config`。Windows 7 需要 SP1 与 .NET Framework 4.8。预期可在 32 位和 64 位 Windows 上运行。Windows 7 的桌面、实际热键、剪贴板粘贴和登录启动需要在真机或虚拟机中单独验收。[微软 .NET Framework 系统要求](https://learn.microsoft.com/dotnet/framework/get-started/system-requirements)

Windows 一般允许在默认策略下运行普通未签名桌面程序。公开分发的便携版仍可能受到下载来源、系统信誉或企业策略的检查。正式分发时可用受信任的 Windows Authenticode 签名加时间戳。验证 SHA-2 签名的 Windows 7 SP1 设备应具备微软相应更新和受信任的证书链。[微软 SHA-2 更新说明](https://support.microsoft.com/en-gb/topic/sha-2-code-signing-support-update-for-windows-server-2008-r2-windows-7-and-windows-server-2008-september-23-2019-84a8aad5-d8d9-2d5c-6d78-34f9aa5f8339) · [微软 SmartScreen 文档](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)

## 验证

GitHub Actions 在 Windows 构建并运行合成图检查，覆盖裁剪、标注、马赛克、PNG 写入及快捷键编码。可在 Windows 开发机执行同一套检查。

```powershell
dotnet build windows/Verify/Suixinjie.Verify.csproj -c Release
.\windows\Verify\bin\Release\net48\Suixinjie.Verify.exe
```

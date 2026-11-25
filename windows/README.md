# 智悲佛网 Windows 桌面版

支持 Windows 11 22H2（内部版本 22621）及以上的 x64 和 ARM64 电脑。界面使用 WPF 的 Fluent 浅色主题，音频由 Windows MediaPlayer 播放。课程目录、收藏和收听进度保存在本机用户的 %LOCALAPPDATA%\ZhibeiFW。封面可在「关于」中清除。

在主页或分类选择课程，点击单集开始收听。底部播放栏支持拖动进度、后退 15 秒、前进 30 秒、倍速和睡眠定时。课程内按目录顺序连播，从最近播放选择时只播放一集。Alt+左箭头返回，Ctrl+F 搜索课程名、拼音全拼或首字母。桌面版沿用 Mac 的在线收听范围。

## 构建

安装微软 .NET 10 SDK，在代码仓库根目录运行。版本号与构建号从根目录的 Version.xcconfig 读取。

```powershell
dotnet run --project windows/Tests
dotnet run --project windows/App/ZhibeiFW.csproj
```

生成带 .NET 桌面运行时的测试文件夹。ARM64 电脑把 win-x64 改为 win-arm64。

```powershell
dotnet publish windows/App/ZhibeiFW.csproj -c Release -r win-x64 --self-contained true -o windows/build/win-x64
```

将整个输出目录复制到 Windows，双击「智悲佛网.exe」。首次获取课程和收听音频需要联网。Mac 可交叉构建两个 Windows 目标，桌面窗口、系统媒体键和声音输出需在 Windows 上验收。

## 双架构安装器

在 Windows 上使用带简体中文语言文件的 Inno Setup 6.7.4。将 `installer/Setup.iss` 和 `App/App.ico` 按原相对路径复制到构建目录，并在同一目录下准备 `Notices`，放入应用、.NET 和 WPF 的许可与声明文本。将两个自包含 Release 输出分别放在 `Payload/win-arm64` 和 `Payload/win-x64`。

向 `ISCC.exe` 传入 `/DAppVersion`（发行版本号）、`/DFileVersion`（发行版本号与末两位构建号组成的四段文件版本）、`/DPayloadRoot`（`Payload` 绝对路径）和 `/DPayloadSize`（两套中较大的单架构输出字节数，排除 PDB）。安装器在运行时选择对应架构，为当前用户安装。对外签名应在打包流程中配置 Authenticode。

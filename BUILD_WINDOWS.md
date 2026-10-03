# YPT Desktop 优化版构建说明

## 环境要求

- Windows 10/11 64 位
- Flutter 3.47 或更高版本
- Visual Studio 2022 或 Build Tools，并安装 **Desktop development with C++**、MSVC、Windows 10/11 SDK、CMake tools
- 已启用 Windows 开发者模式，或终端具备创建符号链接的权限

## 构建

在本文件所在目录打开 PowerShell：

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

生成目录：

```text
build/windows/x64/runner/Release/
```

运行 `ypt_desktop.exe` 前，请保留整个 `Release` 目录及其 `data` 子目录。

本版本的空档活动记录只保存在本机。休息云端接口尚未完成协议验证，因此不会向 YPT 服务端上传这类记录。

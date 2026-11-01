# 构建、发布目录与版本号

各项目独立构建、独立维护版本号。`build/` 保存编译结果，仓库根目录的 `dist/` 保存整理后的运行包、固件包及历史版本。`dist/` 已被 Git 忽略；普通编译不会自动归档所有项目，也不会自动递增版本。

以下 PowerShell 命令均从仓库根目录执行：

```powershell
cd C:\Users\nick\go\src\lpxxn\tepy
```

## 项目与输出对照

| 项目 | 版本设置 | 编译结果 | 发布目录 / 压缩包 |
| --- | --- | --- | --- |
| ESP32 固件 | `firmware/CMakeLists.txt` 的 `project(tepy VERSION ...)` | `firmware/build/` | 自动使用 `dist/firmware/<版本>/`；ZIP 另行生成 |
| Qt Windows 桌面端 | `apps/desktop-qt/CMakeLists.txt`、`src/main.cpp`、`src/main_window.cpp` | `apps/desktop-qt/build/tepy-desktop.exe` | 默认 `dist/tepy-desktop/`；版本目录通过参数指定；ZIP 另行生成 |
| macOS Agent | `apps/macos-agent/cmd/tepy-agent/main.go` 的 `var version` | Mac 上的 `apps/macos-agent/build/tepy-agent` | 构建脚本不写入 `dist/`，需要另外整理和压缩 |
| Flutter Android | `apps/mobile-flutter/pubspec.yaml` 的 `version` | `apps/mobile-flutter/build/app/outputs/flutter-apk/app-release.apk` | 自动使用 `dist/mobile-flutter/<版本>/` |
| Flutter Windows | 与 Android 共用 `pubspec.yaml` | `apps/mobile-flutter/build/windows/x64/runner/Release/` | 自动使用 `dist/flutter-windows/<版本>/`，并生成 `dist/tepy-flutter-<版本>-windows-x64.zip` |

`dist/tepy-desktop-*` 是 Qt 桌面端；`dist/flutter-windows/` 和 `tepy-flutter-*-windows-x64.zip` 是 Flutter 桌面端。两者来自不同工程，版本号不需要相同。Flutter Android / Windows 则来自同一个工程，共用版本设置。

已有 Flutter 手机归档包括 `0.1.0`、`0.1.1`、`0.1.2`、`0.1.3` 和 `0.2.0`，Windows Flutter 从 `0.2.0` 开始提供。历史目录不会随源码升级而自动更新；其中的源码快照、说明和校验文件用于核对当时的交付内容。

## ESP32 固件

在 [firmware/CMakeLists.txt](../firmware/CMakeLists.txt) 设置版本，例如：

```cmake
project(tepy VERSION 0.2.0)
```

需要 ESP-IDF 6.1 环境。先编译、生成合并镜像，再整理发布目录：

```powershell
.\tools\dev\idf.ps1 build
.\tools\dev\idf.ps1 merge-bin -o tepy-merged.bin
.\tools\dev\package-firmware.ps1
```

[package-firmware.ps1](../tools/dev/package-firmware.ps1) 从 CMake 读取版本，默认输出到 `dist/firmware/0.2.0/`。打包前会核对应用镜像中的版本，以及合并镜像中的应用字节是否与本次编译结果一致。修改版本后必须重新编译和生成合并镜像。

发布目录包含 `tepy.bin`、`tepy-merged.bin`、bootloader、分区表、刷机清单、依赖锁和 `SHA256SUMS`。可通过 `-OutputDirectory` 指定其他目录。脚本不自动生成 ZIP；需要压缩包时，在打包成功后另行执行：

```powershell
Compress-Archive -Path .\dist\firmware\0.2.0\* -DestinationPath .\dist\tepy-firmware-0.2.0.zip -Force
```

`tepy.bin` 用于 OTA；合并镜像用于首次安装。日常保留配置升级使用 OTA 或分段刷机清单，详见 [OTA 与串口恢复](ota.md)。

## Qt Windows 桌面端

当前版本 `0.3.0` 在三处分别设置，发布新版本时需要同步修改：

| 文件 | 设置内容 |
| --- | --- |
| [CMakeLists.txt](../apps/desktop-qt/CMakeLists.txt) | `project(tepy_desktop VERSION 0.3.0 LANGUAGES CXX)` |
| [src/main.cpp](../apps/desktop-qt/src/main.cpp) | `QCoreApplication::setApplicationVersion(QStringLiteral("0.3.0"))` |
| [src/main_window.cpp](../apps/desktop-qt/src/main_window.cpp) | 侧栏文字中的 `Desktop 0.3.0` |

需要 Qt、匹配的 Qt MQTT 模块、CMake、Ninja 和 C++23 编译器，具体依赖见 [桌面工具文档](desktop.md)。

```powershell
# 只构建和测试，不整理发布目录
.\tools\dev\desktop.ps1

# 构建、测试，并整理到指定版本目录
.\tools\dev\desktop.ps1 -Package -PackageDirectory .\dist\tepy-desktop-0.3.0
```

[desktop.ps1](../tools/dev/desktop.ps1) 执行 CMake 构建、CTest 和安装，调用 `windeployqt` 收集 Qt DLL、插件及运行库，并附带源码和文档。它还会在仅保留系统目录的 PATH 下运行程序的 `--self-check`，检查运行包能否启动。

**目录名不会从 CMake 版本自动生成。** 不传 `-PackageDirectory` 时默认输出到 `dist/tepy-desktop/`；带版本目录由调用者指定。只改目录名不会修改程序内部版本。

脚本不自动生成 ZIP 或 `SHA256SUMS`。需要校验清单和 ZIP 时，在打包成功后执行以下示例；版本改变时同步修改目录和 ZIP 名称：

```powershell
$qtReleaseDir = (Resolve-Path .\dist\tepy-desktop-0.3.0).Path
$qtReleaseHashes = Get-ChildItem -LiteralPath $qtReleaseDir -Recurse -File |
    Where-Object { $_.Name -ne 'SHA256SUMS' } |
    Sort-Object FullName |
    ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.FullName.Substring($qtReleaseDir.Length + 1).Replace('\', '/')
    }
[IO.File]::WriteAllLines((Join-Path $qtReleaseDir 'SHA256SUMS'), [string[]]$qtReleaseHashes, [Text.UTF8Encoding]::new($false))
Compress-Archive -Path .\dist\tepy-desktop-0.3.0\* -DestinationPath .\dist\tepy-desktop-0.3.0-windows-x64.zip -Force
```

分发时保留整个目录中的 DLL 和插件，用户从解压后的目录运行 `tepy-desktop.exe`。

## macOS Agent

在 [cmd/tepy-agent/main.go](../apps/macos-agent/cmd/tepy-agent/main.go) 设置版本：

```go
var version = "0.2.0"
```

`config.example.toml` 中的 `version = 1` 是配置格式版本，与应用发布版本独立；发布应用新版本时不要据此修改配置格式版本。

需要在 Mac 上使用 Go、Xcode Command Line Tools 和 CGo 原生编译。在 Mac 的仓库根目录执行：

```sh
(cd apps/macos-agent && sh tools/build-macos.sh)
./apps/macos-agent/build/tepy-agent version
```

[build-macos.sh](../apps/macos-agent/tools/build-macos.sh) 执行原生 race 测试、vet 和构建，输出 `apps/macos-agent/build/tepy-agent`。它不会创建 `dist/` 发布目录，也不会生成 ZIP。Windows 的 `tools/dev/agent.ps1` 用于通用代码测试和开发用 EXE 构建，不能代替含 CoreGraphics / IOKit 桥接的原生 Mac 程序。

现有交付目录 `dist/tepy-macos-agent-0.1.0-darwin-arm64/` 是构建后另外整理的运行包，包含程序、示例配置、文档、协议、Go 依赖信息、许可证和校验文件。整理新包时：

1. 用 `tepy-agent version` 确认程序版本，用 `file apps/macos-agent/build/tepy-agent` 确认实际架构；`darwin-arm64` 对应 Apple Silicon。
2. 创建对应版本和架构的目录，复制程序、`config.example.toml`、README、`go.mod` / `go.sum`、公开文档与协议，并收集本次依赖所需的许可证。配置只使用示例文件。
3. 生成文件的 SHA-256 校验清单，完成后压缩整个运行目录。程序需要保留执行权限。

例如整理完成 Apple Silicon `0.1.0` 目录后，可在 Mac 的仓库根目录生成校验清单和 ZIP：

```sh
(
  cd dist/tepy-macos-agent-0.1.0-darwin-arm64
  chmod +x tepy-agent
  find . -type f ! -name SHA256SUMS -exec shasum -a 256 {} \; > SHA256SUMS
)
ditto -c -k --keepParent dist/tepy-macos-agent-0.1.0-darwin-arm64 dist/tepy-macos-agent-0.1.0-darwin-arm64.zip
```

运行和安装步骤见 [macOS Go 服务文档](macos-agent.md)。

### Agent 0.2.0 发布辅助

当前 Apple Silicon 交付为 `dist/tepy-macos-agent-0.2.0-darwin-arm64/` 和同名 ZIP。原生构建脚本不自动整理发布包；新增工具在构建后整理：

```powershell
python tools/dev/package-agent.py --binary apps/macos-agent/build/tepy-agent-darwin-arm64
```

工具默认从工作区 Go 模块缓存收集依赖许可；在 Mac 可指定 `--module-cache "$(go env GOMODCACHE)" --go-license "$(go env GOROOT)/LICENSE"`。源码按 Git 可见文件白名单复制，不包含构建缓存或真实 TOML。文档发布副本去掉独立恢复值，保留原工作区文件。ZIP 包含 SHA256SUMS，并记录 Mac 程序的 Unix 执行权限。

打包前需在 Mac 用新程序确认 version，并运行原生 CGo 构建 / race / vet。打包工具只检查 Mach-O 与架构，不代替运行验证。目标目录已存在时会拒绝混写；可以用 --output 指定新的目录。

## Flutter Android / Windows

两个平台共用 [pubspec.yaml](../apps/mobile-flutter/pubspec.yaml) 的版本。当前源码设置为：

```yaml
version: 0.2.0+6
```

`0.2.0` 是应用版本，`6` 是构建号。Android 使用构建号作为 `versionCode`。两个发布脚本只取 `+` 前的部分生成目录名和文件名，所以从 `0.2.0+5` 改到 `0.2.0+6` 仍然输出到同一个 `0.2.0` 发布目录。

```powershell
# Android：检查、测试、编译并整理发布目录
.\tools\dev\mobile.ps1 -Check -Package

# Windows：检查、测试、编译、整理发布目录并生成 ZIP
.\tools\dev\flutter-windows.ps1 -Check -Package
```

Android 输出 `dist/mobile-flutter/0.2.0/tepy-mobile-0.2.0-arm64.apk`，并附带源码、文档、许可证和 `SHA256SUMS`。脚本不自动生成 Android ZIP。可通过 `-Device <设备ID>` 在构建后使用 ADB 覆盖安装；单独使用 `-Build` 只生成 APK，不整理到 `dist/`。

Windows 输出 `dist/flutter-windows/0.2.0/`，包括 `tepy.exe`、DLL、`data`、x64 C++ 运行库、源码、文档和校验文件，同时自动生成 `dist/tepy-flutter-0.2.0-windows-x64.zip`。

环境和直接使用 Flutter CLI 的方法见 [Android 文档](mobile-flutter.md)、[Windows 文档](flutter-windows.md) 和 [应用 README](../apps/mobile-flutter/README.md)。Android Release 当前使用开发签名，更新已有应用需要保持签名一致。

## 发布新版本与保留历史

1. 只修改本次需要发布的项目版本，并同步相关 README、使用说明和界面版本文字。各项目不要求使用同一版本号。
2. 重新构建、测试，再运行对应的打包步骤。Qt 的目录参数和 Agent 的归档目录、ZIP 名称需要手动同步。
3. 核对程序实际版本、包内文件和校验清单，再进行安装或分发。打包脚本执行的自动测试范围见各项目文档，实机验收记录见 [测试文档](testing.md)。

例如 Flutter 要将下一次交付单独归档，可将版本改成 `0.2.1+7` 后分别打包 Android 和 Windows；脚本会创建 `0.2.1` 目录，已有 `0.2.0` 目录保留。

发布脚本没有统一清理目标目录的逻辑。Flutter 重复打包同一应用版本会覆盖同名文件，复制目录时可能留下已从源码删除的旧文件；固件脚本再次复制到已有目录时也可能因同名文件报错。保留历史时使用新版本或新的输出目录，重新整理同版本包时使用干净的目标目录。

`dist/` 中的目录名只是归档名称，重命名不会改变二进制内的版本。现有历史包中的源码快照也不会因为当前源码修改而自动变化。整理公开包时不加入本机配置、keystore、用户凭据、SDK 或缓存；文档需要检查是否包含本机填写的值。


## Flutter 0.3.0 交付

`pubspec.yaml` 为 `0.3.0+7`，Android / Windows 共用。新增 Mac 诊断 / 事件、明文 JSON 登录密码设置和网络 OTA，说明见 [Flutter 管理](flutter-management.md)。日常 APK 为 `dist/mobile-flutter/0.3.0/tepy-mobile-0.3.0-arm64.apk`，Windows 为 `dist/tepy-flutter-0.3.0-windows-x64.zip`。

`mac-passwords.json` 和临时文件已忽略，运行文件位于应用支持目录，不随二进制 / 源码快照分发。构建不自动安装手机，不自动升级 ESP32。

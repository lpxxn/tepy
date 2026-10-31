[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [switch]$Check,
    [switch]$Build,
    [switch]$Package,
    [string]$Device,
    [string]$Proxy
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$appRoot = Join-Path $repoRoot 'apps/mobile-flutter'
$savedLocation = Get-Location
$savedGradle = $env:GRADLE_USER_HOME
$savedJava = $env:JAVA_TOOL_OPTIONS
$savedHttp = $env:HTTP_PROXY
$savedHttps = $env:HTTPS_PROXY
# 只对当前脚本进程生效，不写用户级 Gradle、Java 或代理设置。
$env:GRADLE_USER_HOME = Join-Path $repoRoot '.venv/flutter-gradle'
try {
    if ($Proxy) {
        $proxyUri = [Uri]$Proxy
        if ($proxyUri.Scheme -ne 'http' -or -not $proxyUri.Host -or $proxyUri.UserInfo) {
            throw 'Proxy 应为不包含用户名密码的 http://host:port。'
        }
        $env:HTTP_PROXY = $Proxy
        $env:HTTPS_PROXY = $Proxy
        $env:JAVA_TOOL_OPTIONS = "$savedJava -Dhttp.proxyHost=$($proxyUri.Host) -Dhttp.proxyPort=$($proxyUri.Port) -Dhttps.proxyHost=$($proxyUri.Host) -Dhttps.proxyPort=$($proxyUri.Port)"
    }
    Set-Location -LiteralPath $appRoot
    & $Flutter pub get
    if ($LASTEXITCODE) { throw 'flutter pub get 失败。' }
    if ($Check -or (-not $Build -and -not $Package -and -not $Device)) {
        # dart 位于相同 Flutter SDK；通过 flutter 工具检查 SDK 版本一致性。
        $flutterCommand = Get-Command $Flutter -ErrorAction Stop
        $dart = Join-Path (Split-Path $flutterCommand.Source) 'dart.bat'
        if (-not (Test-Path -LiteralPath $dart)) { $dart = 'dart' }
        & $dart format --output=none --set-exit-if-changed lib test integration_test test_driver
        if ($LASTEXITCODE) { throw 'Dart 格式检查失败。' }
        & $Flutter analyze --no-pub
        if ($LASTEXITCODE) { throw 'Flutter 静态检查失败。' }
        & $Flutter test --no-pub
        if ($LASTEXITCODE) { throw 'Flutter 测试失败。' }
    }
    if ($Build -or $Package -or $Device) {
        # 始终指定普通入口，防止把 integration_test 的测试入口误打包给用户。
        # 切换 Debug / Release 时让 Flutter 重建插件注册文件，不能加 --no-pub。
        # 否则测试插件的 Debug 注册残留会让 Release Java 编译找不到类。
        & $Flutter build apk --release --target lib/main.dart --target-platform android-arm64
        if ($LASTEXITCODE) { throw 'Android APK 构建失败。' }
    }
    $apk = Join-Path $appRoot 'build/app/outputs/flutter-apk/app-release.apk'
    if ($Package) {
        $versionLine = Get-Content pubspec.yaml | Where-Object { $_ -match '^version: ' } | Select-Object -First 1
        $version = (($versionLine -replace '^version:\s*', '') -split '\+')[0]
        if ($version -notmatch '^\d+\.\d+\.\d+$') { throw '版本格式不受支持。' }
        $packageDir = Join-Path $repoRoot "dist/mobile-flutter/$version"
        $docsDir = Join-Path $packageDir 'docs'
        New-Item -ItemType Directory -Force -Path $packageDir, $docsDir | Out-Null
        $targetApk = Join-Path $packageDir "tepy-mobile-$version-arm64.apk"
        Copy-Item -LiteralPath $apk -Destination $targetApk -Force
        Copy-Item -LiteralPath (Join-Path $appRoot 'THIRD_PARTY.md'), (Join-Path $appRoot 'pubspec.lock') -Destination $packageDir -Force
        $thirdPartyDir = Join-Path $packageDir 'third_party'
        New-Item -ItemType Directory -Force -Path $thirdPartyDir | Out-Null
        Copy-Item -LiteralPath (Join-Path $appRoot 'third_party/usb-serial-LICENSE.txt'), (Join-Path $appRoot 'assets/fonts/OFL.txt') -Destination $thirdPartyDir -Force
        $usbSource = Join-Path $repoRoot '.venv/mobile-third-party/usb-serial-for-android-3.11.0.tar.gz'
        if (Test-Path -LiteralPath $usbSource) {
            if ((Get-FileHash -LiteralPath $usbSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne '9fc12819db958e0e83bc3ec276600758e42e049ec528341c43954768a0793af4') { throw 'USB 驱动源码 Hash 不符。' }
            Copy-Item -LiteralPath $usbSource -Destination $thirdPartyDir -Force
        }
        foreach ($doc in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Filter '*.md' -File) {
            $body = [IO.File]::ReadAllText($doc.FullName)
            # 兼容早期本地文档中用户留下的独立长十六进制行；原文件不改。
            $body = [regex]::Replace($body, '(?m)^\s*[a-fA-F0-9]{24,128}\s*$', '[本地值未包含在发布包中]')
            [IO.File]::WriteAllText((Join-Path $docsDir $doc.Name), $body, [Text.UTF8Encoding]::new($false))
        }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'protocol') -Destination $packageDir -Recurse -Force
        # 只复制 Git 可见的源文件，排除 build、local.properties、keystore 和缓存。
        $sourceFiles = & git -C $repoRoot ls-files --cached --others --exclude-standard -- apps/mobile-flutter
        if ($LASTEXITCODE) { throw '无法枚举 Flutter 源码。' }
        foreach ($relative in $sourceFiles) {
            $destination = [IO.Path]::GetFullPath((Join-Path $packageDir $relative))
            if (-not $destination.StartsWith($packageDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '源码目标超出发布目录。' }
            New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $destination -Force
        }
        $packageTools = Join-Path $packageDir 'tools/dev'
        New-Item -ItemType Directory -Force -Path $packageTools | Out-Null
        foreach ($toolName in 'mobile.ps1', 'flutter-windows.ps1', 'subset-flutter-font.py', 'generate-flutter-icon.py') {
            Copy-Item -LiteralPath (Join-Path $repoRoot "tools/dev/$toolName") -Destination $packageTools -Force
        }
        $readme = "Tepy Mobile $version / Android arm64`n`n开发测试签名，仅供本地实测。入口 lib/main.dart。`n安装：adb -s <设备ID> install -r tepy-mobile-$version-arm64.apk`n使用说明：docs/mobile-flutter.md`n学习导读：docs/flutter-learning.md`n源码：本仓库 apps/mobile-flutter；第三方许可见 THIRD_PARTY.md。`n不包含用户凭据。实际 OTG 读写、密码输入与 TLS Broker 需专项实测。`n"
        [IO.File]::WriteAllText((Join-Path $packageDir 'README.txt'), $readme, [Text.UTF8Encoding]::new($false))
        # 文件名只来自本目录枚举；不含 SDK、缓存、keystore、真实 TOML 或输入历史。
        $hashes = Get-ChildItem -LiteralPath $packageDir -Recurse -File |
            Where-Object { $_.Name -ne 'SHA256SUMS' } |
            Sort-Object FullName |
            ForEach-Object { "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), ([IO.Path]::GetRelativePath($packageDir, $_.FullName).Replace('\', '/')) }
        [IO.File]::WriteAllLines((Join-Path $packageDir 'SHA256SUMS'), $hashes, [Text.UTF8Encoding]::new($false))
        Write-Host "已打包：$packageDir"
    }
    if ($Device) {
        # 显式设备 ID，既不卸载，也不清理该应用已有数据。
        $adb = if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe' } else { 'adb' }
        & $adb -s $Device install -r $apk
        if ($LASTEXITCODE) { throw '手机安装失败，请查看设备授权提示。' }
    }
} finally {
    Set-Location -LiteralPath $savedLocation.Path
    $env:GRADLE_USER_HOME = $savedGradle
    $env:JAVA_TOOL_OPTIONS = $savedJava
    $env:HTTP_PROXY = $savedHttp
    $env:HTTPS_PROXY = $savedHttps
}

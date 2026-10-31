[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [switch]$Check,
    [switch]$Package,
    [switch]$Run,
    [string]$Proxy
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$app = Join-Path $repo 'apps/mobile-flutter'
$savedLocation = Get-Location
$savedHttp = $env:HTTP_PROXY
$savedHttps = $env:HTTPS_PROXY
try {
    if ($Proxy) {
        $uri = [Uri]$Proxy
        if ($uri.Scheme -ne 'http' -or -not $uri.Host -or $uri.UserInfo) { throw '代理应为不含凭据的 http://host:port。' }
        $env:HTTP_PROXY = $Proxy
        $env:HTTPS_PROXY = $Proxy
    }
    Set-Location -LiteralPath $app
    & $Flutter pub get
    if ($LASTEXITCODE) { throw '依赖解析失败。' }
    if ($Check) {
        $dart = Join-Path (Split-Path (Get-Command $Flutter).Source) 'dart.bat'
        & $dart format --output=none --set-exit-if-changed lib test integration_test test_driver
        if ($LASTEXITCODE) { throw '格式检查失败。' }
        & $Flutter analyze --no-pub
        if ($LASTEXITCODE) { throw '静态检查失败。' }
        & $Flutter test --no-pub
        if ($LASTEXITCODE) { throw '自动测试失败。' }
    }
    if (-not $Check -or $Package -or $Run) {
        # 普通入口必须显式指定，避免把原生测试入口打包为日常应用。
        & $Flutter build windows --release --target lib/main.dart
        if ($LASTEXITCODE) { throw 'Windows 构建失败。请检查 C++ 桌面工具链、Windows SDK、ATL，并关闭旧预览窗口。' }
    }
    $release = Join-Path $app 'build/windows/x64/runner/Release'
    if ($Package) {
        $version = ((Get-Content pubspec.yaml | Where-Object { $_ -match '^version: ' } | Select-Object -First 1) -replace '^version:\s*', '') -split '\+' | Select-Object -First 1
        if ($version -notmatch '^\d+\.\d+\.\d+$') { throw '版本格式错误。' }
        $destination = Join-Path $repo "dist/flutter-windows/$version"
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        # 复制完整 Flutter bundle，不能只复制 exe；不包含 PDB 和中间编译产物。
        Get-ChildItem -LiteralPath $release -File | Where-Object { $_.Extension -ne '.pdb' } | Copy-Item -Destination $destination -Force
        Copy-Item -LiteralPath (Join-Path $release 'data') -Destination $destination -Recurse -Force
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $vs) { throw '找不到 Visual Studio C++ 运行库来源。' }
        $redistRoot = Join-Path $vs 'VC/Redist/MSVC'
        $crt = Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object { $_.Name -match '^\d+\.' } | Sort-Object Name -Descending |
            ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName 'x64') -Directory -Filter '*.CRT' -ErrorAction SilentlyContinue } | Select-Object -First 1
        if (-not $crt) { throw '找不到 x64 CRT；发布包未完成。' }
        Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' -File | Copy-Item -Destination $destination -Force
        Copy-Item -LiteralPath (Join-Path $app 'THIRD_PARTY.md'), (Join-Path $app 'pubspec.lock') -Destination $destination -Force
        $docs = Join-Path $destination 'docs'
        New-Item -ItemType Directory -Force -Path $docs | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo 'docs') -Filter '*.md' -File) {
            $body = [IO.File]::ReadAllText($file.FullName)
            $body = [regex]::Replace($body, '(?m)^\s*[a-fA-F0-9]{24,128}\s*$', '[本地值未包含在发布包中]')
            [IO.File]::WriteAllText((Join-Path $docs $file.Name), $body, [Text.UTF8Encoding]::new($false))
        }
        Copy-Item -LiteralPath (Join-Path $repo 'protocol') -Destination $destination -Recurse -Force
        $source = & git -C $repo ls-files --cached --others --exclude-standard -- apps/mobile-flutter
        if ($LASTEXITCODE) { throw '源码枚举失败。' }
        foreach ($relative in $source) {
            $target = [IO.Path]::GetFullPath((Join-Path $destination $relative))
            if (-not $target.StartsWith($destination + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '目标超出发布目录。' }
            New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
            Copy-Item -LiteralPath (Join-Path $repo $relative) -Destination $target -Force
        }
        $scripts = Join-Path $destination 'tools/dev'
        New-Item -ItemType Directory -Force -Path $scripts | Out-Null
        foreach ($name in 'flutter-windows.ps1', 'mobile.ps1', 'subset-flutter-font.py', 'generate-flutter-icon.py') {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts -Force
        }
        $readme = "Tepy Flutter $version / Windows x64`n`n解压整个目录后运行 tepy.exe，保留所有 DLL 与 data 目录。`n同机 Broker：mqtt://127.0.0.1:1883；使用说明：docs/flutter-windows.md。`n与 Qt、Android 配置独立。使用本机安全存储，不包含用户连接信息。`n源代码：apps/mobile-flutter，构建工具：tools/dev，字体许可随源码和应用提供。`n开发版本，未进行发行签名。`n"
        [IO.File]::WriteAllText((Join-Path $destination 'README.txt'), $readme, [Text.UTF8Encoding]::new($false))
        $hashes = Get-ChildItem -LiteralPath $destination -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS' } | Sort-Object FullName |
            ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), [IO.Path]::GetRelativePath($destination, $_.FullName).Replace('\', '/') }
        [IO.File]::WriteAllLines((Join-Path $destination 'SHA256SUMS'), $hashes, [Text.UTF8Encoding]::new($false))
        $zip = Join-Path $repo "dist/tepy-flutter-$version-windows-x64.zip"
        Compress-Archive -Path (Join-Path $destination '*') -DestinationPath $zip -Force
        Write-Host "Windows 发布包：$zip"
    }
    if ($Run) { Start-Process -FilePath (Join-Path $release 'tepy.exe') -WorkingDirectory $release }
} finally {
    Set-Location -LiteralPath $savedLocation
    $env:HTTP_PROXY = $savedHttp
    $env:HTTPS_PROXY = $savedHttps
}

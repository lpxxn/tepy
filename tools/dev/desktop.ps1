[CmdletBinding()]
param(
    [string]$QtPath = 'C:\Qt\6.12.0\mingw_64',
    [string]$CompilerPath = 'C:\Qt\Tools\mingw1310_64\bin',
    [switch]$Run,
    [switch]$Package,
    [string]$PackageDirectory
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$appRoot = Join-Path $repoRoot 'apps/desktop-qt'
$buildDir = Join-Path $appRoot 'build'
$cmake = 'C:\Qt\Tools\CMake_64\bin\cmake.exe'
$ninja = 'C:\Qt\Tools\Ninja\ninja.exe'
$mqttPrefix = Join-Path $repoRoot '.venv/qtmqtt/install'
if (-not (Test-Path -LiteralPath (Join-Path $QtPath 'lib/cmake/Qt6Mqtt/Qt6MqttConfig.cmake')) -and
    -not (Test-Path -LiteralPath (Join-Path $mqttPrefix 'lib/cmake/Qt6Mqtt/Qt6MqttConfig.cmake'))) {
    throw '缺少 Qt MQTT；先安装同版本模块，或运行 tools/dev/desktop-deps.ps1 在工作区构建依赖。'
}
$env:PATH = "$QtPath\bin;$mqttPrefix\bin;$CompilerPath;$env:PATH"
& $cmake -S $appRoot -B $buildDir -G Ninja "-DCMAKE_PREFIX_PATH=$QtPath" "-DCMAKE_CXX_COMPILER=$CompilerPath/g++.exe" "-DCMAKE_MAKE_PROGRAM=$ninja" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $cmake --build $buildDir
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& 'C:\Qt\Tools\CMake_64\bin\ctest.exe' --test-dir $buildDir --output-on-failure
if ($LASTEXITCODE) { exit $LASTEXITCODE }
if ($Package) {
    $packageDir = if ($PackageDirectory) { [IO.Path]::GetFullPath($PackageDirectory) } else { Join-Path $repoRoot 'dist/tepy-desktop' }
    & $cmake --install $buildDir --prefix $packageDir
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    $mqttDll = Join-Path $mqttPrefix 'bin/Qt6Mqtt.dll'
    if (Test-Path -LiteralPath $mqttDll) { Copy-Item -LiteralPath $mqttDll -Destination $packageDir -Force }
    $deployTool = Join-Path $QtPath 'bin/windeployqt.exe'
    if (-not (Test-Path -LiteralPath (Join-Path $QtPath 'bin/Qt6Mqtt.dll'))) {
        # Relocate only the deployment tools and required binaries into a workspace overlay.
        # Its qt.conf redirects Binaries while Plugins/Headers still use the real Qt prefix.
        $deployBin = Join-Path $repoRoot '.venv/qtmqtt/deploy-bin'
        New-Item -ItemType Directory -Force -Path $deployBin | Out-Null
        foreach ($name in @('windeployqt.exe', 'qtpaths6.exe', 'Qt6Core.dll', 'Qt6Gui.dll', 'Qt6Widgets.dll', 'Qt6Network.dll', 'Qt6SerialPort.dll', 'Qt6Svg.dll', 'libgcc_s_seh-1.dll', 'libstdc++-6.dll', 'libwinpthread-1.dll')) {
            Copy-Item -LiteralPath (Join-Path $QtPath "bin/$name") -Destination $deployBin -Force
        }
        Copy-Item -LiteralPath $mqttDll -Destination $deployBin -Force
        $qtConfig = "[Paths]`nPrefix=$($QtPath.Replace('\','/'))`nBinaries=$($deployBin.Replace('\','/'))`n"
        [IO.File]::WriteAllText((Join-Path $deployBin 'qt.conf'), $qtConfig, [Text.UTF8Encoding]::new($false))
        $deployTool = Join-Path $deployBin 'windeployqt.exe'
    }
    & $deployTool --qtpaths (Join-Path (Split-Path $deployTool) 'qtpaths6.exe') --release --no-translations --no-opengl-sw --no-system-d3d-compiler (Join-Path $packageDir 'tepy-desktop.exe')
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    $savedPath = $env:PATH
    try {
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        $check = Start-Process -FilePath (Join-Path $packageDir 'tepy-desktop.exe') -ArgumentList '--self-check' -WindowStyle Hidden -Wait -PassThru
        if ($check.ExitCode) { throw "运行包缺少依赖或启动失败：$($check.ExitCode)" }
    } finally { $env:PATH = $savedPath }
    $packageReadme = (Get-Content -LiteralPath (Join-Path $appRoot 'README.md') -Raw).Replace('../../docs/', 'docs/')
    [IO.File]::WriteAllText((Join-Path $packageDir 'README.md'), $packageReadme, [Text.UTF8Encoding]::new($false))
    $packageDocs = Join-Path $packageDir 'docs'
    New-Item -ItemType Directory -Force -Path $packageDocs | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Filter '*.md' | ForEach-Object {
        $body = Get-Content -LiteralPath $_.FullName -Raw
        if ($_.Name -eq 'getting-started.md') {
            # Do not ship standalone local tokens pasted into the operator's copy of this guide.
            $body = [regex]::Replace($body, '(?m)^[\t ]*[a-fA-F0-9]{24,128}[\t ]*\r?$', '# 本机临时值不包含在分发文档中。')
        }
        [IO.File]::WriteAllText((Join-Path $packageDocs $_.Name), $body, [Text.UTF8Encoding]::new($false))
    }
    $assets = Join-Path $repoRoot 'docs/assets'
    if (Test-Path -LiteralPath $assets) { Copy-Item -LiteralPath $assets -Destination $packageDocs -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $appRoot 'THIRD_PARTY.md') -Destination $packageDir -Force
    $sourceBundle = Join-Path $packageDir 'source'
    $appBundle = Join-Path $sourceBundle 'apps/desktop-qt'
    $toolsBundle = Join-Path $sourceBundle 'tools/dev'
    New-Item -ItemType Directory -Force -Path $appBundle, $toolsBundle | Out-Null
    foreach ($name in @('CMakeLists.txt', 'README.md', 'THIRD_PARTY.md', 'src', 'tests')) {
        Copy-Item -LiteralPath (Join-Path $appRoot $name) -Destination $appBundle -Recurse -Force
    }
    Copy-Item -LiteralPath $packageDocs -Destination $sourceBundle -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'protocol') -Destination $sourceBundle -Recurse -Force
    $packageTools = Join-Path $packageDir 'tools'
    New-Item -ItemType Directory -Force -Path $packageTools | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/mqtt') -Destination $packageTools -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/mqtt') -Destination (Join-Path $sourceBundle 'tools') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/dev/desktop.ps1'), (Join-Path $repoRoot 'tools/dev/desktop-deps.ps1') -Destination $toolsBundle -Force
    $thirdParty = Join-Path $packageDir 'third-party'
    New-Item -ItemType Directory -Force -Path $thirdParty | Out-Null
    $mqttArchive = Join-Path $repoRoot '.venv/qtmqtt/source.tar.gz'
    if (Test-Path -LiteralPath $mqttArchive) {
        Copy-Item -LiteralPath $mqttArchive -Destination (Join-Path $thirdParty 'qtmqtt-6.12.0.tar.gz') -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot '.venv/qtmqtt/qtmqtt-6.12.0/LICENSES') -Destination $thirdParty -Recurse -Force
    }
}
if ($Run) { Start-Process -FilePath (Join-Path $buildDir 'tepy-desktop.exe') -WindowStyle Normal }

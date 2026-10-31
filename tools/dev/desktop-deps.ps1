[CmdletBinding()]
param(
    [string]$QtPath = 'C:\Qt\6.12.0\mingw_64',
    [string]$CompilerPath = 'C:\Qt\Tools\mingw1310_64\bin',
    [string]$Proxy,
    [string]$SourceArchive
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$deps = Join-Path $repoRoot '.venv/qtmqtt'
$archive = Join-Path $deps 'source.tar.gz'
$source = Join-Path $deps 'qtmqtt-6.12.0'
$build = Join-Path $deps 'build'
$prefix = Join-Path $deps 'install'
$expected = '55b2ac2938c6057aebd1df5366860d277ebda445f960111fba0998fedeced700'
New-Item -ItemType Directory -Force -Path $deps | Out-Null
if ($SourceArchive) { Copy-Item -LiteralPath $SourceArchive -Destination $archive -Force }
if (-not (Test-Path -LiteralPath $archive)) {
    $download = @{ Uri = 'https://codeload.github.com/qt/qtmqtt/tar.gz/refs/tags/v6.12.0'; OutFile = $archive }
    if ($Proxy) { $download.Proxy = $Proxy }
    Invoke-WebRequest @download
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Qt MQTT archive checksum mismatch; source was not extracted.'
}
if (-not (Test-Path -LiteralPath (Join-Path $source 'CMakeLists.txt'))) {
    & tar -xf $archive -C $deps
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
$cmake = 'C:\Qt\Tools\CMake_64\bin\cmake.exe'
$env:PATH = "$QtPath\bin;$CompilerPath;$env:PATH"
& $cmake -S $source -B $build -G Ninja "-DCMAKE_PREFIX_PATH=$QtPath" "-DCMAKE_CXX_COMPILER=$CompilerPath/g++.exe" "-DCMAKE_C_COMPILER=$CompilerPath/gcc.exe" -DCMAKE_MAKE_PROGRAM=C:/Qt/Tools/Ninja/ninja.exe -DCMAKE_BUILD_TYPE=Release -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF "-DCMAKE_INSTALL_PREFIX=$prefix"
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $cmake --build $build --parallel 4
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $cmake --install $build
exit $LASTEXITCODE

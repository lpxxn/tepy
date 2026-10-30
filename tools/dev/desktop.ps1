[CmdletBinding()]
param(
    [string]$QtPath = 'C:\Qt\6.12.0\mingw_64',
    [string]$CompilerPath = 'C:\Qt\Tools\mingw1310_64\bin',
    [switch]$Run,
    [switch]$Package
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$appRoot = Join-Path $repoRoot 'apps/desktop-qt'
$buildDir = Join-Path $appRoot 'build'
$cmake = 'C:\Qt\Tools\CMake_64\bin\cmake.exe'
$ninja = 'C:\Qt\Tools\Ninja\ninja.exe'
$env:PATH = "$QtPath\bin;$CompilerPath;$env:PATH"
& $cmake -S $appRoot -B $buildDir -G Ninja "-DCMAKE_PREFIX_PATH=$QtPath" "-DCMAKE_CXX_COMPILER=$CompilerPath/g++.exe" "-DCMAKE_MAKE_PROGRAM=$ninja" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $cmake --build $buildDir
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& 'C:\Qt\Tools\CMake_64\bin\ctest.exe' --test-dir $buildDir --output-on-failure
if ($LASTEXITCODE) { exit $LASTEXITCODE }
if ($Package) {
    $packageDir = Join-Path $repoRoot 'dist/tepy-desktop'
    & $cmake --install $buildDir --prefix $packageDir
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    & (Join-Path $QtPath 'bin/windeployqt.exe') --release --no-translations --no-opengl-sw --no-system-d3d-compiler (Join-Path $packageDir 'tepy-desktop.exe')
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    $packageReadme = (Get-Content -LiteralPath (Join-Path $appRoot 'README.md') -Raw).Replace('../../docs/', 'docs/')
    [IO.File]::WriteAllText((Join-Path $packageDir 'README.md'), $packageReadme, [Text.UTF8Encoding]::new($false))
    $packageDocs = Join-Path $packageDir 'docs'
    New-Item -ItemType Directory -Force -Path $packageDocs | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Filter '*.md' | Copy-Item -Destination $packageDocs
    $assets = Join-Path $repoRoot 'docs/assets'
    if (Test-Path -LiteralPath $assets) { Copy-Item -LiteralPath $assets -Destination $packageDocs -Recurse -Force }
}
if ($Run) { Start-Process -FilePath (Join-Path $buildDir 'tepy-desktop.exe') -WindowStyle Normal }

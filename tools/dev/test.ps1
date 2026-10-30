[CmdletBinding()]
param([string]$Compiler, [string]$Python = 'python', [string]$IdfPath = $env:IDF_PATH)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $Compiler) {
    $command = Get-Command g++ -ErrorAction SilentlyContinue
    if ($command) { $Compiler = $command.Source }
    elseif (Test-Path 'C:\Qt\Tools\mingw1310_64\bin\g++.exe') { $Compiler = 'C:\Qt\Tools\mingw1310_64\bin\g++.exe' }
    else { throw '需要本机 C++23 编译器；通过 -Compiler 指定 g++.exe。' }
}
$compilerBin = Split-Path $Compiler
$env:PATH = "$compilerBin;$env:PATH"
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
$cmake = if ($cmakeCommand) { $cmakeCommand.Source } else { 'C:\Qt\Tools\CMake_64\bin\cmake.exe' }
$ninjaCommand = Get-Command ninja -ErrorAction SilentlyContinue
$ninja = if ($ninjaCommand) { $ninjaCommand.Source } else { 'C:\Qt\Tools\Ninja\ninja.exe' }
$buildDir = Join-Path $repoRoot 'firmware/tests/build'
$env:PYTHONUTF8 = '1'
if (-not $IdfPath) {
    $profilePath = 'C:\Espressif\tools\Microsoft.v6.1.PowerShell_profile.ps1'
    if (Test-Path -LiteralPath $profilePath) {
        $profileText = Get-Content -LiteralPath $profilePath -Raw
        $IdfPath = [regex]::Match($profileText, '"IDF_PATH"\s*=\s*"([^"]+)"').Groups[1].Value
    }
}
if (-not $IdfPath) { throw '请激活 IDF 环境，或通过 -IdfPath 指定 ESP-IDF 6.1 源码。' }
$testDeps = Join-Path $repoRoot '.venv/test-deps'
if (Test-Path -LiteralPath $testDeps) { $env:PYTHONPATH = "$testDeps;$env:PYTHONPATH" }
& $cmake -S (Join-Path $repoRoot 'firmware/tests') -B $buildDir -G Ninja "-DCMAKE_CXX_COMPILER=$Compiler" "-DCMAKE_C_COMPILER=$(Join-Path $compilerBin 'gcc.exe')" "-DCMAKE_MAKE_PROGRAM=$ninja" "-DIDF_SOURCE=$IdfPath"
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $cmake --build $buildDir
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& (Join-Path $buildDir 'tepy_core_tests.exe')
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& (Join-Path $buildDir 'tepy_serial_tests.exe')
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $Python (Join-Path $repoRoot 'tools/dev/check_protocol.py') --core-executable (Join-Path $buildDir 'tepy_core_tests.exe')
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $Python -m unittest discover -s (Join-Path $repoRoot 'tools/mqtt') -p 'test_*.py' -v
exit $LASTEXITCODE

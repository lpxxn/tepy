[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$buildDir = Join-Path $repoRoot 'firmware/build'
$source = Get-Content -LiteralPath (Join-Path $repoRoot 'firmware/CMakeLists.txt') -Raw
$version = [regex]::Match($source, 'project\(tepy VERSION ([0-9.]+)\)').Groups[1].Value
if (-not $version) { throw '无法读取固件版本。' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot "dist/firmware/$version" }
$application = [IO.File]::ReadAllBytes((Join-Path $buildDir 'tepy.bin'))
$builtVersion = [Text.Encoding]::ASCII.GetString($application, 48, 32).Trim([char]0)
if ($builtVersion -ne $version) { throw '应用版本与源码不符，请先构建固件。' }
$merged = [IO.File]::ReadAllBytes((Join-Path $buildDir 'tepy-merged.bin'))
if ($merged.Length -lt (0x20000 + $application.Length)) { throw '合并镜像不完整。' }
$mergedApp = [byte[]]::new($application.Length)
[Array]::Copy($merged, 0x20000, $mergedApp, 0, $application.Length)
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $appHash = [BitConverter]::ToString($sha.ComputeHash($application))
    $mergedAppHash = [BitConverter]::ToString($sha.ComputeHash($mergedApp))
} finally { $sha.Dispose() }
if ($appHash -ne $mergedAppHash) { throw '合并镜像与应用不匹配，请重新运行 idf.py merge-bin。' }
$files = @('tepy.bin', 'tepy-merged.bin', 'flasher_args.json', 'ota_data_initial.bin', 'bootloader/bootloader.bin', 'partition_table/partition-table.bin')
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
foreach ($relative in $files) {
    $destination = Join-Path $OutputDirectory $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $buildDir $relative) -Destination $destination
}
foreach ($relative in @('dependencies.lock', 'partitions.csv')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "firmware/$relative") -Destination (Join-Path $OutputDirectory $relative)
    $files += $relative
}
$sums = foreach ($relative in $files) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $OutputDirectory $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS'), ($sums -join "`n") + "`n", $utf8)
$readme = @"
Tepy firmware $version / ESP32-S3-WROOM-1-N16R8 / ESP-IDF 6.1

OTA：在网页或 Qt 中上传 tepy.bin。
USB 保留配置刷机：在 Qt 中选择 flasher_args.json，保留本目录结构。
tepy-merged.bin 仅用于首次安装；连续写入合并镜像会覆盖空隙中的原配置。
SHA256SUMS 用于文件校验。源码和恢复方法见仓库 docs/ota.md。
"@
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'README.txt'), $readme, $utf8)
Write-Output "Firmware package: $OutputDirectory"

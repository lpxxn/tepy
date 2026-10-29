# Keep native IDF flags (notably -o) out of PowerShell's common-parameter binding.
$idfForwardArgs = [System.Collections.Generic.List[string]]::new()
$idfPort = $null
for ($argumentIndex = 0; $argumentIndex -lt $args.Count; $argumentIndex++) {
    if ($args[$argumentIndex] -eq '-Port') {
        if ($argumentIndex + 1 -ge $args.Count) { throw '-Port 后需要串口名称。' }
        $argumentIndex++
        $idfPort = [string]$args[$argumentIndex]
    } else {
        $idfForwardArgs.Add([string]$args[$argumentIndex])
    }
}
if ($idfForwardArgs.Count -eq 0) { $idfForwardArgs.Add('build') }
$ErrorActionPreference = 'Stop'
$env:PYTHONUTF8 = '1'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $env:IDF_PATH) {
    $idfProfile = 'C:\Espressif\tools\Microsoft.v6.1.PowerShell_profile.ps1'
    if (-not (Test-Path -LiteralPath $idfProfile)) { throw '请先激活 ESP-IDF 6.1 环境。' }
    # Read the installer's exported values without activating IDE helpers or changing its files.
    $profileText = Get-Content -LiteralPath $idfProfile -Raw
    $mapText = [regex]::Match($profileText, '(?s)\$env_var_pairs\s*=\s*@\{(.*?)\}').Groups[1].Value
    foreach ($entry in [regex]::Matches($mapText, '"([A-Z_]+)"\s*=\s*"([^"]*)"')) {
        [Environment]::SetEnvironmentVariable($entry.Groups[1].Value, $entry.Groups[2].Value, 'Process')
    }
    $pathText = [regex]::Match($profileText, '\$env:PATH\s*=\s*"([^"]*)"').Groups[1].Value
    $env:PATH = $pathText.Replace('$env:PATH', $env:PATH)
}
if ($env:IDF_PYTHON_ENV_PATH) { $idfPython = Join-Path $env:IDF_PYTHON_ENV_PATH 'Scripts/python.exe' }
else { $idfPython = (Get-Command python).Source }
$versionSource = Get-Content -LiteralPath (Join-Path $env:IDF_PATH 'tools/cmake/version.cmake') -Raw
$versionParts = foreach ($part in @('MAJOR', 'MINOR', 'PATCH')) {
    [regex]::Match($versionSource, "set\(IDF_VERSION_$part\s+(\d+)\)").Groups[1].Value
}
$env:IDF_VERSION = $versionParts -join '.'
$env:ESP_IDF_VERSION = $versionParts[0..1] -join '.'
$arguments = @('-C', (Join-Path $repoRoot 'firmware'))
if ($idfPort) { $arguments += @('-p', $idfPort) }
$arguments += $idfForwardArgs.ToArray()
& $idfPython (Join-Path $env:IDF_PATH 'tools/idf.py') @arguments
exit $LASTEXITCODE

[CmdletBinding()]
param([string]$Go)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $Go) {
    $projectGo = Join-Path $repoRoot '.venv/agent-tools/windows/go/bin/go.exe'
    if (Test-Path -LiteralPath $projectGo) { $Go = $projectGo }
    else { $Go = (Get-Command go -ErrorAction Stop).Source }
}
$sdkRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path $Go) '..'))
if (Test-Path -LiteralPath (Join-Path $sdkRoot 'VERSION')) { $env:GOROOT = $sdkRoot }
$env:GOPATH = Join-Path $repoRoot '.venv/agent-gopath'
$env:GOCACHE = Join-Path $repoRoot '.venv/agent-gocache'
$env:GOTOOLCHAIN = 'local'
$agentRoot = Join-Path $repoRoot 'apps/macos-agent'
& $Go -C $agentRoot test ./...
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $Go -C $agentRoot vet ./...
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $Go -C $agentRoot build -trimpath -o build/tepy-agent.exe ./cmd/tepy-agent
exit $LASTEXITCODE

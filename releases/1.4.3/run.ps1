# Runs one TradingAgents analysis with the AI provider saved in .env. Started by the "TradingAgents" Desktop shortcut
# (which opens "Run TradingAgents.bat"). Lives in %LOCALAPPDATA%\TradingAgents after install.

$ErrorActionPreference = 'Stop'

$InstallDir = $PSScriptRoot
$VenvPython = Join-Path $InstallDir 'venv\Scripts\python.exe'
$Script     = Join-Path $InstallDir 'run_analysis.py'
$EnvFile    = Join-Path $InstallDir '.env'

function Stop-Run([string]$Message) {
    Write-Host ''
    Write-Host "PROBLEM: $Message" -ForegroundColor Red
    exit 1
}

# Provider id from .env, for the banner only (run_analysis.py does the real reading).
$providerText = ''
if (Test-Path -LiteralPath $EnvFile) {
    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        if ($line -match '^\s*TRADINGAGENTS_LLM_PROVIDER\s*=\s*(\S+)') { $providerText = " (AI provider: $($Matches[1]))" }
    }
}

Write-Host ''
Write-Host "  TradingAgents - daily analysis$providerText" -ForegroundColor White
Write-Host '  Research tool only. It does NOT place trades.' -ForegroundColor Gray
Write-Host ''

if (-not (Test-Path -LiteralPath $VenvPython) -or -not (Test-Path -LiteralPath $Script)) {
    Stop-Run "TradingAgents is not installed yet (or the install did not finish). Double-click '1 - Install (double-click).bat' first."
}
if (-not (Test-Path -LiteralPath $EnvFile)) {
    Stop-Run "Your API key settings are missing. Double-click '1 - Install (double-click).bat' again."
}

$Reports = Join-Path $InstallDir 'reports'   # reports are saved inside the TradingAgents folder

while ($true) {
    $ticker = Read-Host 'Ticker symbol to analyze (press Enter for SPY)'
    if ($null -eq $ticker) { $ticker = '' }
    $ticker = $ticker.Trim().ToUpper()
    if ($ticker -eq '') { $ticker = 'SPY' }
    # Same characters the TradingAgents CLI accepts: letters, digits and . _ - ^ =
    if ($ticker -match '^[A-Z0-9._\-\^=]{1,32}$') { break }
    Write-Host '  That is not a valid ticker. Examples: SPY, AAPL, NVDA, BRK-B, BTC-USD, 0700.HK' -ForegroundColor Yellow
}

$env:PYTHONUTF8 = '1'
Push-Location -LiteralPath $InstallDir
try {
    & $VenvPython $Script --ticker $ticker --reports-dir $Reports
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($code -ne 0) {
    Write-Host ''
    Write-Host 'The analysis did not finish. Read the PROBLEM message above.' -ForegroundColor Red
}
exit $code

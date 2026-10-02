# TradingAgents "Send diagnostics" - started ONLY when you double-click "Send diagnostics" on your Desktop.
# It builds ONE zip file on your Desktop that you can open and read yourself, then attach to your Upwork chat.
# Nothing is uploaded or sent by this script, and it makes no network connection at all.
#
# The zip contains: program/Python/Windows versions, the list of installed Python packages (pip freeze),
# the last 200 lines of the install/update/run logs, and your settings with EVERY VALUE HIDDEN (only the names
# of the settings are shown, plus non-secret ones like which AI provider/model). API keys are never included;
# key-like text that happens to be inside a log line is also masked.

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'TradingAgents'),
    [string]$OutDir = [Environment]::GetFolderPath('Desktop'),
    [string]$PythonExe = ''
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$VenvPython = if ($PythonExe) { $PythonExe } else { Join-Path $InstallDir 'venv\Scripts\python.exe' }

# Settings whose value is NOT secret and is useful for troubleshooting. Everything else is masked.
$PlainSettings = @('TRADINGAGENTS_LLM_PROVIDER', 'TRADINGAGENTS_DEEP_THINK_LLM', 'TRADINGAGENTS_QUICK_THINK_LLM', 'TRADINGAGENTS_LLM_MAX_RETRIES', 'TRADINGAGENTS_LLM_BACKEND_URL')

function Read-EnvPairs([string]$Path) {
    $pairs = New-Object System.Collections.Specialized.OrderedDictionary
    if (-not (Test-Path -LiteralPath $Path)) { return $pairs }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $v = $Matches[2].Trim()
            if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) { $v = $v.Substring(1, $v.Length - 2) }
            $pairs[$Matches[1]] = $v
        }
    }
    return $pairs
}

$secretValues = @()
$envPairs = Read-EnvPairs (Join-Path $InstallDir '.env')
foreach ($k in $envPairs.Keys) { if ($PlainSettings -notcontains $k -and ([string]$envPairs[$k]).Length -ge 6) { $secretValues += [string]$envPairs[$k] } }

function Protect-Text([string]$Text) {
    if ($null -eq $Text) { return '' }
    foreach ($s in $secretValues) { $Text = $Text.Replace($s, '***HIDDEN***') }
    # key-shaped strings (sk-..., sk-ant-..., sk-or-..., AIza..., xai-...) and long tokens after "key"/"token"/"Bearer"
    $Text = [regex]::Replace($Text, '\b(sk-[A-Za-z0-9_\-]{10,}|AIza[A-Za-z0-9_\-]{20,}|xai-[A-Za-z0-9]{10,})', '***HIDDEN***')
    $Text = [regex]::Replace($Text, '(?i)(api[_-]?key|token|secret|authorization|bearer)(["'':=\s]+)([A-Za-z0-9_\-\.]{16,})', '$1$2***HIDDEN***')
    return $Text
}

function Get-Tail([string]$Path, [int]$Count) {
    if (-not (Test-Path -LiteralPath $Path)) { return @("(file not found: $([IO.Path]::GetFileName($Path)))") }
    $lines = @([System.IO.File]::ReadAllLines($Path))
    if ($lines.Count -gt $Count) { $lines = $lines[($lines.Count - $Count)..($lines.Count - 1)] }
    return @($lines | ForEach-Object { Protect-Text $_ })
}

function Invoke-Py([string[]]$PyArgs) {
    if (-not (Test-Path -LiteralPath $VenvPython)) { return @('(Python environment not found)') }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return @(& $VenvPython @PyArgs 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $old }
}

try {
    if (-not (Test-Path -LiteralPath $InstallDir)) { throw "TradingAgents is not installed at $InstallDir." }
    if (-not $OutDir) { throw 'Could not find your Desktop folder.' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('TradingAgents-diag-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        # 1. versions
        $ver = New-Object System.Collections.Generic.List[string]
        $ver.Add("Created:            $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $rel = Join-Path $InstallDir 'release.json'
        if (Test-Path -LiteralPath $rel) { $ver.Add('release.json:       ' + ((Get-Content -LiteralPath $rel -Raw) -replace '\s+', ' ')) } else { $ver.Add('release.json:       (missing)') }
        $cf = Join-Path $InstallDir 'app\.installed-commit'
        $ver.Add('TradingAgents commit: ' + $(if (Test-Path -LiteralPath $cf) { (Get-Content -LiteralPath $cf -Raw).Trim() } else { '(missing)' }))
        $ver.Add("Windows:            $([Environment]::OSVersion.VersionString)")
        $ver.Add("PowerShell:         $($PSVersionTable.PSVersion)")
        $ver.Add('Python:             ' + ((Invoke-Py @('--version')) -join ' '))
        $ver.Add("Install folder:     $InstallDir")
        foreach ($f in @('run.ps1', 'run_analysis.py', 'constraints.txt', 'update.ps1', 'diagnostics.ps1', 'update-pubkey.pub', 'verify_update.py')) {
            $p = Join-Path $InstallDir $f
            if (Test-Path -LiteralPath $p) { $ver.Add(('  {0,-20} sha256 {1}' -f $f, (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower())) } else { $ver.Add(('  {0,-20} MISSING' -f $f)) }
        }
        [System.IO.File]::WriteAllLines((Join-Path $work 'versions.txt'), $ver, $Utf8NoBom)

        # 2. pip freeze
        [System.IO.File]::WriteAllLines((Join-Path $work 'pip-freeze.txt'), [string[]](Invoke-Py @('-m', 'pip', 'freeze')), $Utf8NoBom)

        # 3. logs (last 200 lines each, secrets masked)
        foreach ($pair in @(@('install-log.txt', 'install-log-tail.txt'), @('update.log', 'update-log-tail.txt'), @('last-run-log.txt', 'last-run-log-tail.txt'), @('last-error-log.txt', 'last-error-log-tail.txt'))) {
            $src = Join-Path $InstallDir $pair[0]
            if (Test-Path -LiteralPath $src) { [System.IO.File]::WriteAllLines((Join-Path $work $pair[1]), [string[]](Get-Tail $src 200), $Utf8NoBom) }
        }

        # 4. .env with values masked
        $masked = New-Object System.Collections.Generic.List[string]
        $masked.Add('# Values are hidden on purpose. Only setting names (and non-secret choices) are shown.')
        foreach ($k in $envPairs.Keys) {
            $v = [string]$envPairs[$k]
            if ($PlainSettings -contains $k) { $masked.Add("$k=$v") }
            elseif ($v.Length -eq 0) { $masked.Add("$k=(empty)") }
            else { $masked.Add("$k=***HIDDEN*** (set)") }
        }
        if ($envPairs.Count -eq 0) { $masked.Add('(no .env file found)') }
        [System.IO.File]::WriteAllLines((Join-Path $work 'env-masked.txt'), $masked, $Utf8NoBom)

        # 5. zip
        $zip = Join-Path $OutDir "TradingAgents-diagnostics-$stamp.zip"
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -Force
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Write-Host '  Done. Your diagnostics file is on your Desktop:' -ForegroundColor Green
    Write-Host "    $zip" -ForegroundColor White
    Write-Host ''
    Write-Host '  You can open it and read everything in it first. It has NO API keys (values are hidden).' -ForegroundColor Gray
    Write-Host '  Nothing was sent anywhere. To get help, attach that file to your Upwork message.' -ForegroundColor Gray
    exit 0
} catch {
    Write-Host ''
    Write-Host "  Could not build the diagnostics file: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

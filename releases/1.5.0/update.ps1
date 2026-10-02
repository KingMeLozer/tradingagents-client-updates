# TradingAgents "Check for updates" - started ONLY when you double-click "Check for updates" on your Desktop.
# It is not a service, not a scheduled task and does not run in the background.
#
# What it does, in order:
#   1. Downloads one small file (manifest.json) and its signature over HTTPS from the public GitHub page
#      of the person who sold you this setup. It only ever reads from there; nothing is uploaded.
#   2. Checks the signature against the public key that came with your installer (update-pubkey.pub).
#      A file that is not signed with the matching secret key is rejected and nothing is changed.
#   3. Shows you the release notes and asks you to type Y. No Y = nothing is changed.
#   4. Downloads the changed files, checks each SHA-256 fingerprint listed in the signed manifest,
#      saves a rollback copy of what you have now, then applies the update.
#   5. The update never reads, copies, uploads or changes your .env file (your API key). The start-up check in step 4
#      only launches the normal program, which reads .env locally exactly as it does when you run an analysis
#      (that check makes no AI calls and sends nothing anywhere).
# Everything is written to update.log in the same folder. No telemetry, no inbound connections.
#
# Use "-Rollback" (started by "Undo last update.bat" in the install folder) to restore the copy saved before the last update.

[CmdletBinding()]
param(
    [switch]$Rollback,
    # Below here: testing only. The signature check still applies with any of these.
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'TradingAgents'),
    [string]$BaseUrl = 'https://raw.githubusercontent.com/KingMeLozer/tradingagents-client-updates/main',
    [string]$PythonExe = '',
    [switch]$AssumeYes,
    [switch]$TestMode,
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$Utf8NoBom   = New-Object System.Text.UTF8Encoding $false
$LogFile     = Join-Path $InstallDir 'update.log'
$AppDir      = Join-Path $InstallDir 'app'
$VenvPython  = if ($PythonExe) { $PythonExe } else { Join-Path $InstallDir 'venv\Scripts\python.exe' }
$ReleaseFile = Join-Path $InstallDir 'release.json'
$CommitFile  = Join-Path $AppDir '.installed-commit'
$PubKey      = Join-Path $InstallDir 'update-pubkey.pub'
$Verifier    = Join-Path $InstallDir 'verify_update.py'
$RollbackRoot = Join-Path $InstallDir 'rollback'

# The ONLY files an update is allowed to replace. The public key, verify_update.py, install.ps1 and
# .env are deliberately NOT on this list: an update can never change who is trusted or touch your key.
$AllowedFiles = @('run.ps1', 'run_analysis.py', 'alpaca_client.py', 'auto_sell.py', 'Run TradingAgents.bat', 'constraints.txt', 'READ ME FIRST.txt', 'update.ps1', 'diagnostics.ps1', 'ta-app.ps1', 'Run TradingAgents (console).bat')
$SelfFiles    = @('update.ps1', 'diagnostics.ps1')   # applied last
$Sha256Re     = '^[0-9a-fA-F]{64}$'
$CommitRe     = '^[0-9a-f]{40}$'
$VersionRe    = '^\d{1,4}\.\d{1,4}\.\d{1,4}$'

function Write-Log([string]$Message) {
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $Utf8NoBom)
    } catch { }
}
function Say([string]$Message, [string]$Color = 'Gray') { Write-Host $Message -ForegroundColor $Color; Write-Log $Message }
function Stop-Update([string]$Message) { throw (New-Object System.Exception ('UPDATE_STOP::' + $Message)) }

function Confirm-Yes([string]$Question) {
    if ($AssumeYes) { Write-Host "$Question Y (assumed)"; return $true }
    $a = Read-Host $Question
    return ($null -ne $a -and $a.Trim().ToUpper() -eq 'Y')
}

function Invoke-Python([string[]]$PyArgs) {
    # Returns @{ Code; Output } . Never throws on a non-zero exit.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $VenvPython @PyArgs 2>&1 | ForEach-Object { "$_" }
        return @{ Code = $LASTEXITCODE; Output = @($out) }
    } finally { $ErrorActionPreference = $old }
}

function Get-FileSha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower() }

function Get-Installed {
    if (-not (Test-Path -LiteralPath $ReleaseFile)) { Stop-Update "This install has no release.json. Double-click '1 - Install (double-click).bat' from your setup folder once, then try again." }
    $j = Get-Content -LiteralPath $ReleaseFile -Raw | ConvertFrom-Json
    if ([string]$j.version -notmatch $VersionRe) { Stop-Update 'release.json looks damaged. Run the installer again (your keys are kept).' }
    return $j
}

function Save-Release([string]$Version, [string]$Commit) {
    $obj = [ordered]@{ version = $Version; commit = $Commit; updated = (Get-Date -Format 's') }
    [System.IO.File]::WriteAllText($ReleaseFile, ($obj | ConvertTo-Json), $Utf8NoBom)
}

function Invoke-PipInstall {
    $constraints = Join-Path $InstallDir 'constraints.txt'
    $pipCommon = @('--disable-pip-version-check', '--no-input', '--timeout', '60', '--retries', '3')
    Say '    Installing Python packages (this can take a few minutes)...' 'Gray'
    $r = Invoke-Python (@('-m', 'pip', 'install', '--prefer-binary', '-c', $constraints, $AppDir) + $pipCommon)
    foreach ($l in $r.Output) { Write-Log ('    pip: ' + $l) }
    if ($r.Code -ne 0) { throw (New-Object System.Exception "pip failed with exit code $($r.Code)") }
}

# ---- copying files over a running copy (1.5.0) ----
# "Access to the path ...\ta-app.ps1 is denied" happens when the TradingAgents window (or antivirus software such as Norton)
# still has the file open. Before copying, the installer closes a running TradingAgents window, clears the read-only flag on
# the old file and tries each copy 3 times, one second apart. If it still fails the person gets a plain message.

# Pure filter, unit-tested: ids of PowerShell processes whose command line runs ta-app.ps1 from $DestPath
# ($Procs = Win32_Process rows with ProcessId, Name, CommandLine). Never returns $SelfPid.
function Select-AppProcessIds($Procs, [string]$DestPath, [int]$SelfPid) {
    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($p in @($Procs)) {
        if ($null -eq $p -or $null -eq $p.CommandLine) { continue }
        if ([int]$p.ProcessId -eq $SelfPid) { continue }
        if ([string]$p.Name -notmatch '^(powershell|pwsh)(\.exe)?$') { continue }
        $cl = [string]$p.CommandLine
        if (($DestPath -and $cl.IndexOf($DestPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
            $cl.IndexOf('TradingAgents\ta-app.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $ids.Add([int]$p.ProcessId) }
    }
    return @($ids.ToArray())
}

# Closes the running TradingAgents window (and the analysis it started) so ta-app.ps1 can be replaced.
function Stop-RunningTradingAgentsApp([string]$DestPath) {
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)
        $ids = @(Select-AppProcessIds $procs $DestPath $PID)
        foreach ($id in $ids) {
            Write-Log "Closing the running TradingAgents window (process $id) so its files can be replaced."
            try { Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$id, '/T', '/F') -WindowStyle Hidden -Wait }
            catch { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { Write-Log ('Could not close process ' + $id + ': ' + $_.Exception.Message) } }
        }
        if ($ids.Count -gt 0) { Start-Sleep -Milliseconds 800 }
    } catch { Write-Log ('Could not look for a running TradingAgents window: ' + $_.Exception.Message) }
}

# Copies one file: clears ReadOnly on the destination, retries $Tries times with $DelayMs between tries.
# Returns '' on success, or the last error text. $Copier is only for tests.
function Copy-FileHardened([string]$Source, [string]$Dest, [int]$Tries = 3, [int]$DelayMs = 1000, [scriptblock]$Copier = $null) {
    $last = ''
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            if (Test-Path -LiteralPath $Dest) {
                try { $it = Get-Item -LiteralPath $Dest -Force; if ($it.IsReadOnly) { $it.IsReadOnly = $false } } catch { }
            }
            if ($null -ne $Copier) { & $Copier $Source $Dest } else { Copy-Item -LiteralPath $Source -Destination $Dest -Force -ErrorAction Stop }
            return ''
        } catch {
            $last = $_.Exception.Message
            Write-Log ("Copy attempt $i of $Tries failed for '$Dest': $last")
            if ($i -lt $Tries) { Start-Sleep -Milliseconds $DelayMs }
        }
    }
    return $last
}

function Get-CopyFailMessage([string]$FileName, [string]$Detail) {
    return ("Windows would not let the update replace the file '$FileName'.`n" +
        "  Fix 1: close TradingAgents completely (the window and any black window), then run this again.`n" +
        "  Fix 2: if it happens again, your antivirus (Norton) is probably holding the file. Add this folder to Norton's exclusions,`n" +
        "  then run this again:  %LOCALAPPDATA%\TradingAgents`n" +
        "  (Norton: Settings > Antivirus > Scans and Risks > Exclusions / Low Risks > Configure.)`n" +
        "  What Windows said: $Detail")
}

# Copies one rollback set back over the current install.
function Restore-Rollback([string]$Dir) {
    Say "Restoring your previous version from $Dir" 'Yellow'
    $meta = Get-Content -LiteralPath (Join-Path $Dir 'meta.json') -Raw | ConvertFrom-Json
    foreach ($f in $AllowedFiles) {
        $src = Join-Path $Dir ('files\' + $f)
        if (Test-Path -LiteralPath $src) {
            $e = Copy-FileHardened $src (Join-Path $InstallDir $f)
            if ($e) { throw (New-Object System.Exception (Get-CopyFailMessage $f $e)) }
        }
    }
    $appBackup = Join-Path $Dir 'app'
    if (Test-Path -LiteralPath $appBackup) {
        if (Test-Path -LiteralPath $AppDir) { Remove-Item -LiteralPath $AppDir -Recurse -Force }
        Copy-Item -LiteralPath $appBackup -Destination $AppDir -Recurse -Force
    }
    Save-Release ([string]$meta.version) ([string]$meta.commit)
    Invoke-PipInstall
}

function Invoke-Rollback {
    Say 'Undo last update' 'Cyan'
    $dirs = @()
    if (Test-Path -LiteralPath $RollbackRoot) { $dirs = @(Get-ChildItem -LiteralPath $RollbackRoot -Directory | Sort-Object Name -Descending) }
    if ($dirs.Count -eq 0) { Stop-Update 'There is no saved previous version to go back to.' }
    $meta = Get-Content -LiteralPath (Join-Path $dirs[0].FullName 'meta.json') -Raw | ConvertFrom-Json
    $cur = Get-Installed
    Write-Host ''
    Write-Host "  You have version $($cur.version). The saved previous version is $($meta.version)." -ForegroundColor White
    if (-not (Confirm-Yes '  Go back to it? Type Y and press Enter (anything else cancels)')) { Say 'Cancelled. Nothing was changed.' 'Yellow'; return }
    Restore-Rollback $dirs[0].FullName
    Say "DONE - you are back on version $($meta.version). Your API key was not touched." 'Green'
}

function Get-Download([string]$Url, [string]$OutFile, [int64]$MaxBytes) {
    if ($Url -notmatch '^https://' -and -not ($TestMode -and $Url -match '^http://(localhost|127\.0\.0\.1)[:/]')) { Stop-Update "Refusing a non-HTTPS address: $Url" }
    try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120 }
    catch { Stop-Update ("Could not download $Url`n  $($_.Exception.Message)`n  Check your internet connection and try again.") }
    if ((Get-Item -LiteralPath $OutFile).Length -gt $MaxBytes) { Remove-Item -LiteralPath $OutFile -Force; Stop-Update "A downloaded file was larger than expected ($Url). Nothing was changed." }
}

function Invoke-Update {
    if (-not (Test-Path -LiteralPath $InstallDir)) { Stop-Update "TradingAgents is not installed at $InstallDir." }
    Write-Log '================ Update check started ================'
    if ($Rollback) { Invoke-Rollback; return }
    if (-not (Test-Path -LiteralPath $VenvPython)) { Stop-Update 'TradingAgents is not fully installed yet. Run the installer first.' }
    if (-not (Test-Path -LiteralPath $PubKey) -or -not (Test-Path -LiteralPath $Verifier)) { Stop-Update 'The update public key is missing. Run the installer again (your keys are kept).' }
    $installed = Get-Installed

    Write-Host ''
    Write-Host '  TradingAgents - check for updates' -ForegroundColor White
    Write-Host "  You have version $($installed.version)." -ForegroundColor Gray
    Write-Host '  This only reads a public web page. Nothing changes unless you say Y below.' -ForegroundColor Gray
    Write-Host ''

    $work = Join-Path $InstallDir ('updates\work-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        # ---- 1. manifest + signature ----
        $mPath = Join-Path $work 'manifest.json'
        $sPath = Join-Path $work 'manifest.json.minisig'
        Say '  Checking for a new version...' 'Gray'
        Get-Download "$BaseUrl/manifest.json" $mPath 1MB
        Get-Download "$BaseUrl/manifest.json.minisig" $sPath 16KB

        # ---- 2. signature ----
        $v = Invoke-Python @($Verifier, $PubKey, $mPath, $sPath)
        Write-Log ('verify: code ' + $v.Code + ' ' + ($v.Output -join ' | '))
        if ($v.Code -ne 0) {
            Stop-Update ("The update file's signature is NOT valid, so it was rejected and nothing was changed.`n  ($($v.Output -join ' '))`n  Please send the update.log file to the person who set this up.")
        }
        Say '  Signature OK (signed by the publisher key that came with your installer).' 'Green'

        # ---- 3. parse + validate ----
        $m = [System.IO.File]::ReadAllText($mPath, $Utf8NoBom) | ConvertFrom-Json
        if ([string]$m.product -ne 'tradingagents-windows' -or [int]$m.schema -ne 1) { Stop-Update 'The update file is for something else, or needs a newer updater. Nothing was changed.' }
        $newVer = [string]$m.version
        if ($newVer -notmatch $VersionRe) { Stop-Update 'The update file has an invalid version. Nothing was changed.' }
        $newCommit = [string]$m.tradingagents_commit
        if ($newCommit -notmatch $CommitRe) { Stop-Update 'The update file has an invalid TradingAgents version pin. Nothing was changed.' }
        $cmp = ([version]$newVer).CompareTo([version]([string]$installed.version))
        if ($cmp -eq 0) { Say "  You are up to date (version $($installed.version))." 'Green'; return }
        if ($cmp -lt 0) { Say "  The published version ($newVer) is older than yours ($($installed.version)). Nothing to do." 'Green'; return }

        $files = @()
        foreach ($f in @($m.files)) {
            $name = [string]$f.path
            if ($AllowedFiles -notcontains $name) { Stop-Update "The update lists a file that updates are not allowed to change ('$name'). Nothing was changed." }
            if ([string]$f.sha256 -notmatch $Sha256Re) { Stop-Update "Bad fingerprint for '$name' in the update file. Nothing was changed." }
            $files += @{ Path = $name; Sha = ([string]$f.sha256).ToLower(); Size = [int64]$f.size }
        }
        $archive = $null
        if ($null -ne $m.app_archive) {
            $an = [string]$m.app_archive.name
            if ($an -notmatch '^[A-Za-z0-9._-]{1,100}\.zip$' -or [string]$m.app_archive.sha256 -notmatch $Sha256Re) { Stop-Update 'Bad program-archive entry in the update file. Nothing was changed.' }
            $archive = @{ Name = $an; Sha = ([string]$m.app_archive.sha256).ToLower(); Size = [int64]$m.app_archive.size }
        }
        $curCommit = ''
        if (Test-Path -LiteralPath $CommitFile) { $curCommit = (Get-Content -LiteralPath $CommitFile -Raw).Trim() }
        $commitChanges = ($newCommit -ne $curCommit)
        if ($commitChanges -and $null -eq $archive) { Stop-Update 'The update changes the TradingAgents version but includes no program archive. Nothing was changed.' }

        # ---- 4. show notes, ask ----
        Write-Host ''
        Write-Host "  NEW VERSION AVAILABLE: $newVer  (you have $($installed.version))" -ForegroundColor Cyan
        if ($m.released) { Write-Host "  Released: $($m.released)" -ForegroundColor Gray }
        Write-Host ''
        Write-Host '  What is in it:' -ForegroundColor White
        foreach ($line in (([string]$m.notes) -split "`n")) { Write-Host ('    ' + $line.TrimEnd("`r")) }
        Write-Host ''
        Write-Host '  Files that will be replaced:' -ForegroundColor White
        $changed = @()
        foreach ($f in $files) {
            $cur = Join-Path $InstallDir $f.Path
            if ((Test-Path -LiteralPath $cur) -and ((Get-FileSha256 $cur) -eq $f.Sha)) { continue }
            $changed += $f
            Write-Host ('    ' + $f.Path)
        }
        if ($commitChanges) { Write-Host "    TradingAgents program code -> $($newCommit.Substring(0,7)) (and its Python packages)" }
        if ($changed.Count -eq 0 -and -not $commitChanges) {
            Say '  This release changes nothing on your PC. Recording the new version number only.' 'Gray'
        }
        Write-Host ''
        Write-Host '  Your API key / .env file will NOT be touched. A rollback copy is saved first.' -ForegroundColor Green
        Write-Host ''
        if (-not (Confirm-Yes '  Install this update? Type Y and press Enter (anything else cancels)')) {
            Say '  Cancelled. Nothing was changed.' 'Yellow'
            return
        }
        Write-Log "User confirmed update $($installed.version) -> $newVer"

        # ---- 5. download + verify every asset ----
        $stage = Join-Path $work 'files'
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        $assetBase = "$BaseUrl/releases/$newVer"
        foreach ($f in $changed) {
            $dest = Join-Path $stage $f.Path
            Say "  Downloading $($f.Path)" 'Gray'
            Get-Download ($assetBase + '/' + [Uri]::EscapeDataString($f.Path)) $dest 20MB
            if ((Get-FileSha256 $dest) -ne $f.Sha) { Stop-Update "The downloaded file '$($f.Path)' does not match its signed fingerprint. Nothing was changed." }
        }
        $newAppExtract = $null
        if ($commitChanges) {
            $zip = Join-Path $work $archive.Name
            Say "  Downloading $($archive.Name)" 'Gray'
            Get-Download ($assetBase + '/' + [Uri]::EscapeDataString($archive.Name)) $zip 200MB
            if ((Get-FileSha256 $zip) -ne $archive.Sha) { Stop-Update 'The downloaded program archive does not match its signed fingerprint. Nothing was changed.' }
            $ex = Join-Path $work 'app-extract'
            Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
            $top = @(Get-ChildItem -LiteralPath $ex -Directory)
            if ($top.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $top[0].FullName 'pyproject.toml'))) { Stop-Update 'The program archive does not look right. Nothing was changed.' }
            $newAppExtract = $top[0].FullName
        }
        Say '  All downloads match their signed fingerprints.' 'Green'

        # ---- 6. rollback copy ----
        $rbDir = Join-Path $RollbackRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-from-' + $installed.version)
        New-Item -ItemType Directory -Force -Path (Join-Path $rbDir 'files') | Out-Null
        foreach ($f in $AllowedFiles) {
            $cur = Join-Path $InstallDir $f
            if (Test-Path -LiteralPath $cur) { Copy-Item -LiteralPath $cur -Destination (Join-Path $rbDir ('files\' + $f)) -Force }
        }
        if (Test-Path -LiteralPath $AppDir) { Copy-Item -LiteralPath $AppDir -Destination (Join-Path $rbDir 'app') -Recurse -Force }
        $fz = Invoke-Python @('-m', 'pip', 'freeze')
        if ($fz.Code -eq 0) { [System.IO.File]::WriteAllLines((Join-Path $rbDir 'pip-freeze.txt'), [string[]]$fz.Output, $Utf8NoBom) }
        $metaObj = [ordered]@{ version = [string]$installed.version; commit = $curCommit; saved = (Get-Date -Format 's') }
        [System.IO.File]::WriteAllText((Join-Path $rbDir 'meta.json'), ($metaObj | ConvertTo-Json), $Utf8NoBom)
        Say "  Rollback copy saved: $rbDir" 'Gray'

        # ---- 7. apply (auto-restore on any failure) ----
        try {
            Stop-RunningTradingAgentsApp (Join-Path $InstallDir 'ta-app.ps1')
            if ($commitChanges) {
                if (Test-Path -LiteralPath $AppDir) { Remove-Item -LiteralPath $AppDir -Recurse -Force }
                Move-Item -LiteralPath $newAppExtract -Destination $AppDir
                [System.IO.File]::WriteAllText($CommitFile, $newCommit, $Utf8NoBom)
            }
            foreach ($f in $changed) {
                if ($SelfFiles -contains $f.Path) { continue }
                $e = Copy-FileHardened (Join-Path $stage $f.Path) (Join-Path $InstallDir $f.Path)
                if ($e) { throw (New-Object System.Exception (Get-CopyFailMessage $f.Path $e)) }
                try { Unblock-File -LiteralPath (Join-Path $InstallDir $f.Path) } catch { }
            }
            $needPip = $commitChanges -or (@($changed | Where-Object { $_.Path -eq 'constraints.txt' }).Count -gt 0)
            if ($needPip) { Invoke-PipInstall }
            if (-not $SkipHealthCheck) {
                Say '  Checking that TradingAgents still starts...' 'Gray'
                $old = Get-Location
                Set-Location -LiteralPath $InstallDir
                try { $hc = Invoke-Python @((Join-Path $InstallDir 'run_analysis.py'), '--check') } finally { Set-Location -LiteralPath $old }
                foreach ($l in $hc.Output) { Write-Log ('    check: ' + $l) }
                if ($hc.Code -ne 0) { throw (New-Object System.Exception ('Start-up check failed: ' + (($hc.Output | Select-Object -Last 3) -join ' '))) }
            }
            foreach ($f in $changed) {
                if ($SelfFiles -contains $f.Path) {
                    $e = Copy-FileHardened (Join-Path $stage $f.Path) (Join-Path $InstallDir $f.Path)
                    if ($e) { throw (New-Object System.Exception (Get-CopyFailMessage $f.Path $e)) }
                    try { Unblock-File -LiteralPath (Join-Path $InstallDir $f.Path) } catch { }
                }
            }
            Save-Release $newVer $newCommit
        } catch {
            $why = $_.Exception.Message
            Say "  PROBLEM while applying the update: $why" 'Red'
            Say '  Putting your previous version back...' 'Yellow'
            try {
                Restore-Rollback $rbDir
                Stop-Update "The update failed and your previous version ($($installed.version)) was restored. Nothing of yours was lost.`n  Reason: $why`n  Send the update.log file to the person who set this up."
            } catch {
                if ($_.Exception.Message.StartsWith('UPDATE_STOP::')) { throw }
                Stop-Update ("The update failed AND the automatic restore failed: $($_.Exception.Message)`n  Your saved copy is in $rbDir . Send update.log to the person who set this up.")
            }
        }

        # keep the 3 newest rollback copies
        $all = @(Get-ChildItem -LiteralPath $RollbackRoot -Directory | Sort-Object Name -Descending)
        if ($all.Count -gt 3) { $all | Select-Object -Skip 3 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } }

        Write-Host ''
        Say '  ============================================================' 'Green'
        Say "   UPDATED to version $newVer. Your API key was not touched." 'Green'
        Say '   If anything looks wrong, double-click "Undo last update.bat"' 'Green'
        Say "   (in $InstallDir)" 'Green'
        Say '  ============================================================' 'Green'
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-Update
        exit 0
    } catch {
        $msg = $_.Exception.Message
        if ($msg.StartsWith('UPDATE_STOP::')) { $msg = $msg.Substring(13) } else { $msg = "Unexpected error: $msg (line $($_.InvocationInfo.ScriptLineNumber))" }
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Red
        Write-Host '   UPDATE DID NOT FINISH' -ForegroundColor Red
        Write-Host "   $msg" -ForegroundColor Red
        Write-Host "   Log: $LogFile" -ForegroundColor Red
        Write-Host '  ============================================================' -ForegroundColor Red
        Write-Log ('UPDATE FAILED: ' + $msg)
        exit 1
    }
}

# TradingAgents - results window (WPF, Windows PowerShell 5.1) for Davis Dental & Orthodontics.
# Started by the "TradingAgents" Desktop icon:
#     powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File ta-app.ps1
# It runs run_analysis.py (same folder) with the venv Python as a hidden child process, reads one JSON progress
# line per agent step from its output, and shows the answer in a window instead of a text file in Notepad.
# Screens: Analyze (ticker + live steps), Results (decision badge, key reasons, fold-out reports), Past reports.
# It makes no network calls itself. It reads .env only for the "AI settings" window, which (when you press Save) adds the
# DeepSeek key and DeepSeek model lines to .env and keeps every other line. Reports are written by run_analysis.py to the
# "reports" folder inside this folder (older reports on the Desktop are still listed). Research only - no trades are placed.
# Dot-sourcing this file (". .\ta-app.ps1") only loads the helper functions (used by the tests).
# Keep this file pure ASCII: Windows PowerShell 5.1 reads a BOM-less file as ANSI.

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$KitVersion = '1.4.3'   # shown in the window title bar; the update itself is versioned by release.json

# ======================= helpers (no UI; unit-testable) =======================

$MidDot = [string][char]0x00B7
$Bullet = [string][char]0x2022

# Rating scale of the Portfolio Manager. Fill/Fore = badge colours, Plain = small label under the big word (empty when it would only repeat the big word).
$RatingInfo = @{
    BUY         = @{ Label = 'BUY';         Plain = '';                 Fill = '#1E9E5A'; Fore = '#FFFFFF'
                     Meaning = 'Buy: the team thinks this looks like a good one to buy.' }
    OVERWEIGHT  = @{ Label = 'OVERWEIGHT';  Plain = 'Lean buy';         Fill = '#9AD16B'; Fore = '#1B3A12'
                     Meaning = 'Lean buy: the team thinks holding a bit more than usual makes sense.' }
    HOLD        = @{ Label = 'HOLD';        Plain = '';                 Fill = '#F2B233'; Fore = '#3D2A00'
                     Meaning = 'Hold: the team suggests keeping what you have, with no new buying or selling.' }
    UNDERWEIGHT = @{ Label = 'UNDERWEIGHT'; Plain = 'Lean sell';        Fill = '#F28C38'; Fore = '#3A1B00'
                     Meaning = 'Lean sell: the team thinks holding a bit less than usual makes sense.' }
    SELL        = @{ Label = 'SELL';        Plain = '';                 Fill = '#D9475B'; Fore = '#FFFFFF'
                     Meaning = 'Sell: the team thinks it is time to get out.' }
    REVIEW      = @{ Label = 'REVIEW';      Plain = 'Needs your review'; Fill = '#6F8085'; Fore = '#FFFFFF'
                     Meaning = 'No clear answer: the team did not settle on one rating. Please read their reasoning yourself.' }
}

function Resolve-Rating($Value) {
    $r = ([string]$Value).Trim().ToUpper()
    if ($RatingInfo.ContainsKey($r)) { return $r }
    return 'REVIEW'
}

function Get-RatingInfo($Value) { return $RatingInfo[(Resolve-Rating $Value)] }

# Steps shown while the team works, in the order the agents run. Id = stage name printed by run_analysis.py.
$StepDefs = @(
    @{ Id = 'market';           Label = 'Market analyst';      Hint = 'Price moves and trends' }
    @{ Id = 'sentiment';        Label = 'Sentiment analyst';   Hint = 'What people are saying online' }
    @{ Id = 'news';             Label = 'News analyst';        Hint = 'Recent headlines and events' }
    @{ Id = 'fundamentals';     Label = 'Company financials';  Hint = 'Earnings, sales and debts' }
    @{ Id = 'debate';           Label = 'Bull vs bear debate'; Hint = 'One side argues to buy, one to sell' }
    @{ Id = 'research_manager'; Label = 'Research manager';    Hint = 'Weighs up the debate' }
    @{ Id = 'trader';           Label = 'Trader';              Hint = 'Turns it into a plan' }
    @{ Id = 'risk';             Label = 'Risk team';           Hint = 'Checks what could go wrong' }
    @{ Id = 'portfolio';        Label = 'Portfolio manager';   Hint = 'Makes the final call' }
)

function Test-TickerSymbol([string]$Text) {
    # Same characters the TradingAgents CLI accepts: letters, digits and . _ - ^ =
    return ($Text -match '^[A-Z0-9._\-\^=]{1,32}$')
}

function Test-CryptoTicker([string]$Ticker) {
    return ($Ticker.ToUpper() -match '-(USD|USDT|USDC|BTC|ETH)$')
}

function Format-Elapsed([double]$Seconds) {
    $s = [int][Math]::Max(0, [Math]::Floor($Seconds))
    return ('{0}:{1:00}' -f [Math]::Floor($s / 60), ($s % 60))
}

function Format-Duration($Seconds) {
    $s = 0
    if (-not [int]::TryParse([string]$Seconds, [ref]$s) -or $s -le 0) { return '' }
    if ($s -lt 60) { return "$s sec" }
    return ('{0} min {1} sec' -f [Math]::Floor($s / 60), ($s % 60))
}

function Format-When([string]$Date, [string]$Time) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Date, 'yyyy-MM-dd', $inv, 'None', [ref]$d)) { return (("$Date $Time").Trim()) }
    $text = $d.ToString('ddd d MMM yyyy', $inv)
    $t = [datetime]::MinValue
    if ($Time -and [datetime]::TryParseExact($Time, 'HH:mm', $inv, 'None', [ref]$t)) { $text += ' at ' + $t.ToString('h:mm tt', $inv) }
    return $text
}

# ---- markdown -> plain readable text -------------------------------------------------------------

function Remove-MdInline([string]$Text) {
    if ($null -eq $Text) { return '' }
    $s = [regex]::Replace($Text, '!?\[([^\]]*)\]\([^)]*\)', '$1')
    $s = [regex]::Replace($s, '<[^>]+>', '')
    $s = [regex]::Replace($s, '\*\*\*(.+?)\*\*\*', '$1')
    $s = [regex]::Replace($s, '\*\*(.+?)\*\*', '$1')
    $s = [regex]::Replace($s, '__(.+?)__', '$1')
    $s = [regex]::Replace($s, '(?<![\w*])\*(?!\s)([^*]+?)(?<!\s)\*(?![\w*])', '$1')
    $s = [regex]::Replace($s, '(?<!\w)_(?!\s)([^_]+?)(?<!\s)_(?!\w)', '$1')
    $s = $s.Replace('`', '').Replace('~~', '').Replace('**', '')
    $s = $s.Replace('&nbsp;', ' ').Replace('&amp;', '&')
    return $s.Trim()
}

# Returns blocks: @{ Kind = 'h' | 'b' | 'p'; Text; Marker (bullets); Level (bullets, 0-2) }.
# Headings and bullets stay readable; every markdown symbol (#, **, `, |, ---, links) is dropped.
function Convert-MdToBlocks([string]$Text) {
    $out = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $inFence = $false
    foreach ($raw in ($Text -split "\r?\n")) {
        $line = $raw.TrimEnd()
        if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if ($line.Trim() -eq '') { continue }
        if (-not $inFence) {
            if ($line -match '^\s*([-*_]\s*){3,}$') { continue }
            if (($line -match '^\s*\|[\s:\-|]+\|?\s*$') -and ($line -match '-')) { continue }
            if ($line -match '^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$') {
                $t = Remove-MdInline $Matches[1]
                if ($t) { $out.Add(@{ Kind = 'h'; Text = $t }) }
                continue
            }
            if ($line -match '^\s*\|(.+)\|\s*$') {
                $cells = @($Matches[1].Split('|') | ForEach-Object { Remove-MdInline $_ } | Where-Object { $_ -ne '' })
                if ($cells.Count -gt 0) { $out.Add(@{ Kind = 'p'; Text = ($cells -join "  $MidDot  ") }) }
                continue
            }
            if ($line -match '^(\s*)([-*+]|\u2022|\d{1,2}[.)])\s+(.*)$') {
                $indent = $Matches[1].Length
                $mk = [string]$Matches[2]
                $t = Remove-MdInline $Matches[3]
                $marker = $Bullet
                if ($mk -match '^\d') { $marker = $mk }
                $level = [Math]::Min(2, [int][Math]::Floor($indent / 2))
                if ($t) { $out.Add(@{ Kind = 'b'; Text = $t; Marker = $marker; Level = $level }) }
                continue
            }
            if ($line -match '^\s*(\*\*|__)([^*_]{2,80}?)(\*\*|__):?\s*$') {
                $out.Add(@{ Kind = 'h'; Text = (Remove-MdInline $Matches[2]) })
                continue
            }
        }
        $t = Remove-MdInline $line
        if ($t) { $out.Add(@{ Kind = 'p'; Text = $t }) }
    }
    return $out.ToArray()
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $cut = $Text.Substring(0, $Max)
    $sp = $cut.LastIndexOf(' ')
    if ($sp -gt ($Max * 0.6)) { $cut = $cut.Substring(0, $sp) }
    return ($cut.TrimEnd(' ', ',', ';', ':') + '...')
}

function Split-Sentences([string]$Text) {
    return @([regex]::Split($Text, '(?<=[a-z0-9%\)"][.!?])\s+(?=[A-Z"(])') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

# 3-5 plain sentences explaining the call, taken from the Portfolio Manager text (no AI call):
# bullets first; otherwise the most informative sentences (numbers and reason words score higher).
function Get-KeyReasons([string]$Text, [int]$Max = 5) {
    $blocks = @(Convert-MdToBlocks $Text)
    $skip = '^(rating|recommendation|final decision|final rating|decision|price target|target price|time horizon|horizon|position size|stop[- ]?loss|entry|confidence)\b[^:]{0,20}:'
    $label = '^(executive summary|investment thesis|thesis|summary|rationale|reasoning|key reasons|why|analysis|conclusion)\s*:\s*'
    $bul = New-Object System.Collections.Generic.List[string]
    $sent = New-Object System.Collections.Generic.List[object]
    $idx = 0
    foreach ($b in $blocks) {
        if ($b.Kind -eq 'h') { continue }
        $t = [regex]::Replace([string]$b.Text, $label, '', 'IgnoreCase')
        if ($b.Text -match $skip) { continue }
        if ($t.Length -lt 25) { continue }
        if ($b.Kind -eq 'b') { [void]$bul.Add((Limit-Text $t 260)); continue }
        foreach ($s in (Split-Sentences $t)) {
            if ($s.Length -lt 35) { continue }
            $score = 0
            if ($s -match '[\d%$]') { $score += 2 }
            if ($s -match '(?i)because|due to|driven|growth|earnings|revenue|valuation|risk|momentum|trend|support|resistance|upside|downside|margin|demand|guidance|volatil|inflation|rate|cash|debt') { $score += 2 }
            if ($idx -lt 6) { $score += 1 }
            $sent.Add(@{ Idx = $idx; Text = (Limit-Text $s 240); Score = $score })
            $idx++
        }
    }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($t in $bul) { if ($result.Count -lt $Max) { $result.Add($t) } }
    $need = $Max - $result.Count
    if ($bul.Count -lt 3 -and $need -gt 0 -and $sent.Count -gt 0) {
        $top = @($sent | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Idx } } | Select-Object -First $need | Sort-Object { $_.Idx })
        foreach ($s in $top) {
            $dup = $false
            foreach ($r in $result) { if ($r.Contains($s.Text.Substring(0, [Math]::Min(40, $s.Text.Length)))) { $dup = $true } }
            if (-not $dup) { $result.Add($s.Text) }
        }
    }
    return $result.ToArray()
}

# ---- plain-English pass (deterministic text replacement, no AI call) -------------------------------
# Makes trader jargon readable for someone who is not a trader. Word-boundary aware, case-insensitive,
# safe to run twice. $State (from New-PlainState) remembers that "RSI" was already explained, so the
# first use reads "momentum score (RSI)" and later uses read "momentum score".
function New-PlainState { return @{ Rsi = $false } }

function Test-AtSentenceStart([string]$S, [int]$Index) {
    if ($Index -le 0) { return $true }
    $before = $S.Substring(0, $Index).TrimEnd('*', '_', '"', "'", '(')
    if ($before.Length -eq 0) { return $true }
    return [bool]($before -match '([.!?]\s+|\n\s*)$' -or $before -match '^\s*$')
}

function Convert-Phrase([string]$S, [string]$Pattern, [scriptblock]$Make) {
    $ev = [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $r = [string](& $Make $m)
        if ($r.Length -gt 0 -and [char]::IsUpper($m.Value[0]) -and (Test-AtSentenceStart $S $m.Index)) {
            $r = $r.Substring(0, 1).ToUpper() + $r.Substring(1)
        }
        $r
    }
    return [regex]::Replace($S, $Pattern, $ev, 'IgnoreCase')
}

function Convert-ToPlainEnglish([string]$Text, $State = $null) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($null -eq $State) { $State = New-PlainState }
    $t = $Text
    $t = Convert-Phrase $t '\b(\d+)-day\s+(?:SMA|EMA)s?\b' { param($m) $m.Groups[1].Value + '-day average price' }
    $t = Convert-Phrase $t '\b(?:SMA|EMA)s?\b' { param($m) 'average price' }
    $t = Convert-Phrase $t '(?<![\w/])P/E\b(?:\s+ratio)?' { param($m) 'price-to-earnings ratio' }
    $t = Convert-Phrase $t '(?<!\()\bRSI\b(?:\s*\(\d+\))?' { param($m)
        if ($State.Rsi) { 'momentum score' } else { $State.Rsi = $true; 'momentum score (RSI)' } }
    $t = Convert-Phrase $t '\bMACD\b' { param($m) 'trend-momentum signal' }
    $t = Convert-Phrase $t '\b(an)\s+(?=over(bought|sold)\b)' { param($m) $(if ($m.Groups[1].Value -ceq 'An') { 'A ' } else { 'a ' }) }
    $t = Convert-Phrase $t '\boverbought\b' { param($m) 'stretched up' }
    $t = Convert-Phrase $t '\boversold\b' { param($m) 'stretched down' }
    $t = Convert-Phrase $t '\bbps\b' { param($m) 'basis points (hundredths of a percent)' }
    return $t
}

# Key reasons exactly as shown on the Results screen: plain English, "RSI" explained once across the list.
function Get-DisplayReasons([string]$Text, [int]$Max = 5) {
    $ps = New-PlainState
    return @(Get-KeyReasons $Text $Max | ForEach-Object { Convert-ToPlainEnglish $_ $ps })
}

# ---- AI settings: DeepSeek (pure functions, unit-tested; no UI) ------------------------------------
# DeepSeek retired the names deepseek-chat / deepseek-reasoner on 2026-07-24 (api-docs.deepseek.com/updates).
# Current names: deepseek-v4-pro for the deep-thinking roles, deepseek-flash for the quick analyst roles.
$DeepSeekModels = [ordered]@{
    TRADINGAGENTS_LLM_PROVIDER     = 'deepseek'
    TRADINGAGENTS_DEEP_THINK_LLM   = 'deepseek-v4-pro'
    TRADINGAGENTS_QUICK_THINK_LLM  = 'deepseek-flash'
    TRADINGAGENTS_LLM_BACKEND_URL  = 'https://api.deepseek.com'
}

function Test-DeepSeekKey([string]$Key) {
    return ([string]$Key -match '^sk-[A-Za-z0-9_\-]{16,200}$')
}

# Returns the lines with each name in $Values set: the first existing "NAME=" line is replaced in place,
# later duplicates of it are dropped, missing names are appended. Every other line is kept exactly as it was.
function Set-EnvLines([string[]]$Lines, $Values) {
    $out = New-Object System.Collections.Generic.List[string]
    $done = @{}
    foreach ($line in @($Lines)) {
        $hit = $null
        foreach ($name in $Values.Keys) {
            if ($line -match ('^\s*(?:export\s+)?' + [regex]::Escape([string]$name) + '\s*=')) { $hit = [string]$name; break }
        }
        if ($null -eq $hit) { $out.Add($line); continue }
        if ($done.ContainsKey($hit)) { continue }
        $out.Add($hit + '=' + [string]$Values[$hit])
        $done[$hit] = $true
    }
    foreach ($name in $Values.Keys) {
        if (-not $done.ContainsKey([string]$name)) { $out.Add([string]$name + '=' + [string]$Values[$name]) }
    }
    return @($out.ToArray())
}

function Get-EnvValue([string[]]$Lines, [string]$Name) {
    $v = ''
    foreach ($line in @($Lines)) {
        $m = [regex]::Match($line, '^\s*(?:export\s+)?' + [regex]::Escape($Name) + '\s*=\s*(.*?)\s*$')
        if ($m.Success) { $v = $m.Groups[1].Value.Trim([char[]]@([char]34, [char]39)) }
    }
    return $v
}

# Switches .env to DeepSeek. $Key may be '' only when .env already holds a DEEPSEEK_API_KEY.
# The first time, the old .env is kept as ".env.before-deepseek" (same folder) so it can be restored by hand.
# The key is never written anywhere else and never returned or logged.
function Save-DeepSeekSettings([string]$EnvPath, [string]$Key) {
    if (-not (Test-Path -LiteralPath $EnvPath)) { throw 'The settings file (.env) was not found. Run TradingAgents-Setup first.' }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $lines = [System.IO.File]::ReadAllLines($EnvPath, $utf8)
    $vals = [ordered]@{}
    foreach ($k in $DeepSeekModels.Keys) { $vals[$k] = $DeepSeekModels[$k] }
    if ($Key) {
        if (-not (Test-DeepSeekKey $Key)) { throw 'That does not look like a DeepSeek key. It starts with sk- and has no spaces.' }
        $vals['DEEPSEEK_API_KEY'] = $Key
    } elseif (-not (Get-EnvValue $lines 'DEEPSEEK_API_KEY')) {
        throw 'Please paste your DeepSeek key.'
    }
    $new = Set-EnvLines $lines $vals
    $backup = $EnvPath + '.before-deepseek'
    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $EnvPath -Destination $backup -Force }
    $tmp = $EnvPath + '.tmp'
    [System.IO.File]::WriteAllLines($tmp, [string[]]$new, $utf8)
    Move-Item -LiteralPath $tmp -Destination $EnvPath -Force
}

# ---- reports on disk -----------------------------------------------------------------------------

$RatingRegex = 'FINAL DECISION(?:\s+for\s+\S+\s+on\s+[^\s:]+)?\s*:\s*\**\s*(BUY|OVERWEIGHT|HOLD|UNDERWEIGHT|SELL|REVIEW)\b'

# Rating from the "FINAL DECISION ..." line of a .txt report. Returns 'REVIEW' when there is none.
function Get-RatingFromText([string]$Text) {
    $m = [regex]::Match([string]$Text, $RatingRegex, 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    return 'REVIEW'
}

function Get-StampFromName([string]$Name) {
    # SPY_2026-09-29_1415.txt -> @{ Ticker; Date; Time }
    $m = [regex]::Match($Name, '^(.+)_(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})\.[A-Za-z]+$')
    if ($m.Success) { return @{ Ticker = $m.Groups[1].Value; Date = $m.Groups[2].Value; Time = ($m.Groups[3].Value + ':' + $m.Groups[4].Value) } }
    return $null
}

function Get-ItemStamp([string]$Date, [string]$Time, [datetime]$Fallback) {
    $d = [datetime]::MinValue
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ([datetime]::TryParseExact(("$Date $Time").Trim(), 'yyyy-MM-dd HH:mm', $inv, 'None', [ref]$d)) { return $d }
    if ([datetime]::TryParseExact($Date, 'yyyy-MM-dd', $inv, 'None', [ref]$d)) { return $d }
    return $Fallback
}

function Read-Utf8([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding $false))
}

function Get-JsonProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return '' }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    # PowerShell 7 turns "2026-09-29" into a DateTime while parsing JSON; Windows PowerShell 5.1 keeps the text.
    if ($p.Value -is [datetime]) { return $p.Value.ToString('yyyy-MM-dd') }
    return [string]$p.Value
}

# Report from a .json written by run_analysis.py (schema 1), or $null if the file is not one.
function Read-ReportJson([string]$Path) {
    try {
        $j = (Read-Utf8 $Path) | ConvertFrom-Json
    } catch { return $null }
    if ($null -eq $j -or [string](Get-JsonProp $j 'ticker') -eq '' -or [string](Get-JsonProp $j 'rating') -eq '') { return $null }
    $sec = @{}
    if ($j.PSObject.Properties['sections'] -and $j.sections) {
        foreach ($p in $j.sections.PSObject.Properties) { $sec[$p.Name] = [string]$p.Value }
    }
    $deep = ''; $quick = ''
    if ($j.PSObject.Properties['models'] -and $j.models) { $deep = Get-JsonProp $j.models 'deep'; $quick = Get-JsonProp $j.models 'quick' }
    $txt = [System.IO.Path]::ChangeExtension($Path, '.txt')
    $named = Get-JsonProp $j 'txt_report'
    if ($named) {
        $cand = Join-Path ([System.IO.Path]::GetDirectoryName($Path)) ([System.IO.Path]::GetFileName($named))
        if (Test-Path -LiteralPath $cand) { $txt = $cand }
    }
    $item = Get-Item -LiteralPath $Path
    $date = Get-JsonProp $j 'date'; $time = Get-JsonProp $j 'time'
    return @{
        Ticker   = (Get-JsonProp $j 'ticker'); Date = $date; Time = $time
        Rating   = (Resolve-Rating (Get-JsonProp $j 'rating'))
        Provider = (Get-JsonProp $j 'provider_name'); Deep = $deep; Quick = $quick
        PM       = (Get-JsonProp $j 'portfolio_manager'); Sections = $sec
        Seconds  = (Get-JsonProp $j 'duration_seconds'); Crypto = ((Get-JsonProp $j 'is_crypto') -eq 'True')
        TxtPath  = $txt; Path = $Path; Legacy = $false
        Stamp    = (Get-ItemStamp $date $time $item.LastWriteTime)
    }
}

# Report from an older .txt-only file: rating from the FINAL DECISION line, reasoning from the
# "PORTFOLIO MANAGER" part. The analyst sections are not split out for these (Sections is empty).
function Read-ReportTxt([string]$Path) {
    try { $text = Read-Utf8 $Path } catch { return $null }
    $item = Get-Item -LiteralPath $Path
    $stamp = Get-StampFromName $item.Name
    $ticker = ''; $date = ''; $time = ''
    if ($stamp) { $ticker = $stamp.Ticker; $date = $stamp.Date; $time = $stamp.Time }
    $head = [regex]::Match($text, '(?m)^TradingAgents report:\s*(\S+)\s+date:\s*(\d{4}-\d{2}-\d{2})')
    if ($head.Success) { if (-not $ticker) { $ticker = $head.Groups[1].Value }; if (-not $date) { $date = $head.Groups[2].Value } }
    if (-not $ticker) { $ticker = [System.IO.Path]::GetFileNameWithoutExtension($item.Name) }
    $provider = ''; $deep = ''; $quick = ''
    $pm = [regex]::Match($text, '(?m)^AI provider:\s*(.+?)\s+-\s+models:\s*(.+?)\s*/\s*(.+?)\s*$')
    if ($pm.Success) { $provider = $pm.Groups[1].Value; $deep = $pm.Groups[2].Value; $quick = $pm.Groups[3].Value }
    $reason = ''
    $lines = $text -split "\r?\n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^PORTFOLIO MANAGER\b') { $start = $i; break } }
    if ($start -ge 0) {
        $buf = New-Object System.Collections.Generic.List[string]
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^={20,}\s*$') { break }
            if ($i -eq $start + 1 -and $lines[$i] -match '^-{10,}\s*$') { continue }
            $buf.Add($lines[$i])
        }
        $reason = ($buf -join "`n").Trim()
    }
    return @{
        Ticker   = $ticker; Date = $date; Time = $time
        Rating   = (Get-RatingFromText $text)
        Provider = $provider; Deep = $deep; Quick = $quick
        PM       = $reason; Sections = @{}; Seconds = ''; Crypto = $false
        TxtPath  = $Path; Path = $Path; Legacy = $true
        Stamp    = (Get-ItemStamp $date $time $item.LastWriteTime)
    }
}

# Rating + ticker + date from the top of a .txt report only (cheap, for the history list).
function Read-ReportTxtHead([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    try {
        $head = (@(Get-Content -LiteralPath $Path -TotalCount 14 -Encoding UTF8 -ErrorAction Stop)) -join "`n"
    } catch { return $null }
    $stamp = Get-StampFromName $item.Name
    $ticker = ''; $date = ''; $time = ''
    if ($stamp) { $ticker = $stamp.Ticker; $date = $stamp.Date; $time = $stamp.Time }
    $m = [regex]::Match($head, '(?m)^TradingAgents report:\s*(\S+)\s+date:\s*(\d{4}-\d{2}-\d{2})')
    if ($m.Success) { if (-not $ticker) { $ticker = $m.Groups[1].Value }; if (-not $date) { $date = $m.Groups[2].Value } }
    if (-not $ticker) { $ticker = [System.IO.Path]::GetFileNameWithoutExtension($item.Name) }
    return @{ Ticker = $ticker; Date = $date; Time = $time; Rating = (Get-RatingFromText $head); Path = $Path
             Stamp = (Get-ItemStamp $date $time $item.LastWriteTime) }
}

function Read-ReportFile([string]$Path) {
    # Never throws: a missing, locked or blocked file (security software, odd permissions) gives $null.
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
        if ([System.IO.Path]::GetExtension($Path).ToLower() -eq '.json') { return (Read-ReportJson $Path) }
        return (Read-ReportTxt $Path)
    } catch { return $null }
}

# Newest first. A .json wins over the .txt with the same name; .txt files without one are old reports.
function Get-ReportHistory([string]$Dir, [int]$Max = 200) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.json' -or $_.Extension -eq '.txt' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First ($Max * 2))
    $list = New-Object System.Collections.Generic.List[object]
    $haveJson = @{}
    foreach ($f in ($files | Where-Object { $_.Extension -eq '.json' })) {
        $r = $null
        try { $r = Read-ReportJson $f.FullName } catch { }
        if ($null -eq $r) { continue }
        $haveJson[$f.BaseName] = $true
        $list.Add(@{ Ticker = $r.Ticker; Date = $r.Date; Time = $r.Time; Rating = $r.Rating; Path = $f.FullName; Stamp = $r.Stamp })
    }
    foreach ($f in ($files | Where-Object { $_.Extension -eq '.txt' })) {
        if ($haveJson.ContainsKey($f.BaseName)) { continue }
        $r = $null
        try { $r = Read-ReportTxtHead $f.FullName } catch { }
        if ($null -ne $r) { $list.Add($r) }
    }
    return @($list.ToArray() | Sort-Object @{ Expression = { $_.Stamp }; Descending = $true } | Select-Object -First $Max)
}

# Past reports from several folders (the app's reports folder first, then older Desktop reports), newest first.
function Get-ReportHistoryMulti([string[]]$Dirs, [int]$Max = 200) {
    $all = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($d in @($Dirs)) {
        if (-not $d -or $seen.ContainsKey($d.ToLower())) { continue }
        $seen[$d.ToLower()] = $true
        foreach ($it in @(Get-ReportHistory $d $Max)) { $all.Add($it) }
    }
    return @($all.ToArray() | Sort-Object @{ Expression = { $_.Stamp }; Descending = $true } | Select-Object -First $Max)
}

# Fold-out cards for the Results screen: @{ Title; Sub; Parts = @(@{ Head; Text }) }. Empty sections are left out.
function Get-ReportCards($Report) {
    $s = $Report.Sections
    function Sec([string]$k) { if ($s -and $s.ContainsKey($k)) { return ([string]$s[$k]).Trim() }; return '' }
    function NoPrefix([string]$t) { return ([regex]::Replace($t, '(?im)^\s*(Bull|Bear|Aggressive|Conservative|Neutral)( Analyst)?\s*:\s*', '')) }
    $cards = New-Object System.Collections.Generic.List[object]
    $one = @(
        @('market', 'Market analyst', 'Price moves and trends'),
        @('news', 'News analyst', 'Recent headlines and world events'),
        @('sentiment', 'Sentiment analyst', 'What people are saying online'),
        @('fundamentals', 'Company financials analyst', 'Earnings, sales, debts and value'))
    foreach ($o in $one) {
        $t = Sec $o[0]
        if ($t) { $cards.Add(@{ Title = $o[1]; Sub = $o[2]; Parts = @(@{ Head = ''; Text = $t }) }) }
    }
    $parts = New-Object System.Collections.Generic.List[object]
    $bull = NoPrefix (Sec 'bull'); $bear = NoPrefix (Sec 'bear')
    if ($bull) { $parts.Add(@{ Head = 'The case for buying (bull)'; Text = $bull }) }
    if ($bear) { $parts.Add(@{ Head = 'The case against (bear)'; Text = $bear }) }
    if (-not $bull -and -not $bear) {
        $h = NoPrefix (Sec 'debate_history')
        if ($h) { $parts.Add(@{ Head = ''; Text = $h }) }
    }
    $v = Sec 'debate_verdict'
    if ($v) { $parts.Add(@{ Head = 'How the research manager judged it'; Text = $v }) }
    if ($parts.Count -gt 0) { $cards.Add(@{ Title = 'Bull vs bear debate'; Sub = 'One side argues for buying, the other against'; Parts = $parts.ToArray() }) }
    $t = Sec 'research_manager'
    if ($t) { $cards.Add(@{ Title = "Research manager's plan"; Sub = 'What the team took from the debate'; Parts = @(@{ Head = ''; Text = $t }) }) }
    $t = Sec 'trader'
    if ($t) { $cards.Add(@{ Title = "Trader's plan"; Sub = 'How the team would act on it'; Parts = @(@{ Head = ''; Text = $t }) }) }
    $parts = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(@('risk_aggressive', 'Bold view (accepts more risk)'), @('risk_conservative', 'Careful view (avoids risk)'),
                     @('risk_neutral', 'Balanced view'), @('risk_verdict', "Risk team's verdict"))) {
        $t = NoPrefix (Sec $r[0])
        if ($t) { $parts.Add(@{ Head = $r[1]; Text = $t }) }
    }
    if ($parts.Count -eq 0) { $h = NoPrefix (Sec 'risk_history'); if ($h) { $parts.Add(@{ Head = ''; Text = $h }) } }
    if ($parts.Count -gt 0) { $cards.Add(@{ Title = 'Risk team'; Sub = 'Three views on how risky this is'; Parts = $parts.ToArray() }) }
    if ($Report.PM) { $cards.Add(@{ Title = "Portfolio manager's full reasoning"; Sub = 'The final call, in full'; Parts = @(@{ Head = ''; Text = [string]$Report.PM }) }) }
    return $cards.ToArray()
}

# ---- running run_analysis.py ---------------------------------------------------------------------

# Pure bookkeeping for the step list. $Run = New-RunState; feed it every JSON event from the child process.
function New-RunState {
    return @{ MaxIdx = -1; Starts = @{}; Durations = @{}; Done = $false; Error = ''; Result = $null; Crypto = $false; Provider = ''; Models = '' }
}

function Get-StepIndex([string]$Stage) {
    for ($i = 0; $i -lt $StepDefs.Count; $i++) { if ($StepDefs[$i].Id -eq $Stage) { return $i } }
    return -1
}

function Update-RunState($Run, $Evt, [datetime]$Now) {
    $kind = [string](Get-JsonProp $Evt 'event')
    switch ($kind) {
        'start' {
            $Run.Crypto = ((Get-JsonProp $Evt 'crypto') -eq 'True')
            $Run.Provider = Get-JsonProp $Evt 'provider_name'
        }
        'step' {
            $idx = Get-StepIndex (Get-JsonProp $Evt 'stage')
            if ($idx -lt 0 -or $idx -le $Run.MaxIdx) { return }
            if ($Run.MaxIdx -ge 0 -and $Run.Starts.ContainsKey($Run.MaxIdx)) {
                $Run.Durations[$Run.MaxIdx] = ($Now - $Run.Starts[$Run.MaxIdx]).TotalSeconds
            }
            $Run.MaxIdx = $idx
            $Run.Starts[$idx] = $Now
        }
        'done' {
            if ($Run.MaxIdx -ge 0 -and $Run.Starts.ContainsKey($Run.MaxIdx) -and -not $Run.Durations.ContainsKey($Run.MaxIdx)) {
                $Run.Durations[$Run.MaxIdx] = ($Now - $Run.Starts[$Run.MaxIdx]).TotalSeconds
            }
            $Run.Done = $true
            $Run.Result = $Evt
        }
        'error' { $Run.Error = Get-JsonProp $Evt 'message' }
    }
}

# 'done' | 'active' | 'pending' for step $Index.
function Get-StepState($Run, [int]$Index) {
    if ($Run.Done) { return 'done' }
    if ($Index -lt $Run.MaxIdx) { return 'done' }
    if ($Index -eq $Run.MaxIdx) { return 'active' }
    return 'pending'
}

function Start-AnalysisProcess([string]$Python, [string]$Script, [string]$Ticker, [string]$ReportsDir, [string]$WorkDir) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Python
    $psi.Arguments = ('"{0}" --ticker {1} --reports-dir "{2}" --no-notepad --json-progress' -f $Script, $Ticker, $ReportsDir)
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
    $psi.EnvironmentVariables['PYTHONUNBUFFERED'] = '1'
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $p = [System.Diagnostics.Process]::Start($psi)
    try { $p.StandardInput.Close() } catch { }
    return @{ Proc = $p; OutTask = $p.StandardOutput.ReadLineAsync(); ErrTask = $p.StandardError.ReadLineAsync()
              Err = (New-Object System.Text.StringBuilder) }
}

# Non-blocking: collects every output line that has arrived since the last call (called from a UI timer, so the
# window never waits on the child). Returns the JSON events; stderr text is kept in $Pump.Err.
function Read-AnalysisPump($Pump) {
    $events = New-Object System.Collections.Generic.List[object]
    while ($null -ne $Pump.OutTask -and $Pump.OutTask.IsCompleted) {
        $line = $null
        try { $line = $Pump.OutTask.Result } catch { $Pump.OutTask = $null; break }
        if ($null -eq $line) { $Pump.OutTask = $null; break }
        try { $Pump.OutTask = $Pump.Proc.StandardOutput.ReadLineAsync() } catch { $Pump.OutTask = $null }
        $t = $line.Trim()
        if ($t.StartsWith('{')) { try { $events.Add(($t | ConvertFrom-Json)) } catch { } }
    }
    while ($null -ne $Pump.ErrTask -and $Pump.ErrTask.IsCompleted) {
        $line = $null
        try { $line = $Pump.ErrTask.Result } catch { $Pump.ErrTask = $null; break }
        if ($null -eq $line) { $Pump.ErrTask = $null; break }
        try { $Pump.ErrTask = $Pump.Proc.StandardError.ReadLineAsync() } catch { $Pump.ErrTask = $null }
        if ($Pump.Err.Length -lt 6000) { [void]$Pump.Err.AppendLine($line) }
    }
    return $events.ToArray()
}

function Test-PumpFinished($Pump) {
    return ($null -eq $Pump.OutTask -and $Pump.Proc.HasExited)
}

function Stop-AnalysisProcess($Pump) {
    if ($null -eq $Pump -or $null -eq $Pump.Proc) { return }
    try {
        if (-not $Pump.Proc.HasExited) {
            if ($env:OS -eq 'Windows_NT') {
                Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$Pump.Proc.Id, '/T', '/F') -WindowStyle Hidden -Wait
            }
            if (-not $Pump.Proc.HasExited) { $Pump.Proc.Kill() }
        }
    } catch { }
}

# ======================= the window =======================

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Davis Dental &amp; Orthodontics - TradingAgents" Width="1120" Height="700"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" FontFamily="Segoe UI" FontStyle="Normal" FontStretch="Normal"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <!-- Davis Dental palette: mint #E8F7F4 / #BFEDE4, teal #2BB5A0 / #1B8C7C, slate text #1F3A40 -->
    <Color x:Key="Aqua">#2BB5A0</Color>
    <SolidColorBrush x:Key="AquaBrush" Color="#2BB5A0"/>
    <SolidColorBrush x:Key="TealBrush" Color="#1B8C7C"/>
    <SolidColorBrush x:Key="MintBrush" Color="#E8F7F4"/>
    <SolidColorBrush x:Key="MintEdgeBrush" Color="#BFEDE4"/>
    <SolidColorBrush x:Key="TextBrush" Color="#1F3A40"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#4F6E74"/>
    <SolidColorBrush x:Key="CardBrush" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="CardEdgeBrush" Color="#D3EFE9"/>
    <SolidColorBrush x:Key="RoseBrush" Color="#D9475B"/>
    <LinearGradientBrush x:Key="AquaGradient" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#1E9886" Offset="0"/>
      <GradientStop Color="#177A6C" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="ProgressGradient" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#2BB5A0" Offset="0"/>
      <GradientStop Color="#1B8C7C" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="MarkTileGradient" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#E8F7F4" Offset="0"/>
      <GradientStop Color="#BFEDE4" Offset="1"/>
    </LinearGradientBrush>
    <!-- the tooth mark, same outline as TradingAgents.ico (100x100 design space) -->
    <Geometry x:Key="ToothGeometry">M50.0,27.0 C46.7,27.0 43.8,18.7 40.0,17.0 C36.2,15.3 30.5,15.0 27.0,17.0 C23.5,19.0 20.0,24.3 19.0,29.0 C18.0,33.7 19.5,40.0 21.0,45.0 C22.5,50.0 26.5,53.3 28.0,59.0 C29.5,64.7 28.7,74.2 30.0,79.0 C31.3,83.8 34.0,88.0 36.0,88.0 C38.0,88.0 40.3,82.8 42.0,79.0 C43.7,75.2 44.7,68.0 46.0,65.0 C47.3,62.0 48.7,61.0 50.0,61.0 C51.3,61.0 52.7,62.0 54.0,65.0 C55.3,68.0 56.3,75.2 58.0,79.0 C59.7,82.8 62.0,88.0 64.0,88.0 C66.0,88.0 68.7,83.8 70.0,79.0 C71.3,74.2 70.5,64.7 72.0,59.0 C73.5,53.3 77.5,50.0 79.0,45.0 C80.5,40.0 82.0,33.7 81.0,29.0 C80.0,24.3 76.5,19.0 73.0,17.0 C69.5,15.0 63.8,15.3 60.0,17.0 C56.2,18.7 53.3,27.0 50.0,27.0 Z</Geometry>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="34,14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="16" Background="{StaticResource AquaGradient}" Padding="{TemplateBinding Padding}">
              <Border.Effect><DropShadowEffect Color="#1B8C7C" BlurRadius="18" ShadowDepth="4" Direction="270" Opacity="0.28"/></Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.9"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.78"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.35"/>
                <Setter TargetName="bd" Property="Effect" Value="{x:Null}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Foreground" Value="#1F3A40"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="20,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="14" Background="#FFFFFF" BorderBrush="#BFEDE4" BorderThickness="1.5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E8F7F4"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#2BB5A0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="LinkButton" TargetType="Button">
      <Setter Property="Foreground" Value="#17766A"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <ContentPresenter x:Name="cp" TextElement.Foreground="{TemplateBinding Foreground}"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="cp" Property="TextElement.Foreground" Value="#0E5148"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GlassInput" TargetType="TextBox">
      <Setter Property="Foreground" Value="#1F3A40"/>
      <Setter Property="CaretBrush" Value="#1B8C7C"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" CornerRadius="12" Background="#F6FCFA" BorderBrush="#BFEDE4" BorderThickness="1.5" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#2BB5A0"/>
                <Setter TargetName="bd" Property="Background" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinButton" TargetType="Button">
      <Setter Property="Foreground" Value="#4F6E74"/>
      <Setter Property="Width" Value="38"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="8" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#E3F5F1"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="CornerRadius" Value="20"/>
      <Setter Property="Background" Value="{StaticResource CardBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardEdgeBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="24"/>
      <Setter Property="Effect">
        <Setter.Value><DropShadowEffect Color="#1B8C7C" BlurRadius="20" ShadowDepth="4" Direction="270" Opacity="0.10"/></Setter.Value>
      </Setter>
    </Style>
    <!-- Always upright: pins FontStyle for every TextBlock, including the ones buttons and list items create. -->
    <Style TargetType="TextBlock"><Setter Property="FontStyle" Value="Normal"/></Style>
    <!-- Fold-out card: header row with a chevron, body appears when opened. -->
    <Style x:Key="FoldCard" TargetType="Expander">
      <Setter Property="Margin" Value="0,0,8,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <Border x:Name="bd" CornerRadius="16" Background="#FFFFFF" BorderBrush="#D3EFE9" BorderThickness="1">
              <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <ToggleButton Grid.Row="0" Cursor="Hand" Focusable="False" IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                  <ToggleButton.Template>
                    <ControlTemplate TargetType="ToggleButton">
                      <Border x:Name="hb" Background="Transparent" CornerRadius="16" Padding="18,12">
                        <ContentPresenter/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="hb" Property="Background" Value="#F1FBF8"/></Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </ToggleButton.Template>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
                    <Path x:Name="arrow" Grid.Column="1" Data="M1,1 L8,8 L15,1" Stroke="#1B8C7C" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Width="16" Height="10" Stretch="Fill" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5"/>
                  </Grid>
                </ToggleButton>
                <ContentPresenter x:Name="body" Grid.Row="1" Visibility="Collapsed" Margin="18,0,18,16"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True">
                <Setter TargetName="body" Property="Visibility" Value="Visible"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#2BB5A0"/>
                <Setter TargetName="arrow" Property="RenderTransform">
                  <Setter.Value><RotateTransform Angle="180"/></Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Slim mint scroll bar for the content lists. -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#BFEDE4" Margin="3,0"/></ControlTemplate></Thumb.Template></Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavButton" TargetType="Button" BasedOn="{StaticResource GhostButton}">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="20">
    <Border CornerRadius="26" BorderThickness="1" BorderBrush="#BFEDE4">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#FFFFFF" Offset="0"/>
          <GradientStop Color="#F4FBF9" Offset="0.6"/>
          <GradientStop Color="#E8F7F4" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <Border.Effect><DropShadowEffect Color="#1B8C7C" BlurRadius="30" ShadowDepth="4" Direction="270" Opacity="0.28"/></Border.Effect>

      <Grid>
        <!-- soft mint / aqua washes -->
        <Ellipse Width="420" Height="420" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,30,30,0" IsHitTestVisible="False">
          <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#40BFEDE4" Offset="0"/><GradientStop Color="#00BFEDE4" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        </Ellipse>
        <Ellipse Width="360" Height="360" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="30,0,0,30" IsHitTestVisible="False">
          <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#2E9FE3D6" Offset="0"/><GradientStop Color="#009FE3D6" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        </Ellipse>

        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="72"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <!-- title bar: tooth mark + clinic name and product, navigation, window buttons -->
          <Border Grid.Row="0" Height="1" VerticalAlignment="Bottom" Margin="30,0,30,0" Background="#DDF2EE" IsHitTestVisible="False"/>
          <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent" Margin="30,0,18,0">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Left">
              <Border Width="44" Height="44" CornerRadius="14" Background="{StaticResource MarkTileGradient}" BorderBrush="#BFEDE4" BorderThickness="1">
                <Path Data="{StaticResource ToothGeometry}" Width="28" Height="30" Stretch="Uniform" Fill="#FFFFFF" Stroke="#1B8C7C" StrokeThickness="2" StrokeLineJoin="Round" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <TextBlock Margin="14,0,0,0" VerticalAlignment="Center" FontSize="19">
                <Run Text="Davis Dental &amp; Orthodontics" Foreground="#1F3A40" FontWeight="SemiBold"/><Run Text=" &#xB7; TradingAgents" Foreground="#1B8C7C" FontWeight="SemiBold"/><Run x:Name="VerRun" Text="" Foreground="#4F6E74" FontSize="11"/>
              </TextBlock>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <Button x:Name="BtnNavAnalyze" Style="{StaticResource NavButton}" Content="New analysis"/>
              <Button x:Name="BtnNavHistory" Style="{StaticResource NavButton}" Content="Past reports"/>
              <Button x:Name="BtnNavSettings" Style="{StaticResource NavButton}" Content="AI settings" Margin="0,0,18,0"/>
              <Button x:Name="BtnMin" Style="{StaticResource WinButton}" Content="&#x2013;" FontSize="16"/>
              <Button x:Name="BtnClose" Style="{StaticResource WinButton}" Content="&#x2715;" FontSize="13"/>
            </StackPanel>
          </Grid>

          <Grid Grid.Row="1" Margin="30,18,30,22">

            <!-- 1. Analyze -->
            <Grid x:Name="ScrAnalyze">
              <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="24"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

              <Border Grid.Column="0" Style="{StaticResource Card}" Padding="28,24">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel Margin="0,0,6,0">
                      <TextBlock Text="Analyze a stock or fund" Foreground="#1F3A40" FontSize="30" FontWeight="Light"/>
                      <TextBlock Text="Type a ticker symbol. A team of AI analysts studies it, debates it, and gives you a plain-English answer." Foreground="#4F6E74" FontSize="14" TextWrapping="Wrap" Margin="0,6,0,20" LineHeight="21"/>
                      <TextBlock Text="TICKER SYMBOL" Foreground="#4F6E74" FontSize="11" FontWeight="SemiBold" Margin="2,0,0,6"/>
                      <TextBox x:Name="TickerBox" Style="{StaticResource GlassInput}" FontSize="28" Padding="16,8" MaxLength="32" CharacterCasing="Upper" FontWeight="SemiBold"/>
                      <TextBlock x:Name="TickerHint" Text="Examples: AAPL is Apple, NVDA is NVIDIA, SPY follows the S&amp;P 500, BTC-USD is Bitcoin." Foreground="#4F6E74" FontSize="13" TextWrapping="Wrap" Margin="2,8,0,0"/>
                      <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                        <TextBlock Text="Try:" Foreground="#4F6E74" FontSize="13" VerticalAlignment="Center" Margin="2,0,10,0"/>
                        <Button x:Name="ChipAAPL" Style="{StaticResource GhostButton}" Content="AAPL" FontSize="13" Padding="14,6" Margin="0,0,8,0"/>
                        <Button x:Name="ChipNVDA" Style="{StaticResource GhostButton}" Content="NVDA" FontSize="13" Padding="14,6" Margin="0,0,8,0"/>
                        <Button x:Name="ChipSPY" Style="{StaticResource GhostButton}" Content="SPY" FontSize="13" Padding="14,6" Margin="0,0,8,0"/>
                        <Button x:Name="ChipBTC" Style="{StaticResource GhostButton}" Content="BTC-USD" FontSize="13" Padding="14,6"/>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal" Margin="0,24,0,0">
                        <Button x:Name="BtnAnalyze" Style="{StaticResource PrimaryButton}" Content="Analyze" FontSize="17" Padding="40,13"/>
                        <Button x:Name="BtnCancel" Style="{StaticResource GhostButton}" Content="Cancel" Margin="14,0,0,0" Visibility="Collapsed"/>
                      </StackPanel>
                      <TextBlock x:Name="RunNote" Text="This takes several minutes. Keep this window open while the team works." Foreground="#4F6E74" FontSize="13" TextWrapping="Wrap" Margin="2,12,0,0"/>
                      <Border x:Name="ErrCard" Visibility="Collapsed" CornerRadius="14" Background="#FFF1F3" BorderBrush="#F0B4BD" BorderThickness="1" Padding="16,12" Margin="0,16,0,0">
                        <StackPanel>
                          <TextBlock Text="The analysis did not finish" Foreground="#D9475B" FontSize="14" FontWeight="SemiBold"/>
                          <TextBlock x:Name="ErrText" Foreground="#1F3A40" FontSize="13" TextWrapping="Wrap" Margin="0,4,0,0" LineHeight="19"/>
                        </StackPanel>
                      </Border>
                    </StackPanel>
                  </ScrollViewer>
                  <TextBlock Grid.Row="1" Text="Research only, not financial advice. No trades are placed." Foreground="#5F7D83" FontSize="12" Margin="2,12,0,0"/>
                </Grid>
              </Border>

              <Border Grid.Column="2" Style="{StaticResource Card}" Padding="26,22">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <Grid Grid.Row="0" Margin="0,0,0,10">
                    <StackPanel>
                      <TextBlock Text="THE TEAM AT WORK" Foreground="#4F6E74" FontSize="11" FontWeight="SemiBold"/>
                      <TextBlock x:Name="StepHead" Text="Ready when you are" Foreground="#1F3A40" FontSize="20" FontWeight="Light" Margin="0,2,0,0"/>
                    </StackPanel>
                    <StackPanel HorizontalAlignment="Right" VerticalAlignment="Center">
                      <TextBlock x:Name="TotalElapsed" Text="0:00" Foreground="#17766A" FontSize="26" FontWeight="Light" HorizontalAlignment="Right"/>
                      <TextBlock Text="time so far" Foreground="#5F7D83" FontSize="11" HorizontalAlignment="Right"/>
                    </StackPanel>
                  </Grid>
                  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel x:Name="StepList" Margin="0,0,6,0"/>
                  </ScrollViewer>
                  <TextBlock Grid.Row="2" x:Name="StepNote" Text="Each analyst studies the stock, then they debate it and the portfolio manager makes the final call." Foreground="#5F7D83" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0"/>
                </Grid>
              </Border>
            </Grid>

            <!-- 2. Results -->
            <Grid x:Name="ScrResults" Visibility="Collapsed">
              <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="20"/><ColumnDefinition Width="1.2*"/></Grid.ColumnDefinitions>

              <!-- the answer: big colour-coded badge + what it means -->
              <Border Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="3" Style="{StaticResource Card}" Padding="24,16">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Border x:Name="ResBadge" Grid.Column="0" CornerRadius="20" Background="#6F8085" MinWidth="300" Padding="26,10" VerticalAlignment="Center">
                    <StackPanel HorizontalAlignment="Center">
                      <TextBlock x:Name="ResRating" Text="REVIEW" Foreground="#FFFFFF" FontSize="40" FontWeight="Bold" HorizontalAlignment="Center"/>
                      <TextBlock x:Name="ResRatingPlain" Text="" Foreground="#FFFFFF" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <StackPanel Grid.Column="2" VerticalAlignment="Center">
                    <Grid>
                      <TextBlock x:Name="ResTicker" Text="SPY" Foreground="#1F3A40" FontSize="28" FontWeight="SemiBold"/>
                      <TextBlock x:Name="ResDate" Text="" Foreground="#4F6E74" FontSize="13" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                    <TextBlock x:Name="ResMeaning" Text="" Foreground="#1F3A40" FontSize="17" TextWrapping="Wrap" LineHeight="24" Margin="0,4,0,0"/>
                  </StackPanel>
                </Grid>
              </Border>

              <!-- why: 3-5 key reasons (scrolls inside the card on small screens) -->
              <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource Card}" Padding="22,16,12,12" Margin="0,16,0,12">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="WHY" Foreground="#4F6E74" FontSize="11" FontWeight="SemiBold"/>
                  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,4,0,0">
                    <StackPanel Margin="0,0,8,0">
                      <StackPanel x:Name="ReasonsPanel"/>
                      <TextBlock x:Name="ReasonsNone" Text="The team did not write short reasons. Open the cards on the right to read their full reports." Foreground="#4F6E74" FontSize="13" TextWrapping="Wrap" Visibility="Collapsed" Margin="0,6,0,0"/>
                    </StackPanel>
                  </ScrollViewer>
                </Grid>
              </Border>

              <!-- the team's reports: fold-out cards -->
              <Grid Grid.Row="1" Grid.Column="2" Margin="0,16,0,12">
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Text="THE TEAM'S REPORTS  (click a card to open it)" Foreground="#4F6E74" FontSize="11" FontWeight="SemiBold" Margin="4,2,0,8"/>
                <ScrollViewer x:Name="CardsScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                  <StackPanel>
                    <Border x:Name="LegacyNote" Visibility="Collapsed" CornerRadius="14" Background="#E8F7F4" BorderBrush="#BFEDE4" BorderThickness="1" Padding="16,12" Margin="0,0,8,10">
                      <TextBlock Text="This is an older report, so only the final decision and the manager's reasoning are shown here. Click Open full report to read everything the team wrote." Foreground="#1F3A40" FontSize="13" TextWrapping="Wrap" LineHeight="19"/>
                    </Border>
                    <StackPanel x:Name="CardsPanel"/>
                  </StackPanel>
                </ScrollViewer>
              </Grid>

              <Grid Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="3">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="4,0,24,0">
                  <TextBlock Text="Research only, not financial advice." Foreground="#1F3A40" FontSize="13" FontWeight="SemiBold"/>
                  <TextBlock x:Name="ResMeta" Text="" Foreground="#5F7D83" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                  <Button x:Name="BtnOpenFull" Style="{StaticResource GhostButton}" Content="Open full report"/>
                  <Button x:Name="BtnNewAnalysis" Style="{StaticResource PrimaryButton}" Content="New analysis" FontSize="15" Padding="28,11" Margin="12,0,0,0"/>
                </StackPanel>
              </Grid>
            </Grid>

            <!-- 3. Past reports -->
            <Grid x:Name="ScrHistory" Visibility="Collapsed">
              <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Margin="4,0,0,12">
                <TextBlock Text="Past reports" Foreground="#1F3A40" FontSize="30" FontWeight="Light"/>
                <TextBlock Text="Click a report to open it. Newest first." Foreground="#4F6E74" FontSize="14" Margin="0,4,0,0"/>
              </StackPanel>
              <Border Grid.Row="1" Style="{StaticResource Card}" Padding="18,16,10,10">
                <Grid>
                  <ListBox x:Name="HistoryList" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Auto">
                    <ListBox.Resources>
                      <Style TargetType="ListBoxItem">
                        <Setter Property="Margin" Value="0,0,8,8"/>
                        <Setter Property="Cursor" Value="Hand"/>
                        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                        <Setter Property="Template">
                          <Setter.Value>
                            <ControlTemplate TargetType="ListBoxItem">
                              <Border x:Name="bd" CornerRadius="14" Background="#FFFFFF" BorderBrush="#D3EFE9" BorderThickness="1.5" Padding="16,10">
                                <ContentPresenter VerticalAlignment="Center"/>
                              </Border>
                              <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                  <Setter TargetName="bd" Property="Background" Value="#F1FBF8"/>
                                  <Setter TargetName="bd" Property="BorderBrush" Value="#2BB5A0"/>
                                </Trigger>
                              </ControlTemplate.Triggers>
                            </ControlTemplate>
                          </Setter.Value>
                        </Setter>
                      </Style>
                    </ListBox.Resources>
                  </ListBox>
                  <TextBlock x:Name="HistoryEmpty" Text="No reports yet. Run your first analysis and it will show up here." Foreground="#4F6E74" FontSize="15" TextWrapping="Wrap" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" MaxWidth="420" TextAlignment="Center"/>
                </Grid>
              </Border>
              <Grid Grid.Row="2" Margin="4,12,0,0">
                <TextBlock x:Name="HistoryCount" Text="" Foreground="#5F7D83" FontSize="12" VerticalAlignment="Center"/>
                <Button x:Name="BtnHistFolder" Style="{StaticResource GhostButton}" Content="Open reports folder" HorizontalAlignment="Right"/>
              </Grid>
            </Grid>

          </Grid>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

# Small "AI settings" window (opened by the AI settings button). Plain controls, same colours as the main window.
$SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AI settings" Width="520" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="#F6FCFA" FontFamily="Segoe UI">
  <StackPanel Margin="24,20,24,22">
    <TextBlock Text="AI settings" FontSize="22" FontWeight="SemiBold" Foreground="#1F3A40"/>
    <TextBlock x:Name="SetCurrent" Margin="0,8,0,0" FontSize="13" Foreground="#4F6E74" TextWrapping="Wrap"/>
    <TextBlock Margin="0,14,0,0" FontSize="13" Foreground="#1F3A40" TextWrapping="Wrap"
               Text="Switch to DeepSeek. Paste your DeepSeek key below (get one at platform.deepseek.com/api_keys). It is saved only on this computer and is never shown again."/>
    <PasswordBox x:Name="SetKey" Margin="0,12,0,0" Padding="8,7" FontSize="14" BorderBrush="#BFEDE4" BorderThickness="1.5"/>
    <TextBlock Margin="0,8,0,0" FontSize="12" Foreground="#4F6E74" TextWrapping="Wrap"
               Text="Final decisions use deepseek-v4-pro (the deep-thinking model); the analysts use deepseek-flash (the fast one). Your other settings are kept."/>
    <TextBlock x:Name="SetMsg" Margin="0,10,0,0" FontSize="13" Foreground="#D9475B" TextWrapping="Wrap" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="SetCancel" Content="Cancel" Padding="18,7" Margin="0,0,10,0" IsCancel="True"/>
      <Button x:Name="SetSave" Content="Save and switch to DeepSeek" Padding="18,7" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

# Every x:Name the code below uses (checked against the XAML by the test script).
$UiNames = @('TitleBar', 'BtnNavAnalyze', 'BtnNavHistory', 'BtnNavSettings', 'BtnMin', 'BtnClose',
    'ScrAnalyze', 'TickerBox', 'TickerHint', 'ChipAAPL', 'ChipNVDA', 'ChipSPY', 'ChipBTC', 'BtnAnalyze', 'BtnCancel', 'RunNote',
    'ErrCard', 'ErrText', 'StepHead', 'TotalElapsed', 'StepList', 'StepNote',
    'ScrResults', 'ResTicker', 'ResDate', 'ResBadge', 'ResRating', 'ResRatingPlain', 'ResMeaning', 'ReasonsPanel', 'ReasonsNone',
    'CardsScroll', 'CardsPanel', 'LegacyNote', 'ResMeta', 'BtnOpenFull', 'BtnNewAnalysis',
    'ScrHistory', 'HistoryList', 'HistoryEmpty', 'HistoryCount', 'BtnHistFolder')

function Start-TaApp {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    $InstallDir = $Here
    $Python  = Join-Path $InstallDir 'venv\Scripts\python.exe'
    $Script  = Join-Path $InstallDir 'run_analysis.py'
    $Desktop = [Environment]::GetFolderPath('Desktop')
    $Reports = Join-Path $InstallDir 'reports'                      # new reports go here (inside the app folder)
    $LegacyReports = Join-Path $Desktop 'TradingAgents Reports'    # older reports: still listed under Past reports
    $ErrorFile = Join-Path $env:TEMP 'TradingAgents-app-error.txt'

    $w = [Windows.Markup.XamlReader]::Parse($Xaml)
    try {   # window/taskbar icon = the tooth icon the installer copied next to this script
        $icoPath = Join-Path $InstallDir 'TradingAgents.ico'
        if (Test-Path -LiteralPath $icoPath) { $w.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icoPath) }
    } catch { }
    # Fit small screens (1366x768 at 100% - 125% scaling): never taller/wider than the usable desktop.
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w.Width = [Math]::Min($w.Width, $wa.Width)
        $w.Height = [Math]::Min($w.Height, $wa.Height)
    } catch { }
    try { $w.FindName('VerRun').Text = '  v' + $KitVersion } catch { }
    $ui = @{}
    foreach ($n in $UiNames) {
        $c = $w.FindName($n)
        if ($null -eq $c) { throw "Internal error: the window is missing '$n'." }
        $ui[$n] = $c
    }
    $bc = New-Object System.Windows.Media.BrushConverter
    function Brush([string]$hex) { return $bc.ConvertFromString($hex) }

    # ---- state ----
    $st = @{ Pump = $null; Run = $null; Started = $null; Current = $null; Rows = @{}; Ticker = ''; Timer = $null; Finishing = $false }

    # ---- small element builders ----
    function New-Text([string]$Text, [double]$Size = 14, [string]$Color = '#1F3A40', [string]$Weight = 'Normal') {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $Text
        $t.FontSize = $Size
        $t.Foreground = Brush $Color
        $t.FontWeight = $Weight
        $t.TextWrapping = 'Wrap'
        return $t
    }

    function Add-Blocks($Panel, $Blocks) {
        foreach ($b in @($Blocks)) {
            if ($b.Kind -eq 'h') {
                $t = New-Text $b.Text 15 '#1B8C7C' 'SemiBold'
                $t.Margin = '0,10,0,4'
                [void]$Panel.Children.Add($t)
            } elseif ($b.Kind -eq 'b') {
                $g = New-Object System.Windows.Controls.Grid
                $g.Margin = ('{0},2,0,3' -f (4 + 18 * [int]$b.Level))
                $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(22)
                $c2 = New-Object System.Windows.Controls.ColumnDefinition
                [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
                $m = New-Text ([string]$b.Marker) 14 '#2BB5A0' 'Bold'
                $m.VerticalAlignment = 'Top'
                $t = New-Text $b.Text 14 '#1F3A40'
                $t.LineHeight = 21
                [System.Windows.Controls.Grid]::SetColumn($t, 1)
                [void]$g.Children.Add($m); [void]$g.Children.Add($t)
                [void]$Panel.Children.Add($g)
            } else {
                $t = New-Text $b.Text 14 '#1F3A40'
                $t.LineHeight = 21
                $t.Margin = '0,2,0,6'
                [void]$Panel.Children.Add($t)
            }
        }
    }

    # ---- screens ----
    function Show-Screen([string]$Name) {
        foreach ($s in 'ScrAnalyze', 'ScrResults', 'ScrHistory') { $ui[$s].Visibility = 'Collapsed' }
        $t = $ui[$Name]
        $t.Visibility = 'Visible'
        $t.Opacity = 0
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(300))))
        $t.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        $slide = New-Object System.Windows.Media.Animation.DoubleAnimation(14, 0, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(300))))
        $slide.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
        $t.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
    }

    # ---- the live step list ----
    function Build-StepRows {
        $ui.StepList.Children.Clear()
        $st.Rows = @{}
        foreach ($d in $StepDefs) {
            $g = New-Object System.Windows.Controls.Grid
            $g.Height = 42
            $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = New-Object System.Windows.GridLength(40)
            $c1 = New-Object System.Windows.Controls.ColumnDefinition
            $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
            [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)

            $icon = New-Object System.Windows.Controls.Grid
            $icon.Width = 26; $icon.Height = 26; $icon.HorizontalAlignment = 'Left'; $icon.VerticalAlignment = 'Center'
            $ring = New-Object System.Windows.Shapes.Ellipse
            $ring.StrokeThickness = 2; $ring.Stroke = Brush '#BFEDE4'; $ring.Fill = Brush '#FFFFFF'
            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 10; $dot.Height = 10; $dot.Fill = Brush '#2BB5A0'; $dot.Visibility = 'Collapsed'
            $chk = New-Object System.Windows.Shapes.Path
            $chk.Data = [System.Windows.Media.Geometry]::Parse('M2,7 L6,11 L13,2')
            $chk.Stroke = Brush '#FFFFFF'; $chk.StrokeThickness = 2.4; $chk.StrokeStartLineCap = 'Round'; $chk.StrokeEndLineCap = 'Round'; $chk.StrokeLineJoin = 'Round'
            $chk.Width = 14; $chk.Height = 12; $chk.Stretch = 'Uniform'; $chk.Visibility = 'Collapsed'
            [void]$icon.Children.Add($ring); [void]$icon.Children.Add($dot); [void]$icon.Children.Add($chk)

            $txt = New-Object System.Windows.Controls.StackPanel
            $txt.VerticalAlignment = 'Center'
            $label = New-Text $d.Label 15 '#6B878C' 'Normal'
            $hint = New-Text $d.Hint 12 '#8AA3A8' 'Normal'
            [void]$txt.Children.Add($label); [void]$txt.Children.Add($hint)
            [System.Windows.Controls.Grid]::SetColumn($txt, 1)

            $time = New-Text '' 13 '#4F6E74' 'Normal'
            $time.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($time, 2)

            [void]$g.Children.Add($icon); [void]$g.Children.Add($txt); [void]$g.Children.Add($time)
            [void]$ui.StepList.Children.Add($g)
            $st.Rows[$d.Id] = @{ Panel = $g; Ring = $ring; Dot = $dot; Check = $chk; Label = $label; Hint = $hint; Time = $time; State = '' }
        }
    }

    function Set-RowState($Row, [string]$State, [string]$TimeText) {
        if ($Row.State -ne $State) {
            $Row.Dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $Row.Dot.Opacity = 1
            switch ($State) {
                'pending' {
                    $Row.Ring.Stroke = Brush '#BFEDE4'; $Row.Ring.Fill = Brush '#FFFFFF'
                    $Row.Dot.Visibility = 'Collapsed'; $Row.Check.Visibility = 'Collapsed'
                    $Row.Label.Foreground = Brush '#6B878C'; $Row.Label.FontWeight = 'Normal'
                }
                'active' {
                    $Row.Ring.Stroke = Brush '#2BB5A0'; $Row.Ring.Fill = Brush '#E8F7F4'
                    $Row.Dot.Visibility = 'Visible'; $Row.Check.Visibility = 'Collapsed'
                    $Row.Label.Foreground = Brush '#1F3A40'; $Row.Label.FontWeight = 'SemiBold'
                    $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation(0.25, 1.0, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(700))))
                    $pulse.AutoReverse = $true
                    $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                    $Row.Dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
                }
                'done' {
                    $Row.Ring.Stroke = Brush '#1B8C7C'; $Row.Ring.Fill = Brush '#1B8C7C'
                    $Row.Dot.Visibility = 'Collapsed'; $Row.Check.Visibility = 'Visible'
                    $Row.Label.Foreground = Brush '#3F5E64'; $Row.Label.FontWeight = 'Normal'
                }
            }
            $Row.State = $State
        }
        $Row.Time.Text = $TimeText
    }

    function Update-StepRows {
        $run = $st.Run
        for ($i = 0; $i -lt $StepDefs.Count; $i++) {
            $id = $StepDefs[$i].Id
            $row = $st.Rows[$id]
            if ($null -eq $run) { Set-RowState $row 'pending' ''; continue }
            if ($id -eq 'fundamentals' -and $run.Crypto) { $row.Panel.Visibility = 'Collapsed'; continue }
            $row.Panel.Visibility = 'Visible'
            $state = Get-StepState $run $i
            $tt = ''
            if ($state -eq 'done' -and $run.Durations.ContainsKey($i)) { $tt = Format-Elapsed $run.Durations[$i] }
            if ($state -eq 'active' -and $run.Starts.ContainsKey($i)) { $tt = Format-Elapsed ((Get-Date) - $run.Starts[$i]).TotalSeconds }
            Set-RowState $row $state $tt
        }
    }

    function Reset-StepRows([string]$Ticker) {
        for ($i = 0; $i -lt $StepDefs.Count; $i++) {
            $row = $st.Rows[$StepDefs[$i].Id]
            Set-RowState $row 'pending' ''
            $row.Panel.Visibility = 'Visible'
        }
        if ($Ticker -and (Test-CryptoTicker $Ticker)) { $st.Rows['fundamentals'].Panel.Visibility = 'Collapsed' }
    }

    # ---- running state of the Analyze screen ----
    function Set-Running([bool]$On) {
        $ui.TickerBox.IsEnabled = -not $On
        $ui.BtnAnalyze.IsEnabled = -not $On
        $ui.BtnAnalyze.Content = $(if ($On) { 'Working...' } else { 'Analyze' })
        $ui.BtnCancel.Visibility = $(if ($On) { 'Visible' } else { 'Collapsed' })
        foreach ($c in 'ChipAAPL', 'ChipNVDA', 'ChipSPY', 'ChipBTC') { $ui[$c].IsEnabled = -not $On }
        $ui.StepNote.Visibility = $(if ($On) { 'Collapsed' } else { 'Visible' })
    }

    function Show-RunError([string]$Message) {
        $ui.ErrText.Text = $Message
        $ui.ErrCard.Visibility = 'Visible'
    }

    function Stop-Timer { if ($st.Timer) { $st.Timer.Stop() } }

    # ---- results ----
    function Show-Report($r) {
        $st.Current = $r
        $info = Get-RatingInfo $r.Rating
        $ui.ResTicker.Text = [string]$r.Ticker
        $ui.ResDate.Text = Format-When ([string]$r.Date) ([string]$r.Time)
        $ui.ResBadge.Background = Brush $info.Fill
        $ui.ResRating.Text = $info.Label
        $ui.ResRating.Foreground = Brush $info.Fore
        $ui.ResRatingPlain.Text = $info.Plain
        $ui.ResRatingPlain.Visibility = $(if ($info.Plain) { 'Visible' } else { 'Collapsed' })
        $ui.ResRatingPlain.Foreground = Brush $info.Fore
        $ui.ResMeaning.Text = $info.Meaning

        # why: 3-5 key reasons from the portfolio manager's text
        $ui.ReasonsPanel.Children.Clear()
        $reasons = @(Get-DisplayReasons ([string]$r.PM))
        $n = 0
        foreach ($txt in $reasons) {
            $n++
            $g = New-Object System.Windows.Controls.Grid
            $g.Margin = '0,6,0,6'
            $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(34)
            $c2 = New-Object System.Windows.Controls.ColumnDefinition
            [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
            $badge = New-Object System.Windows.Controls.Border
            $badge.Width = 24; $badge.Height = 24; $badge.CornerRadius = New-Object System.Windows.CornerRadius(12)
            $badge.Background = Brush '#E8F7F4'; $badge.BorderBrush = Brush '#BFEDE4'; $badge.BorderThickness = '1'
            $badge.HorizontalAlignment = 'Left'; $badge.VerticalAlignment = 'Top'
            $badge.Child = New-Text ([string]$n) 12 '#1B8C7C' 'Bold'
            $badge.Child.HorizontalAlignment = 'Center'; $badge.Child.VerticalAlignment = 'Center'
            $t = New-Text $txt 14 '#1F3A40'
            $t.LineHeight = 21
            [System.Windows.Controls.Grid]::SetColumn($t, 1)
            [void]$g.Children.Add($badge); [void]$g.Children.Add($t)
            [void]$ui.ReasonsPanel.Children.Add($g)
        }
        $ui.ReasonsNone.Visibility = $(if ($reasons.Count -eq 0) { 'Visible' } else { 'Collapsed' })

        # fold-out cards
        $ui.CardsPanel.Children.Clear()
        foreach ($card in @(Get-ReportCards $r)) {
            $ex = New-Object System.Windows.Controls.Expander
            $ex.Style = $w.FindResource('FoldCard')
            $head = New-Object System.Windows.Controls.StackPanel
            [void]$head.Children.Add((New-Text $card.Title 16 '#1F3A40' 'SemiBold'))
            [void]$head.Children.Add((New-Text $card.Sub 12 '#4F6E74' 'Normal'))
            $ex.Header = $head
            $body = New-Object System.Windows.Controls.StackPanel
            $body.Margin = '0,4,0,0'
            $cardPs = New-PlainState
            foreach ($part in $card.Parts) {
                if ($part.Head) {
                    $h = New-Text (Convert-ToPlainEnglish ([string]$part.Head) $cardPs) 14 '#17766A' 'SemiBold'
                    $h.Margin = '0,10,0,2'
                    [void]$body.Children.Add($h)
                }
                Add-Blocks $body (Convert-MdToBlocks (Convert-ToPlainEnglish ([string]$part.Text) $cardPs))
            }
            $ex.Content = $body
            [void]$ui.CardsPanel.Children.Add($ex)
        }
        $ui.LegacyNote.Visibility = $(if ($r.Legacy) { 'Visible' } else { 'Collapsed' })
        $ui.CardsScroll.ScrollToTop()

        $meta = @()
        if ($r.Provider) { $meta += [string]$r.Provider }
        if ($r.Deep -or $r.Quick) {
            if ($r.Deep -and $r.Quick -and $r.Deep -ne $r.Quick) { $meta += ('{0} (final call) / {1} (analysts)' -f $r.Deep, $r.Quick) }
            else { $meta += [string]$(if ($r.Deep) { $r.Deep } else { $r.Quick }) }
        }
        $meta += (Format-When ([string]$r.Date) ([string]$r.Time))
        $dur = Format-Duration $r.Seconds
        if ($dur) { $meta += "took $dur" }
        $ui.ResMeta.Text = ($meta -join "  $MidDot  ")
        Show-Screen 'ScrResults'
    }

    function Open-ReportFile([string]$Path) {
        $r = Read-ReportFile $Path
        if ($null -eq $r) {
            [System.Windows.MessageBox]::Show("This report could not be opened. It may have been moved or blocked by security software.`r`n`r`n$Path", 'TradingAgents', 'OK', 'Warning') | Out-Null
            return
        }
        try { Show-Report $r }
        catch {
            try { Add-Content -LiteralPath $ErrorFile -Value ("{0}  Show-Report: {1}" -f (Get-Date -Format s), $_.Exception.ToString()) } catch { }
            [System.Windows.MessageBox]::Show("This report could not be shown on screen.`r`n`r`n$Path", 'TradingAgents', 'OK', 'Warning') | Out-Null
        }
    }

    # ---- past reports ----
    function Show-History {
        $ui.HistoryList.Items.Clear()
        $items = @(Get-ReportHistoryMulti @($Reports, $LegacyReports))
        foreach ($it in $items) {
            $info = Get-RatingInfo $it.Rating
            $g = New-Object System.Windows.Controls.Grid
            $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = New-Object System.Windows.GridLength(150)
            $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(150)
            $c2 = New-Object System.Windows.Controls.ColumnDefinition
            $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = [System.Windows.GridLength]::Auto
            foreach ($c in $c0, $c1, $c2, $c3) { [void]$g.ColumnDefinitions.Add($c) }
            $pill = New-Object System.Windows.Controls.Border
            $pill.CornerRadius = New-Object System.Windows.CornerRadius(12)
            $pill.Background = Brush $info.Fill
            $pill.Padding = '12,5'
            $pill.HorizontalAlignment = 'Left'; $pill.VerticalAlignment = 'Center'
            $pt = New-Text $info.Label 13 $info.Fore 'Bold'
            $pt.TextWrapping = 'NoWrap'
            $pill.Child = $pt
            $tk = New-Text ([string]$it.Ticker) 19 '#1F3A40' 'SemiBold'
            $tk.VerticalAlignment = 'Center'; $tk.TextTrimming = 'CharacterEllipsis'; $tk.TextWrapping = 'NoWrap'
            [System.Windows.Controls.Grid]::SetColumn($tk, 1)
            $when = New-Text (Format-When ([string]$it.Date) ([string]$it.Time)) 14 '#4F6E74' 'Normal'
            $when.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($when, 2)
            $open = New-Text 'Open' 13 '#17766A' 'SemiBold'
            $open.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($open, 3)
            [void]$g.Children.Add($pill); [void]$g.Children.Add($tk); [void]$g.Children.Add($when); [void]$g.Children.Add($open)
            $li = New-Object System.Windows.Controls.ListBoxItem
            $li.Content = $g
            $li.Tag = $it.Path
            [void]$ui.HistoryList.Items.Add($li)
        }
        $ui.HistoryEmpty.Visibility = $(if ($items.Count -eq 0) { 'Visible' } else { 'Collapsed' })
        $ui.HistoryCount.Text = $(if ($items.Count -eq 0) { '' } elseif ($items.Count -eq 1) { '1 report' } else { "$($items.Count) reports" })
        Show-Screen 'ScrHistory'
    }

    # ---- starting, following and finishing a run ----
    function Start-Run {
        $ticker = $ui.TickerBox.Text.Trim().ToUpper()
        if (-not (Test-TickerSymbol $ticker)) {
            $ui.TickerHint.Text = 'Please type a ticker symbol first, for example AAPL, NVDA, SPY or BTC-USD.'
            $ui.TickerHint.Foreground = Brush '#D9475B'
            $ui.TickerBox.Focus() | Out-Null
            return
        }
        $ui.TickerHint.Text = 'Examples: AAPL is Apple, NVDA is NVIDIA, SPY follows the S&P 500, BTC-USD is Bitcoin.'
        $ui.TickerHint.Foreground = Brush '#4F6E74'
        $ui.ErrCard.Visibility = 'Collapsed'
        if (-not (Test-Path -LiteralPath $Python) -or -not (Test-Path -LiteralPath $Script)) {
            Show-RunError "TradingAgents is not installed yet, or the install did not finish. Run TradingAgents-Setup again."
            return
        }
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir '.env'))) {
            Show-RunError "Your AI key settings are missing. Run TradingAgents-Setup again."
            return
        }
        try { New-Item -ItemType Directory -Force -Path $Reports | Out-Null } catch { }
        $st.Ticker = $ticker
        $st.Run = New-RunState
        $st.Run.Crypto = (Test-CryptoTicker $ticker)
        $st.Started = Get-Date
        $st.Finishing = $false
        Reset-StepRows $ticker
        $ui.StepHead.Text = "Studying $ticker"
        $ui.TotalElapsed.Text = '0:00'
        try {
            $st.Pump = Start-AnalysisProcess $Python $Script $ticker $Reports $InstallDir
        } catch {
            $st.Pump = $null; $st.Run = $null
            Show-RunError ("TradingAgents could not start: " + $_.Exception.Message)
            return
        }
        Set-Running $true
        $st.Timer.Start()
    }

    function Complete-Run {
        Stop-Timer
        $run = $st.Run
        $pump = $st.Pump
        $err = ''
        if ($pump) { $err = $pump.Err.ToString().Trim() }
        $st.Pump = $null
        Set-Running $false
        if ($run -and $run.Done) {
            $res = $run.Result
            $path = Get-JsonProp $res 'json'
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { $path = Get-JsonProp $res 'txt' }
            $r = Read-ReportFile $path
            if ($null -ne $r) {
                $ui.StepHead.Text = 'Finished'
                Show-Report $r
                return
            }
            Show-RunError "The analysis finished, but the report file could not be read:`r`n$path"
            return
        }
        $ui.StepHead.Text = 'Ready when you are'
        $msg = ''
        if ($run) { $msg = $run.Error }
        if (-not $msg) {
            $last = @($err -split "\r?\n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 3) -join ' '
            if ($last) { $msg = "The analysis stopped with an error: $last" }
            else { $msg = "The analysis stopped before it finished. Please try again." }
            $msg += "`r`nMore details: $(Join-Path $InstallDir 'last-error-log.txt')"
        }
        Show-RunError $msg
    }

    function Update-Run {
        if ($null -eq $st.Pump) { return }
        $now = Get-Date
        foreach ($evt in @(Read-AnalysisPump $st.Pump)) { Update-RunState $st.Run $evt $now }
        $ui.TotalElapsed.Text = Format-Elapsed (($now - $st.Started).TotalSeconds)
        Update-StepRows
        if (Test-PumpFinished $st.Pump) {
            # one last drain: the final lines can arrive together with the exit
            foreach ($evt in @(Read-AnalysisPump $st.Pump)) { Update-RunState $st.Run $evt (Get-Date) }
            Update-StepRows
            Complete-Run
        }
    }

    function Stop-Run([bool]$Confirm) {
        if ($null -eq $st.Pump) { return $true }
        if ($Confirm) {
            $a = [System.Windows.MessageBox]::Show('Stop this analysis? Nothing will be saved.', 'TradingAgents', 'YesNo', 'Question')
            if ($a -ne 'Yes') { return $false }
        }
        Stop-Timer
        Stop-AnalysisProcess $st.Pump
        $st.Pump = $null
        $st.Run = $null
        Set-Running $false
        Reset-StepRows ''
        $ui.StepHead.Text = 'Ready when you are'
        $ui.TotalElapsed.Text = '0:00'
        return $true
    }

    # ---- AI settings (switch to DeepSeek) ----
    function Show-AiSettings {
        $envPath = Join-Path $InstallDir '.env'
        $sw = [Windows.Markup.XamlReader]::Parse($SettingsXaml)
        $sw.Owner = $w
        $cur = $sw.FindName('SetCurrent'); $key = $sw.FindName('SetKey'); $msg = $sw.FindName('SetMsg')
        $prov = ''; $hasKey = $false
        try {
            $lines = [System.IO.File]::ReadAllLines($envPath)
            $prov = Get-EnvValue $lines 'TRADINGAGENTS_LLM_PROVIDER'
            $hasKey = [bool](Get-EnvValue $lines 'DEEPSEEK_API_KEY')
        } catch { }
        $cur.Text = $(if ($prov -eq 'deepseek') { 'Currently using: DeepSeek. Paste a new key only if you want to replace it.' }
                      elseif ($prov) { "Currently using: $prov." } else { 'Currently using: not set.' })
        $sw.FindName('SetCancel').Add_Click({ $sw.Close() })
        $sw.FindName('SetSave').Add_Click({
            $msg.Visibility = 'Collapsed'
            if ($null -ne $st.Pump) { $msg.Text = 'An analysis is running. Wait for it to finish, then switch.'; $msg.Visibility = 'Visible'; return }
            $typed = $key.Password.Trim()
            try {
                Save-DeepSeekSettings $envPath $typed
                $key.Clear()
                [System.Windows.MessageBox]::Show('Done. TradingAgents will use DeepSeek from your next analysis. Your key was saved on this computer only.', 'TradingAgents', 'OK', 'Information') | Out-Null
                $sw.Close()
            } catch {
                $msg.Text = $_.Exception.Message
                $msg.Visibility = 'Visible'
            }
        })
        [void]$sw.ShowDialog()
    }

    # ---- build + wire ----
    Build-StepRows
    $st.Timer = New-Object System.Windows.Threading.DispatcherTimer
    $st.Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $st.Timer.Add_Tick({ try { Update-Run } catch { try { Add-Content -LiteralPath $ErrorFile -Value ("{0}  tick: {1}" -f (Get-Date -Format s), $_.Exception.ToString()) } catch { } } })

    $ui.TitleBar.Add_MouseLeftButtonDown({ try { $w.DragMove() } catch { } })
    $ui.BtnMin.Add_Click({ $w.WindowState = 'Minimized' })
    $ui.BtnClose.Add_Click({ $w.Close() })

    $ui.BtnNavAnalyze.Add_Click({ Show-Screen 'ScrAnalyze' })
    $ui.BtnNavHistory.Add_Click({ Show-History })
    $ui.BtnNavSettings.Add_Click({
        try { Show-AiSettings } catch {
            try { Add-Content -LiteralPath $ErrorFile -Value ("{0}  AI settings: {1}" -f (Get-Date -Format s), $_.Exception.ToString()) } catch { }
            [System.Windows.MessageBox]::Show('The AI settings window could not open.', 'TradingAgents', 'OK', 'Warning') | Out-Null
        }
    })
    $ui.BtnNewAnalysis.Add_Click({
        Show-Screen 'ScrAnalyze'
        if ($null -eq $st.Pump) { $ui.ErrCard.Visibility = 'Collapsed'; $ui.TickerBox.Clear(); $ui.TickerBox.Focus() | Out-Null }
    })

    $ui.ChipAAPL.Add_Click({ $ui.TickerBox.Text = 'AAPL' })
    $ui.ChipNVDA.Add_Click({ $ui.TickerBox.Text = 'NVDA' })
    $ui.ChipSPY.Add_Click({ $ui.TickerBox.Text = 'SPY' })
    $ui.ChipBTC.Add_Click({ $ui.TickerBox.Text = 'BTC-USD' })
    $ui.TickerBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return' -and $ui.BtnAnalyze.IsEnabled) { Start-Run } })
    $ui.BtnAnalyze.Add_Click({ Start-Run })
    $ui.BtnCancel.Add_Click({ [void](Stop-Run $true) })

    $ui.HistoryList.Add_SelectionChanged({
        $item = $ui.HistoryList.SelectedItem
        if ($null -eq $item) { return }
        $ui.HistoryList.SelectedIndex = -1
        try { Open-ReportFile ([string]$item.Tag) } catch {
            try { Add-Content -LiteralPath $ErrorFile -Value ("{0}  open: {1}" -f (Get-Date -Format s), $_.Exception.ToString()) } catch { }
            [System.Windows.MessageBox]::Show('This report could not be opened.', 'TradingAgents', 'OK', 'Warning') | Out-Null
        }
    })
    $ui.BtnHistFolder.Add_Click({
        try {
            if (-not (Test-Path -LiteralPath $Reports)) { New-Item -ItemType Directory -Force -Path $Reports | Out-Null }
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Reports + '"')
        } catch { }
    })
    $ui.BtnOpenFull.Add_Click({
        $r = $st.Current
        if ($null -eq $r) { return }
        $p = [string]$r.TxtPath
        $shown = $false
        try {
            # Opens the plain .txt report in Notepad (nothing else: no HTML, no PDF, nothing written to Temp).
            if ($p -and (Test-Path -LiteralPath $p)) {
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $p + '"')
                $shown = $true
            }
        } catch {
            try { Add-Content -LiteralPath $ErrorFile -Value ("{0}  open full report: {1}" -f (Get-Date -Format s), $_.Exception.ToString()) } catch { }
        }
        if (-not $shown) {
            $where = $(if ($p) { "`r`n`r`nIt should be here:`r`n$p" } else { '' })
            [System.Windows.MessageBox]::Show("The full report could not be opened. It may have been moved, or your security software blocked it.$where", 'TradingAgents', 'OK', 'Information') | Out-Null
        }
    })

    $w.Add_Closing({
        param($sender, $e)
        if ($null -ne $st.Pump) {
            $a = [System.Windows.MessageBox]::Show('An analysis is still running. Stop it and close?', 'TradingAgents', 'YesNo', 'Question')
            if ($a -ne 'Yes') { $e.Cancel = $true; return }
            Stop-Timer
            Stop-AnalysisProcess $st.Pump
        }
    })

    $w.Dispatcher.Add_UnhandledException({
        param($sender, $e)
        try { Add-Content -LiteralPath $ErrorFile -Value ("{0}  {1}" -f (Get-Date -Format s), $e.Exception.ToString()) } catch { }
        $e.Handled = $true
    })

    Show-Screen 'ScrAnalyze'
    $ui.TickerBox.Focus() | Out-Null
    [void]$w.ShowDialog()
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        # WPF needs a single-threaded apartment. The Desktop icon passes -STA; if someone starts this another way, restart in STA.
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
            $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', ('"' + $MyInvocation.MyCommand.Path + '"'))
            exit 0
        }
        Start-TaApp
        exit 0
    } catch {
        $msg = $_.Exception.Message + "`r`n" + $_.ScriptStackTrace
        try { [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'TradingAgents-app-error.txt'), $msg) } catch { }
        try {
            Add-Type -AssemblyName PresentationFramework
            [System.Windows.MessageBox]::Show("The TradingAgents window could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nDetails: $env:TEMP\TradingAgents-app-error.txt`r`n`r`nYou can still use 'Run TradingAgents (console)' in the TradingAgents folder.", 'TradingAgents', 'OK', 'Error') | Out-Null
        } catch { }
        exit 1
    }
}

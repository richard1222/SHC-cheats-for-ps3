<#
  shc_hp_lock.ps1  -  Super Heroine Chronicle (PS3) INFINITE HP / GOD MODE
  -----------------------------------------------------------------------
  Finds and locks a character's HP in the RUNNING game's RAM using
  webMAN MOD's PS3MAPI memory engine over HTTP. No Artemis, no injection,
  nothing that can crash the console.

  WHY THIS AND NOT THE CPK EDIT:
  The CPK stat edit (CharParam.csv) was installed but did not reach the
  battle stats, so this works directly on live memory instead.

  HOW TO USE (classic 3-step trainer narrowing):
    1. Start SHC and get into a battle. Look at your character's HP,
       e.g. "600/600".
    2. Run:  .\shc_hp_lock.ps1 -Mode find -HP 600
    3. Let the character take a hit (HP drops, e.g. to 540).
       Run:  .\shc_hp_lock.ps1 -Mode narrow -HP 540
       Repeat narrow until only 1-3 candidates remain.
    4. Run:  .\shc_hp_lock.ps1 -Mode lock
       -> writes 9999 to the HP address in a loop, so HP never drops.

  Or just run with no arguments for an interactive menu.

  EXAMPLES
    .\shc_hp_lock.ps1                       # interactive menu
    .\shc_hp_lock.ps1 -Mode find -HP 600
    .\shc_hp_lock.ps1 -Mode narrow -HP 540
    .\shc_hp_lock.ps1 -Mode list
    .\shc_hp_lock.ps1 -Mode lock -LockValue 9999
    .\shc_hp_lock.ps1 -Mode lock -Value 9999    # alias, non-interactive
    .\shc_hp_lock.ps1 -Mode unlock              # stop the lock loop
#>
[CmdletBinding()]
param(
  [string]$IP   = "PS3_IP_HERE",
  [ValidateSet("menu","find","narrow","list","lock","unlock","status")]
  [string]$Mode = "menu",
  [int]$HP      = 0,               # HP value you can SEE on screen
  [int]$LockValue = 9999,          # value to force HP to
  [int]$Value   = 0,               # alias for -LockValue (handy for .bat)
  [int]$Limit   = 3000,            # max candidates to track
  [string]$CandidateFile = ""
)

$ErrorActionPreference = "Stop"

# Refuse to run until the user has set their own console address.
if ($IP -eq "PS3_IP_HERE") {
    Write-Host "SET YOUR PS3 IP FIRST:" -ForegroundColor Yellow
    Write-Host "  edit the `$IP line at the top of this script, e.g." -ForegroundColor Yellow
    Write-Host "      `$IP = `"192.168.1.50`"" -ForegroundColor Gray
    Write-Host "  (XMB -> Settings -> Network Settings -> Connection Status)" -ForegroundColor DarkGray
    exit 1
}

$script:Base = "http://$IP"

# $PSScriptRoot can be empty while the param block is being bound on some
# PowerShell builds, so resolve the script folder here instead.
if ($PSScriptRoot) { $script:Root = $PSScriptRoot }
else { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $CandidateFile) { $CandidateFile = Join-Path $script:Root "hp_candidates.txt" }

# ---------------------------------------------------------------- helpers
function Get-Raw([string]$query) {
  try { return ((curl.exe -s --max-time 30 "$script:Base/$query") -join "`n") }
  catch { return "" }
}

function Get-Pid {
  # Scrape the game process id from the PS3MAPI getmem page. The dropdown
  # looks like:  <option value="0x1030200"/>01030200_main_EBOOT.BIN
  # NOTE: the first <option> is NOT necessarily the running game, so match
  # specifically on the *_main_EBOOT.BIN entry.
  $r = Get-Raw "getmem.ps3mapi"
  $m = [regex]::Match($r, '<option value="(0x[0-9A-Fa-f]+)"\s*/>\s*([0-9A-Fa-f]{8})_main_EBOOT\.BIN')
  if ($m.Success) { return $m.Groups[1].Value }
  # Fallback: any *_main_* option (e.g. an unusual EBOOT name)
  $m = [regex]::Match($r, '<option value="(0x[0-9A-Fa-f]+)"\s*/>\s*[0-9A-Fa-f]{8}_main_[^<]*')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Find-Bytes([string]$proc, [string]$pat, [string]$start = "0") {
  # returns the address (hex, no 0x) of the first match at/after $start,
  # or $null when the server reports "not found" (it echoes the start addr).
  $r = Get-Raw "getmem.ps3mapi?proc=$proc&addr=0x$start&find=$pat"
  $m = [regex]::Match($r, 'name="addr"[^>]*value="([0-9A-Fa-f]+)"')
  if (-not $m.Success) { return $null }
  $a = $m.Groups[1].Value.TrimStart('0')
  if ($a -eq "") { $a = "0" }
  $s = $start.TrimStart('0'); if ($s -eq "") { $s = "0" }
  if ($a -eq $s) { return $null }   # not found: server echoed the start
  return $a
}

function Read-Bytes([string]$proc, [string]$addrHex, [int]$len = 16) {
  $fmt = "{0:X8}" -f ([Convert]::ToUInt32($addrHex, 16))
  $r = Get-Raw "getmem.ps3mapi?proc=$proc&addr=0x$fmt&len=$len"
  $m = [regex]::Match($r, [regex]::Escape($fmt) + "\s+((?:[0-9A-F]{2}\s+){15}[0-9A-F]{2})")
  if ($m.Success) { return ($m.Groups[1].Value -replace '\s+', '') }
  return $null
}

function Read-Int32([string]$proc, [string]$addrHex) {
  $h = Read-Bytes $proc $addrHex 16
  if (-not $h) { return $null }
  return [Convert]::ToUInt32($h.Substring(0, 8), 16)
}

function Read-Int16([string]$proc, [string]$addrHex) {
  $h = Read-Bytes $proc $addrHex 16
  if (-not $h) { return $null }
  return [Convert]::ToUInt32($h.Substring(0, 4), 16)
}

function Write-Val([string]$proc, [string]$addrHex, [uint32]$val32, [int]$width = 4) {
  $hex = if ($width -eq 4) { "{0:X8}" -f $val32 } else { "{0:X4}" -f $val32 }
  $a = $addrHex.TrimStart('0'); if ($a -eq "") { $a = "0" }
  $r = Get-Raw "setmem.ps3mapi?proc=$proc&addr=$a&oper=0&val=$hex"
  return ($r -match "(?i)ok|success|written|setmem") -or ($r -notmatch "(?i)error")
}

function Save-Candidates([string]$path, $rows) {
  $rows | ForEach-Object { "{0},{1}" -f $_.addr, $_.width } | Set-Content -Encoding ASCII $path
}
function Load-Candidates([string]$path) {
  if (-not (Test-Path $path)) { return @() }
  return (Get-Content -Encoding ASCII $path) | Where-Object { $_ -match "^\S+,\d+$" } | ForEach-Object {
    $p = $_ -split ","; [pscustomobject]@{ addr = $p[0]; width = [int]$p[1] }
  }
}

function Require-Proc {
  # NOTE: $PID is a reserved automatic variable, so use a different name.
  $gproc = Get-Pid
  if (-not $gproc) {
    Write-Host "!! Could not find a running game process." -ForegroundColor Red
    Write-Host "   Start Super Heroine Chronicle and load a battle first." -ForegroundColor Yellow
    exit 1
  }
  return $gproc
}

# ------------------------------------------------------------------ modes
function Do-Find([int]$hp) {
  $proc = Require-Proc
  Write-Host ("Searching process {0} for HP = {1} (as int32 and int16)..." -f $proc, $hp) -ForegroundColor Cyan
  $rows  = New-Object System.Collections.Generic.List[object]
  foreach ($w in 4, 2) {
    $pat = if ($w -eq 4) { "{0:X8}" -f $hp } else { "{0:X4}" -f $hp }
    $start = "0"; $guard = 0
    while ($rows.Count -lt $Limit -and $guard -lt 200000) {
      $guard++
      $a = Find-Bytes $proc $pat $start
      if (-not $a) { break }
      $rows.Add([pscustomobject]@{ addr = $a; width = $w })
      $start = "{0:X}" -f ([Convert]::ToUInt32($a, 16) + 1)
    }
  }
  Save-Candidates $CandidateFile $rows
  Write-Host ("  -> {0} candidate address(es) saved to {1}" -f $rows.Count, $CandidateFile) -ForegroundColor Green
  Show-List $rows 20
}

function Do-Narrow([int]$hp) {
  $proc = Require-Proc
  $rows = Load-Candidates $CandidateFile
  if ($rows.Count -eq 0) { Write-Host "No candidates - run -Mode find first." -ForegroundColor Red; return }
  Write-Host ("Re-reading {0} candidate(s), keeping those now equal to {1}..." -f $rows.Count, $hp) -ForegroundColor Cyan
  $keep = New-Object System.Collections.Generic.List[object]
  foreach ($c in $rows) {
    $v = if ($c.width -eq 4) { Read-Int32 $proc $c.addr } else { Read-Int16 $proc $c.addr }
    if ($v -eq $hp) { $keep.Add($c) }
  }
  Save-Candidates $CandidateFile $keep
  Write-Host ("  -> {0} candidate(s) remain" -f $keep.Count) -ForegroundColor Green
  Show-List $keep 20
  if ($keep.Count -le 3 -and $keep.Count -ge 1) {
    Write-Host "  Looks good! Run:  -Mode lock" -ForegroundColor Yellow
  }
}

function Show-List($rows, [int]$max = 50) {
  $proc = Get-Pid
  $i = 0
  foreach ($c in $rows) {
    if ($i -ge $max) { Write-Host ("  ... and {0} more" -f ($rows.Count - $max)); break }
    $v = if ($c.width -eq 4) { Read-Int32 $proc $c.addr } else { Read-Int16 $proc $c.addr }
    $ctx = Read-Bytes $proc $c.addr 16
    Write-Host ("  {0,3}. 0x{1,-9} int{2}  now={3,-6}  ctx={4}" -f ($i + 1), $c.addr, ($c.width * 8), $v, $ctx)
    $i++
  }
}

function Do-List {
  $proc = Require-Proc
  $rows = Load-Candidates $CandidateFile
  Write-Host ("{0} candidate(s) in {1}" -f $rows.Count, $CandidateFile) -ForegroundColor Cyan
  Show-List $rows 50
}

function Do-Lock([int]$val) {
  $proc = Require-Proc
  $rows = Load-Candidates $CandidateFile
  if ($rows.Count -eq 0) { Write-Host "No candidates - run -Mode find first." -ForegroundColor Red; return }
  if ($rows.Count -gt 8) { Write-Host ("Warning: {0} candidates - narrow more first." -f $rows.Count) -ForegroundColor Yellow }
  $lockFile = Join-Path $script:Root "hp_lock.pid"
  Set-Content -Encoding ASCII $lockFile $PID
  Write-Host ""
  Write-Host ("LOCKING HP = {0} on {1} address(es). Press Ctrl+C to stop." -f $val, $rows.Count) -ForegroundColor Green
  Write-Host "  (the game will keep running; nothing is injected)" -ForegroundColor DarkGray
  try {
    while ($true) {
      foreach ($c in $rows) {
        if ($c.width -eq 4) { Write-Val $proc $c.addr ([uint32]$val) 4 | Out-Null }
        else                { Write-Val $proc $c.addr ([uint32]$val) 2 | Out-Null }
      }
      Start-Sleep -Milliseconds 200
    }
  } finally {
    Remove-Item $lockFile -ErrorAction SilentlyContinue
  }
}

function Do-Unlock {
  $lockFile = Join-Path $script:Root "hp_lock.pid"
  if (-not (Test-Path $lockFile)) { Write-Host "No lock is running." -ForegroundColor Yellow; return }
  $lpid = [int](Get-Content $lockFile)
  try { Stop-Process -Id $lpid -Force; Write-Host ("Stopped lock loop (PID {0})." -f $lpid) -ForegroundColor Green }
  catch { Write-Host "Lock loop already stopped." -ForegroundColor Yellow }
  Remove-Item $lockFile -ErrorAction SilentlyContinue
}

function Do-Status {
  $pid_ = Get-Pid
  if ($pid_) { Write-Host ("Game process: {0}  (running)" -f $pid_) -ForegroundColor Green }
  else       { Write-Host "No game process found (PS3 at XMB?)." -ForegroundColor Yellow }
  $rows = Load-Candidates $CandidateFile
  $lockFile = Join-Path $script:Root "hp_lock.pid"
  Write-Host ("Candidates : {0}" -f $rows.Count)
  $lockState = if (Test-Path $lockFile) { "RUNNING" } else { "stopped" }
  Write-Host ("Lock loop  : {0}" -f $lockState)
}

function Read-Int([string]$prompt, [int]$default = 0) {
  $s = Read-Host $prompt
  if ([string]::IsNullOrWhiteSpace($s)) { return $default }
  $n = 0
  if ([int]::TryParse($s.Trim(), [ref]$n)) { return $n }
  Write-Host "  (not a number)" -ForegroundColor Yellow
  return $default
}

function Do-Menu {
  while ($true) {
    Write-Host ""
    Write-Host "=== SHC Infinite HP / God Mode ===" -ForegroundColor Cyan
    Write-Host ("  IP: {0}" -f $IP)
    $rows = Load-Candidates $CandidateFile
    Write-Host ("  candidates on file: {0}" -f $rows.Count)
    Write-Host ""
    Write-Host "  1) find    - search for the HP value you see on screen"
    Write-Host "  2) narrow  - after HP changes, drop non-matching addresses"
    Write-Host "  3) list    - show current candidates"
    Write-Host "  4) lock    - force HP (infinite HP)"
    Write-Host "  5) unlock  - stop forcing"
    Write-Host "  6) status"
    Write-Host "  q) quit"
    $c = Read-Host "choice"
    switch ($c) {
      "1" { $v = Read-Int "  HP shown in battle (e.g. 600)"; if ($v -gt 0) { Do-Find $v } }
      "2" { $v = Read-Int "  new HP shown (e.g. 540)"; if ($v -gt 0) { Do-Narrow $v } }
      "3" { Do-List }
      "4" { $v = Read-Int "  lock HP to (default 9999)" 9999; if ($v -le 0) { $v = 9999 }; Do-Lock $v }
      "5" { Do-Unlock }
      "6" { Do-Status }
      "q" { return }
      default { Write-Host "?" }
    }
  }
}

if ($Value -gt 0) { $LockValue = $Value }

switch ($Mode) {
  "find"   { Do-Find $HP }
  "narrow" { Do-Narrow $HP }
  "list"   { Do-List }
  "lock"   { Do-Lock $LockValue }
  "unlock" { Do-Unlock }
  "status" { Do-Status }
  default  { Do-Menu }
}

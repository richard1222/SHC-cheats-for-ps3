<#
================================================================================
 shc_godmode.ps1  --  Super Heroine Chronicle (BLJS10244)  GOD MODE (HP LOCK)
================================================================================
   Locks a character's live battle HP so it never drops.

   Needs NO Artemis and no permanent patch: it finds the character's HP field
   in the PS3's RAM through webMAN MOD's PS3MAPI web interface, then re-writes
   it a few times a second so the game's own damage code never wins.

   * RAM ONLY  : nothing on the PS3's disk is touched.  Quit = stock game.
   * RE-FINDS  : the HP field lives on the heap, so it MOVES every battle and
                 every launch.  The tool searches for it each time it runs.
   * CFW AGNOSTIC : anything running webMAN MOD (any CFW, DEX/CEX).

   HOW IT FINDS THE FIELD
     The game keeps a static "base" copy of a character's stat block and a
     separate LIVE copy that battle actually uses.  The base copy sits exactly
     0x374 bytes (884) BEFORE the live one, and its first two words are:

         [ full HP , 159 ]        <- big-endian 32-bit integers

     (verified: full HP 1920 and 159 for a level-35 Jeanne)

     So the tool scans the heap for those 8 bytes, adds 0x374 to get the live
     HP field, then VALIDATES the live struct before writing anything.  If the
     structure does not check out it refuses and writes nothing.

     Note the PS3's CPU is big-endian: value 557 is the bytes 00 00 02 2D.

   Usage
     Apply :  powershell -ExecutionPolicy Bypass -File shc_godmode.ps1
     Stop  :  powershell -ExecutionPolicy Bypass -File shc_godmode.ps1 -Mode off
     Find  :  powershell -ExecutionPolicy Bypass -File shc_godmode.ps1 -Mode find
     Other :  ... -Value 5000            lock HP to 5000 instead of 9999
             ... -MaxHP 1428             if her full HP is not 1920 (see below)
             ... -IntervalMs 500         slower lock loop (less network traffic)

     (or just double-click HP-GodMode.bat / HP-FIND.bat / HP-GodMode-OFF.bat)

   IF IT SAYS "no match"
     The search signature starts with the character's FULL HP.  That number
     changes with level and equipment, so if Jeanne is a different level than
     35, look at her HP bar while she is undamaged and pass that number:

         powershell -ExecutionPolicy Bypass -File shc_godmode.ps1 -MaxHP 1428
================================================================================
#>
param(
    [string] $IP = "PS3_IP_HERE",
    [ValidateSet("on","off","find","status")] [string] $Mode = "on",

    # what to lock HP to
    [int] $Value = 9999,
    # delay between lock writes (ms).  Lower = harder for the game to win.
    [ValidateRange(50, 5000)] [int] $IntervalMs = 300,

    # --- search signature -----------------------------------------------------
    # first word of the base stat copy = the character's FULL (undamaged) HP
    [int] $MaxHP = 1920,
    # second word, right after full HP.  159 for Jeanne; stays put in battle.
    [int] $Sig2 = 159,
    # third check: a field in the LIVE struct that does not move in battle.
    [int] $Check3 = 1170,

    # --- heap geometry (BLJS10244 01.00) -------------------------------------
    [uint32] $HeapStart = 0x30000000,
    [uint32] $HeapEnd   = 0x34C00000,
    # distance from the static base copy to the live copy
    [uint32] $LiveDelta = 0x374,
    # each webMAN "find" call only reaches ~16 MB forward, so sweep in windows
    [uint32] $WinStep   = 0x800000,

    [switch] $RestoreOnExit
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

$stateFile = Join-Path $PSScriptRoot "hp_lock_state.txt"
$script:proc = ""

function Invoke-Ps3([string]$path) {
    $url = "http://$IP/$path"
    return ((curl.exe -s --max-time 15 $url) -join "")
}

function Get-Ps3Mem([string]$addrHex, [int]$len = 16) {
    $fmt = "{0:X8}" -f [Convert]::ToUInt32($addrHex, 16)
    $r = Invoke-Ps3 "getmem.ps3mapi?proc=$script:proc&addr=0x$fmt&len=$len"
    $m = [regex]::Match($r, [regex]::Escape($fmt) + "\s+((?:[0-9A-F]{2}\s+){1,})")
    if ($m.Success) { return ($m.Groups[1].Value.Trim() -replace '\s+', '') }
    return $null
}

function Set-Ps3Mem([string]$addrHex, [string]$valHex) {
    Invoke-Ps3 "setmem.ps3mapi?proc=$script:proc&addr=$addrHex&oper=0&val=$valHex" | Out-Null
}

# read one big-endian 32-bit word; returns $null if memory could not be read
function Read-Word([uint32]$addr) {
    $h = Get-Ps3Mem ("{0:X8}" -f $addr) 4
    if ($null -eq $h -or $h.Length -lt 8) { return $null }
    return [Convert]::ToUInt32($h.Substring(0, 8), 16)
}

# webMAN "find" returns the START ADDRESS as its not-found sentinel,
# so a hit is only real when the result differs from what we asked for.
function Find-Ps3([uint32]$start, [string]$sig) {
    $s = "{0:X8}" -f $start
    $r = Invoke-Ps3 "getmem.ps3mapi?proc=$script:proc&addr=0x$s&find=$sig"
    if ($r -match 'name="addr"[^>]*value="([0-9A-Fa-f]+)"') {
        $v = "{0:X8}" -f [Convert]::ToUInt32($matches[1], 16)
        if ($v -ne $s) { return $v }
    }
    return $null
}

function Show([string]$msg, [string]$color = "Gray") {
    Write-Host $msg -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# locate the live HP field.  returns $null or a hashtable.
# ---------------------------------------------------------------------------
function Find-HpField {
    $sig = "{0:X8}{1:X8}" -f [uint32]$MaxHP, [uint32]$Sig2

    Show ("  heap 0x{0:X8} - 0x{1:X8}   signature [{2} , {3}] = {4}" -f `
        $HeapStart, $HeapEnd, $MaxHP, $Sig2, $sig) DarkGray

    $hits = @()
    for ($w = $HeapStart; $w -lt $HeapEnd; $w = [uint32]($w + $WinStep)) {
        $r = Find-Ps3 $w $sig
        if ($r) {
            $hits += $r
            Show ("    candidate base copy at 0x{0}" -f $r) DarkGray
        }
    }

    if ($hits.Count -eq 0) {
        Show "  no match.  Her full HP probably is not $MaxHP anymore." Red
        Show "  Run HP-FIND.bat, look at her undamaged max HP, then use -MaxHP <number>." Red
        return $null
    }

    # validate each candidate against the LIVE struct
    $good = @()
    foreach ($h in $hits) {
        $base = [Convert]::ToUInt32($h, 16)
        $live = [uint32]($base + $LiveDelta)
        $hp  = Read-Word $live          # current HP
        $s2  = Read-Word ([uint32]($live + 4))
        $c3  = Read-Word ([uint32]($live + 0x14))

        $ok = ($null -ne $hp -and $null -ne $s2 -and
               $s2 -eq [uint32]$Sig2 -and $hp -le 100000)
        $extra = ""
        if ($ok -and $c3 -ne [uint32]$Check3) {
            $extra = "   (note: +0x14 is $c3, expected $Check3 - continuing)"
        }

        if ($ok) {
            Show ("    0x{0}  ->  live HP field 0x{1}   HP={2}  [{3}]={4}  +0x14={5}{6}" -f `
                $h, $live, $hp, $Sig2, $s2, $c3, $extra) Green
            $good += @{ base = $base; live = $live; hp = $hp }
        } else {
            Show ("    0x{0}  ->  REJECTED (live+4 = {1}, expected {2})" -f $h, $s2, $Sig2) Yellow
        }
    }

    if ($good.Count -eq 0) {
        Show "  candidates found but none matched the live struct - nothing written." Yellow
        return $null
    }
    if ($good.Count -gt 1) {
        Show ("  {0} matches - using the first. Re-run if the wrong one is picked." -f $good.Count) Yellow
    }
    return $good[0]
}

# ---------------------------------------------------------------------------
Write-Host ""
Show "==============================================================================" Cyan
Show "  Super Heroine Chronicle  -  GOD MODE / HP lock   (webMAN MOD / PS3MAPI)"     Cyan
Show "==============================================================================" Cyan
Show ""

# --- find the console --------------------------------------------------------
Write-Host "[1/4] Looking for webMAN MOD at $IP ... " -NoNewline
try {
    $cpursx = Invoke-Ps3 "cpursx.ps3"
} catch {
    Show "FAILED" Red
    Show "      Could not reach http://$IP/  -- is webMAN MOD running / PS3 on?" Red
    exit 1
}
if ($cpursx -notmatch "webMAN|wMAN") {
    Show "NOT FOUND" Red
    Show "      $IP answered but does not look like webMAN MOD." Red
    exit 1
}
Show "yes" Green

# --- find the running game process -------------------------------------------
Write-Host "[2/4] Finding the running game process ... " -NoNewline
if ($cpursx -match "pid=([0-9A-Fa-f]{8})") {
    $script:proc = "0x" + $matches[1]
} else {
    Show "NOT FOUND" Red
    Show "      No game is running.  Launch Super Heroine Chronicle first." Red
    exit 1
}
Show ("pid=" + $script:proc) Green
if ($cpursx -notmatch "BLJS10244") {
    Show "      WARNING: running title is not BLJS10244.  Continue only if this is SHC." Yellow
}

# --- locate ------------------------------------------------------------------
Write-Host "[3/4] Locating the live HP field ... " -NoNewline
Show ""
$field = Find-HpField
if ($null -eq $field) {
    Show ""
    Show "Not locking anything.  Nothing was written to the console." Yellow
    exit 1
}
$hpAddr = $field.live
Show ("  -> locking 0x{0}" -f $hpAddr) Cyan

# --- act ---------------------------------------------------------------------
Write-Host "[4/4] $Mode" -NoNewline
Show ""
Show ""

switch ($Mode) {

    "find" {
        Show ("  base copy (static) : 0x{0:X8}" -f $field.base) Gray
        Show ("  live HP field      : 0x{0:X8}" -f $hpAddr) Gray
        Show ("  current HP         : {0}" -f $field.hp) Gray
        Show ""
        Show "Read-only pass.  Nothing was written." Cyan
    }

    "status" {
        $hp  = Read-Word $hpAddr
        $sp  = Read-Word ([uint32]($hpAddr + 8))
        $s2  = Read-Word ([uint32]($hpAddr + 4))
        Show ("  HP field 0x{0:X8} = {1}" -f $hpAddr, $hp) Gray
        Show ("  SP field          = {0}" -f $sp) Gray
        Show ("  word +0x04        = {0}" -f $s2) Gray
        if ($hp -eq [uint32]$Value) {
            Show "  -> LOCK IS ACTIVE (HP held at $Value)" Green
        } else {
            Show "  -> not locked right now" DarkGray
        }
    }

    "off" {
        if (Test-Path $stateFile) {
            $st = Get-Content $stateFile | ConvertFrom-Json
            $oldAddr = [Convert]::ToUInt32($st.addr, 16)
            # only restore if that address still looks like the HP field
            $chk = Read-Word ([uint32]($oldAddr + 4))
            if ($chk -eq [uint32]$Sig2) {
                $restore = "{0:X8}" -f [uint32]$st.value
                Set-Ps3Mem ("{0:X8}" -f $oldAddr) $restore
                Start-Sleep -Milliseconds 300
                $now = Read-Word $oldAddr
                Show ("  restored HP at 0x{0:X8} to {1}  (read back: {2})" -f `
                    $oldAddr, $st.value, $now) Green
            } else {
                Show "  saved address no longer looks like the HP field - skipped." Yellow
            }
            Remove-Item $stateFile -Force
            Show "  lock state cleared." Green
        } else {
            Show "  no active lock recorded - nothing to undo." DarkGray
        }
        Show ""
        Show "Reminder: HP-GodMode.bat must be STOPPED (close its window) to stay off." DarkGray
    }

    "on" {
        # remember the natural HP so "off" can put it back
        $natural = Read-Word $hpAddr
        @{ addr = "{0:X8}" -f $hpAddr; value = $natural } | ConvertTo-Json | Set-Content $stateFile

        Show ("  God mode ON.  HP held at {0}  (every {1} ms)" -f $Value, $IntervalMs) Green
        Show ("  natural HP was {0} - HP-GodMode-OFF.bat restores it." -f $natural) DarkGray
        Show "  Leave this window open.  Press Ctrl+C to stop." DarkGray
        Show ""

        $target = "{0:X8}" -f [uint32]$Value
        $tick = 0
        $stuck = 0

        try {
            for (;;) {
                Set-Ps3Mem ("{0:X8}" -f $hpAddr) $target
                $tick++

                # periodically prove the value is actually sticking
                if (($tick % 4) -eq 0) {
                    $now = Read-Word $hpAddr
                    if ($now -eq [uint32]$Value) {
                        $stuck = 0
                        Write-Host ("`r  HP = {0,-6}  tick {1,-8} locked    " -f $now, $tick) -ForegroundColor Green
                    } else {
                        $stuck++
                        Write-Host ("`r  HP = {0,-6}  tick {1,-8} ({2})     " -f $now, $tick, $now) -ForegroundColor Yellow
                        # the battle likely changed - re-locate the field
                        if ($stuck -ge 3) {
                            Show ""
                            Show "  value not sticking - re-scanning for the HP field ..." Yellow
                            $nf = Find-HpField
                            if ($null -ne $nf) {
                                $hpAddr = $nf.live
                                @{ addr = "{0:X8}" -f $hpAddr; value = $natural } | ConvertTo-Json | Set-Content $stateFile
                                $stuck = 0
                                Show ("  now locking 0x{0}" -f $hpAddr) Cyan
                            } else {
                                Show "  could not re-locate - keep waiting." Yellow
                                $stuck = 0
                            }
                        }
                    }
                }
                Start-Sleep -Milliseconds $IntervalMs
            }
        } finally {
            Show ""
            if ($RestoreOnExit) {
                $chk = Read-Word ([uint32]($hpAddr + 4))
                if ($chk -eq [uint32]$Sig2) {
                    Set-Ps3Mem ("{0:X8}" -f $hpAddr) ("{0:X8}" -f [uint32]$natural)
                    Show ("  restored HP to {0}" -f $natural) DarkGray
                }
            } else {
                Show "  lock stopped.  (HP stays where it is - run HP-GodMode-OFF.bat to restore)" DarkGray
            }
        }
    }
}

Show ""

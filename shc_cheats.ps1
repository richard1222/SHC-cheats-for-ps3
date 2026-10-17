<#
================================================================================
 shc_cheats.ps1  --  Super Heroine Chronicle (BLJS10244) LIVE MEMORY CHEATS
================================================================================
   Infinite SP      (SP never decreases)
   Unlimited Turns

 How it works
   Talks to webMAN MOD's PS3MAPI memory engine on your PS3 over the network and
   patches the running game's code in RAM.  This is exactly what Artemis tries
   to do, but WITHOUT Artemis -> nothing to crash.

   * RAM only    : nothing on the PS3's disk is touched. Reboot = stock game.
   * Re-apply    : run this again every time you launch the game.
   * Any CFW     : any CFW, DEX or CEX, as long as webMAN MOD is
                   installed and its web server (port 80) is reachable.

 Usage
   Apply  :  powershell -ExecutionPolicy Bypass -File shc_cheats.ps1
   Revert :  powershell -ExecutionPolicy Bypass -File shc_cheats.ps1 -Mode off
   Status :  powershell -ExecutionPolicy Bypass -File shc_cheats.ps1 -Mode status
   Custom :  powershell -ExecutionPolicy Bypass -File shc_cheats.ps1 -IP 192.168.1.50

   (or just double-click Cheats-ON.bat / Cheats-OFF.bat / Cheats-STATUS.bat)
================================================================================
#>
param(
    [string] $IP   = "PS3_IP_HERE",
    [ValidateSet("on","off","status")] [string] $Mode = "on"
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


# ----------------------------------------------------------------------------
# The cheat table.  addr = RAM address in the game process (hex, no 0x).
# Verified against BLJS10244 ver 01.00 EBOOT.
# ----------------------------------------------------------------------------
$CODES = @(
    @{ name = "Infinite SP (SP never decreases)"; addr = "924C0";  orig = "40800008"; hack = "48000008" },
    @{ name = "Unlimited Turns";                  addr = "1AC22C"; orig = "80840000"; hack = "38800001" }
)

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

function Show([string]$msg, [string]$color = "Gray") {
    Write-Host $msg -ForegroundColor $color
}

# ----------------------------------------------------------------------------
Write-Host ""
Show "==============================================================================" Cyan
Show "  Super Heroine Chronicle  -  live memory cheats   (webMAN MOD / PS3MAPI)"   Cyan
Show "==============================================================================" Cyan
Show ""

# --- find the console ---------------------------------------------------------
Write-Host "[1/3] Looking for webMAN MOD at $IP ... " -NoNewline
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
Write-Host "[2/3] Finding the running game process ... " -NoNewline
if ($cpursx -match "pid=([0-9A-Fa-f]{8})") {
    $script:proc = "0x" + $matches[1]
} else {
    Show "NOT FOUND" Red
    Show "      No game is running.  Launch Super Heroine Chronicle first, then re-run." Red
    exit 1
}
$isRightGame = ($cpursx -match "BLJS10244")
Show ("pid=" + $script:proc) Green
if (-not $isRightGame) {
    Show "      WARNING: the running title is not BLJS10244.  Continue only if this is SHC." Yellow
}

# --- apply / revert / report -------------------------------------------------
Write-Host "[3/3] $Mode" -NoNewline
Show ""
Show ""

$applied = 0; $reverted = 0; $already = 0; $failed = 0

foreach ($c in $CODES) {
    $cur = Get-Ps3Mem $c.addr 4
    if ($null -eq $cur) {
        Show ("  {0,-38} -> could not read memory at 0x{1}" -f $c.name, $c.addr) Red
        $failed++
        continue
    }

    switch ($Mode) {
        "status" {
            $state = if ($cur -eq $c.hack) { "ON  (patched)" }
                     elseif ($cur -eq $c.orig) { "off (stock)" }
                     else { "??  (unexpected: $cur)" }
            $color = if ($cur -eq $c.hack) { "Green" } elseif ($cur -eq $c.orig) { "Gray" } else { "Yellow" }
            Show ("  {0,-38} 0x{1,-8} = {2}   {3}" -f $c.name, $c.addr, $cur, $state) $color
        }
        "on" {
            if ($cur -eq $c.hack) {
                Show ("  {0,-38} already ON" -f $c.name) DarkGray
                $already++
            } elseif ($cur -eq $c.orig) {
                Set-Ps3Mem $c.addr $c.hack
                Start-Sleep -Milliseconds 300
                $now = Get-Ps3Mem $c.addr 4
                if ($now -eq $c.hack) {
                    Show ("  {0,-38} 0x{1,-8}  {2} -> {3}   ON" -f $c.name, $c.addr, $cur, $now) Green
                    $applied++
                } else {
                    Show ("  {0,-38} write failed ({1} -> {2})" -f $c.name, $cur, $now) Red
                    $failed++
                }
            } else {
                Show ("  {0,-38} unexpected value {1} at 0x{2} - skipped (game/EBOOT different?)" -f $c.name, $cur, $c.addr) Yellow
                $failed++
            }
        }
        "off" {
            if ($cur -eq $c.orig) {
                Show ("  {0,-38} already off" -f $c.name) DarkGray
                $already++
            } elseif ($cur -eq $c.hack) {
                Set-Ps3Mem $c.addr $c.orig
                Start-Sleep -Milliseconds 300
                $now = Get-Ps3Mem $c.addr 4
                if ($now -eq $c.orig) {
                    Show ("  {0,-38} 0x{1,-8}  {2} -> {3}   OFF" -f $c.name, $c.addr, $cur, $now) Green
                    $reverted++
                } else {
                    Show ("  {0,-38} write failed ({1} -> {2})" -f $c.name, $cur, $now) Red
                    $failed++
                }
            } else {
                Show ("  {0,-38} unexpected value {1} at 0x{2} - skipped" -f $c.name, $cur, $c.addr) Yellow
                $failed++
            }
        }
    }
}

Show ""
if ($Mode -eq "on") {
    if ($failed -eq 0) {
        Show ("DONE. {0} applied, {1} already on, 0 failed." -f $applied, $already) Green
        Show "Go back to the game - the cheats are active immediately." Green
    } else {
        Show ("Finished with {0} problem(s).  Read the lines above." -f $failed) Yellow
    }
} elseif ($Mode -eq "off") {
    Show ("DONE. {0} reverted, {1} already off, {2} failed." -f $reverted, $already, $failed) Green
} else {
    Show "Status shown above.  (ON = cheat active)" Cyan
}
Show ""
Show "Reminder: these live in RAM only - re-run Cheats-ON.bat after each game launch." DarkGray
Show ""

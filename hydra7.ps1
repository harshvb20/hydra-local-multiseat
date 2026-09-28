# hydra7.ps1 -- mode 7 cold start, one command.
#
# MODE 7 is mode 6 with the machinery removed.
#
#   sdl-freerdp  --fullscreen on the student's physical panel-->  done.
#
# No virtual display. No session_capture. No shared ring. No mirror. The client
# IS the seat's screen, and it plays the seat's audio itself through its winmm
# rdpsnd backend.
#
# WHY THIS IS ALLOWED NOW. Modes 2-6 are all increasingly elaborate answers to
# one problem: mstsc suppresses output when covered or minimised, so the panel
# froze. `-suppress-output` (added 2026-08-16) solves that directly. A fullscreen
# client on a monitor with nothing else on it is never covered anyway.
#
# The project already knew this. hydra-no-overlay-needed\seats.toml calls
# display_mode="off" plus a fullscreen client "the configuration that actually
# works" -- it was abandoned only because mstsc froze.
#
# UNCHANGED: input isolation and audio are independent of the display path.
# seat_router -> agent:B injects the wireless pair into the session regardless.
#
# USAGE (elevated, from the Hydra Shell)
#   .\hydra7.ps1
#   .\hydra7.ps1 -Monitor 2      # skip auto-detect, use this FreeRDP index
#   .\hydra7.ps1 -Stop

param(
    [int]$Monitor = 0,          # 0 = auto-detect the seat panel
    [switch]$Stop,
    [string]$Seat = 'B',
    [string]$User = 'teacher',
    [switch]$NoAudioPin,
    [string]$Root = 'C:\Programs\hydra'
)

$ErrorActionPreference = 'Continue'
# PS 7.4 made native-command stderr honour ErrorActionPreference. Several tools
# here write PROGRESS to stderr -- hydractl's 'not reachable' while it waits,
# mirror's 'pixel transport opened' -- and 2>&1 under 'Stop' turned those
# SUCCESS lines into terminating errors. This broke hydra-start.ps1 on 2026-08-21.
$PSNativeCommandUseErrorActionPreference = $false
Set-Location $Root
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

# ------------------------------------------- console taskbar on seat panel --
# Windows only hides a taskbar behind a fullscreen window while that window is
# in the foreground. In mode 7 the teacher works on the laptop, so the console's
# secondary taskbar sat on top of the seat's screen, above seat B's own taskbar.
# Off while the seat is up, back on at -Stop.
# HKCU: run elevated from the SAME account, or this edits the wrong hive.
$mmKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
# PID of the explorer that owns THIS session's taskbar. FindWindow only sees
# the calling session, so seat B's shell can never match.
# Removes a window's taskbar button (ITaskbarList::DeleteTab). A fresh COM
# object per call, so it always reaches the explorer running NOW -- no stale
# binding like the VirtualDesktop module has.
if (-not ('HydraTaskbar' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITaskbarList {
    void HrInit();
    void AddTab(IntPtr hwnd);
    void DeleteTab(IntPtr hwnd);
    void ActivateTab(IntPtr hwnd);
    void SetActiveAlt(IntPtr hwnd);
}
[ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
class CTaskbarList { }
public static class HydraTaskbar {
    public static void Hide(IntPtr hwnd) {
        ITaskbarList t = (ITaskbarList)new CTaskbarList();
        try { t.HrInit(); t.DeleteTab(hwnd); }
        finally { Marshal.ReleaseComObject(t); }
    }
}
'@
}
if (-not ('HydraShellWin' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HydraShellWin {
    [DllImport("user32.dll")] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static int TrayPid() {
        IntPtr h = FindWindow("Shell_TrayWnd", null);
        if (h == IntPtr.Zero) return 0;
        uint pid; GetWindowThreadProcessId(h, out pid);
        return (int)pid;
    }
}
'@
}
function Set-ConsoleTaskbarOnAllDisplays([bool]$On) {
    $want = [int]$On
    $have = (Get-ItemProperty $mmKey -Name MMTaskbarEnabled -EA SilentlyContinue).MMTaskbarEnabled
    if ($null -eq $have) { $have = 1 }      # absent = Windows default = on
    if ($have -eq $want) { return }         # no change, no explorer restart
    Set-ItemProperty `
        -Path $mmKey `
        -Name 'MMTaskbarEnabled' `
        -Value $want `
        -Type DWord
    # Folder windows in their own process, so killing the shell spares them.
    # Explorer reads this at start: the FIRST restart after it is set still
    # takes open folder windows with it. Every restart after that leaves them.
    if ((Get-ItemProperty $mmKey -Name SeparateProcess -EA SilentlyContinue).SeparateProcess -ne 1) {
        Set-ItemProperty `
            -Path $mmKey `
            -Name 'SeparateProcess' `
            -Value 1 `
            -Type DWord
        Say "  folder windows set to a separate process (open ones close this once)" Yellow
    }
    # Kill ONLY the shell: the explorer that owns this session's taskbar.
    # Not seat B's shell (other session), not the folder-window process.
    $old = [HydraShellWin]::TrayPid()
    if ($old) { Stop-Process -Id $old -Force }
    # Wait for a NEW taskbar, then let it settle. Virtual desktops live in the
    # shell; a window created while it is still starting can lose its pin.
    # (A surviving folder-window explorer means "any explorer running" is no
    # longer proof the shell is back -- hence the tray check.)
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep 1
        $now = [HydraShellWin]::TrayPid()
        if ($now -and $now -ne $old) { break }
    }
    if (-not [HydraShellWin]::TrayPid()) { Start-Process explorer }
    Start-Sleep 4
    Say "  console taskbar on all displays: $(if ($On) { 'on' } else { 'off' })" DarkGray
}

# ---------------------------------------------------------------- stop -----
function Stop-Everything {
    Say "stopping ..." Cyan
    Get-Process mirror, hydrardp, sdl-freerdp, mstsc, cursor_overlay -EA SilentlyContinue | Stop-Process -Force
    Stop-Service Hydra -EA SilentlyContinue
    Start-Sleep 2
    $t = query session | Select-String $User
    if ($t) {
        $sid = ($t.ToString().Trim() -split '\s+' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
        # A merely DISCONNECTED session is held by RDP-Wrapper and only a reboot
        # clears it. Log it off properly.
        if ($sid) { Say "  logging off $User session $sid" Yellow; logoff $sid 2>$null }
    }
    Say "stopped." Green
}

if ($Stop) { Stop-Everything; Set-ConsoleTaskbarOnAllDisplays $true; return }
Stop-Everything
Say ""

# ---------------------------------------------------------- preconditions --
if ((& sc.exe qc TermService | Out-String) -notmatch 'WIN32_OWN_PROCESS') {
    Say "TermService is not type= own. RDP-Wrapper's ServiceDll will not load," Red
    Say "you get ONE session, and it shows up as ERRCONNECT_ACTIVATION_TIMEOUT." Red
    Say "  sc.exe config TermService type= own      (then reboot)" Red
    return
}

$dm = (Select-String -Path "$Root\dist\seats.toml" -Pattern '^display_mode' | Select-Object -First 1).Line
if ($dm -notmatch '"off"') {
    Say "display_mode is not `"off`" -- currently: $dm" Yellow
    Say "Mode 7 needs it off, or hydrad launches a capture agent that nothing reads." Yellow
    Say "  (Get-Content seats.toml -Raw) -replace '(?m)^display_mode = `".*`"', 'display_mode = `"off`"' | Set-Content seats.toml -NoNewline" Yellow
    Say "  .\setup.ps1" Yellow
    return
}

# ------------------------------------------------------------- service -----
# Still needed: it runs seat_router and agent:B, which are what actually give
# the student their keyboard and mouse.
# --- termsrv preflight (see tools\termsrv-guard) -------------------------
# Fail fast with the real cause instead of a seat that times out or is
# logged off ten seconds in.
$tsFlag = Join-Path $PSScriptRoot 'state\termsrv-UNPATCHED'
if (Test-Path $tsFlag) {
    Write-Host "termsrv.dll is NOT patched (build $(Get-Content $tsFlag -Raw)) -- seat B would be logged off." -ForegroundColor Red
    Write-Host 'See tools\termsrv-guard\README.md, "Adding a pattern".' -ForegroundColor Red
    exit 1
}
$tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
if ((Get-ItemProperty $tsKey).fDenyTSConnections -eq 1) {
    Write-Host 'Remote Desktop is switched off (fDenyTSConnections=1) -- see INSTALL.md, termsrv-guard section.' -ForegroundColor Red
    exit 1
}
if ((Get-Service TermService).Status -ne 'Running') {
    Write-Host 'TermService not running -- starting it ...'
    Start-Service TermService
}
# --- end termsrv preflight -----------------------------------------------
# Console taskbar off the seat panel. After the preflight, so a failed
# preflight does not leave it switched off. Before the service so explorer has the
# service start and audio pin to finish restarting before the client window
# exists -- a window born into a half-started explorer can lose its pin.
Set-ConsoleTaskbarOnAllDisplays $false

Say "starting Hydra service ..." Cyan
Start-Service Hydra
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep 1
    if ((& "$Root\dist\hydractl.exe" status 2>&1 | Out-String) -notmatch 'not reachable') { break }
}

# ----------------------------------------------------------- audio pin -----
# MUST run BEFORE the client starts -- a per-app output change will not take on
# an audio stream that is already open (audio-pin.ps1 line 23).
#
# In mode 7 the CLIENT plays the seat's audio, through FreeRDP's winmm rdpsnd
# backend, into the console session. audio_bridge is not involved and abren will
# sit at "waiting for the shared ring" -- that is expected, not a fault.
if (-not $NoAudioPin -and (Test-Path "$Root\audio-pin.ps1")) {
    Say "applying audio pin ..." Cyan
    try { & "$Root\audio-pin.ps1" -Apply -App 'sdl-freerdp.exe' | Out-Null }
    catch { Say "  audio-pin failed: $_" Yellow }
}

# -------------------------------------------------------- monitor index ----
# FreeRDP's own 1-based enumeration, NOT the Windows DISPLAY number, and it
# shifts between boots. Auto-detect: the seat panel is the entry that is neither
# primary (marked *) nor the virtual display.
$mon = & "$Root\dist\freerdp\sdl-freerdp.exe" /list:monitor 2>&1 | Out-String
$lines = $mon -split "`r?`n"
if ($Monitor -eq 0) {
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(\d+)\]\s+\[([^\]]+)\]' -and $line -notmatch '^\s*\*' -and $Matches[2] -notmatch 'VDD') {
            $Monitor = [int]$Matches[1]
            Say "seat panel: FreeRDP monitor $Monitor  [$($Matches[2])]" Green
            break
        }
    }
}
if ($Monitor -eq 0) {
    Say "could not identify the seat panel. Pick one and pass -Monitor <n>:" Red
    Write-Host $mon
    return
}

# ------------------------------------------------------------- client ------
# /sound            REQUIRED. Without it there is no audio channel at all.
# -suppress-output  the flag mode 7 rests on -- the client keeps pulling frames
#                   regardless of what it thinks is visible.
# /scale:140        session DPI, so the seat's UI is readable at 1:1.
# /d:               login focus on the password field, not the domain field.
# /f /monitors:N    fullscreen on the seat's panel. This IS the seat's display.
Say ""
Say "starting the client fullscreen on the seat panel -- LOG IN AS $User" Cyan
Say "  (echo is off; a typo shows as ERRCONNECT_LOGON_FAILURE)" DarkGray
Say "  its log stays open in the new window -- that is where connection errors" DarkGray
Say "  and codec warnings appear. Leave it open." DarkGray

# Launched inside a -NoExit PowerShell window rather than detached, so its
# output is READABLE. Start-Process on the exe directly swallows everything --
# no ERRCONNECT reason, no rdpsnd backend line, no codec warnings. Same approach
# hydra-view.ps1 uses for hydrardp.
$clientArgs = "/v:127.0.0.2 /u:$User /d: /cert:ignore /sound -suppress-output /scale:140 +auto-reconnect /gfx:rfxc /network:lan /f /monitors:$Monitor"
$cmd = "`$host.UI.RawUI.WindowTitle = 'Hydra seat $Seat -- client log'; " +
       "& '$Root\dist\freerdp\sdl-freerdp.exe' $clientArgs"
Start-Process powershell -WindowStyle Minimized -ArgumentList '-NoExit', '-Command', $cmd

Say "waiting for the seat session ..." Yellow
$ok = $false
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep 2
    if ((& query session | Out-String) -match "$User\s+\d+\s+Active") { $ok = $true; break }
}
if (-not $ok) { Say "no $User session after 3 minutes." Red; return }
Say "seat session up." Green

# -------------------------------------------------------------- pin --------
# A fullscreen client belongs to the virtual desktop it was launched from, and
# virtual desktops span all monitors -- so switching away hides the seat's
# screen from the student. Pinning puts it on every desktop.
#
# The pin runs in a FRESH PowerShell process every time. The VirtualDesktop
# module binds to explorer's COM objects once, when it first loads, and keeps
# them for the life of the process. After explorer restarts (the taskbar
# toggle, -Stop, a crash), a shell that already loaded the module is talking
# to a dead explorer and every pin silently fails. A child process always binds
# to the explorer that is running now.
Start-Sleep 3
$pinScript = {
    param([long]$hwnd)
    try {
        Import-Module -Name VirtualDesktop -DisableNameChecking -EA Stop
        Pin-Window -Hwnd ([IntPtr]$hwnd) | Out-Null
        if (Test-WindowPinned -Hwnd ([IntPtr]$hwnd)) { exit 0 }
        'pin call returned but Test-WindowPinned says no'
        exit 1
    } catch { "$_"; exit 2 }
}
$psExe = (Get-Process -Id $PID).Path
$pinned = $false
$pinMsg = 'no client window found'
for ($i = 1; $i -le 10 -and -not $pinned; $i++) {
    $h = (Get-Process sdl-freerdp -EA SilentlyContinue |
        Where-Object MainWindowHandle -ne 0 |
        Select-Object -First 1).MainWindowHandle
    if ($h) {
        $pinMsg = & $psExe -NoProfile -Command $pinScript -args $h.ToInt64() 2>&1 | Out-String
        $pinned = ($LASTEXITCODE -eq 0)
    }
    if (-not $pinned) { Start-Sleep 2 }
}
if ($pinned) {
    Say "client pinned to all virtual desktops" Green
} else {
    Say "  client NOT pinned after 10 tries: $($pinMsg.Trim())" Yellow
    Say "  if the panel goes blank when you switch virtual desktops, that is why." Yellow
}

# ------------------------------------------------------ taskbar button ------
# With the console taskbar off the seat panel, the client's button lands on the
# laptop's taskbar -- on every virtual desktop, since it is pinned. The teacher
# never needs it: the seat is reached by moving the cursor onto its panel.
# The client LOG window keeps its button; that one is useful.
$h = (Get-Process sdl-freerdp -EA SilentlyContinue |
    Where-Object MainWindowHandle -ne 0 |
    Select-Object -First 1).MainWindowHandle
if ($h) {
    try   { [HydraTaskbar]::Hide($h); Say "client taskbar button removed" Green }
    catch { Say "  could not remove the client taskbar button: $_" Yellow }
}

# ------------------------------------------------------------- verify ------
Start-Sleep 2
Say ""
$st = & "$Root\dist\hydractl.exe" status 2>&1 | Out-String
Write-Host $st -ForegroundColor DarkGray
if ($st -match 'capture:B') {
    Say "capture:B is running -- display_mode is not off. Harmless but wasteful." Yellow
}
Say "expected in mode 7: router, agent:B, abcap:B, abren:B -- and NO capture:B" DarkGray

Say ""
Say "The student's wireless keyboard and mouse drive seat $Seat directly." Cyan
Say "No window, no focus, no virtual desktop involved." DarkGray

# Mouse button swap is PER USER, and seat B runs as a different account -- so a
# left-handed console does not make seat B left-handed. Crossing onto the seat's
# panel silently flips the buttons back, which is disorienting mid-lesson.
$mineSwapped = (Get-ItemProperty 'HKCU:\Control Panel\Mouse' SwapMouseButtons -EA SilentlyContinue).SwapMouseButtons
if ($mineSwapped -eq '1') {
    Say ""
    Say "NOTE: your console mouse is left-handed. Seat $Seat is a separate user," Yellow
    Say "so it has its own setting. If the buttons flip when you cross onto the" Yellow
    Say "seat's panel, set it once INSIDE the seat:" Yellow
    Say "  Settings > Bluetooth & devices > Mouse > Primary mouse button: Right" DarkGray
    Say "It persists in $User's profile after that." DarkGray
}
Say ""
Say "To reach seat $Seat yourself, move your cursor onto its panel." DarkGray
Say ""
Say "Stop:   .\hydra7.ps1 -Stop" Cyan
Say "Panic:  type  Stop-Service Hydra  and press Enter (works blind)" DarkGray

# --------------------------------------------------------- audio note ------
$pin = Get-Content "$Root\audio-pin.json" -Raw -EA SilentlyContinue
if ($pin -and $pin -notmatch 'intcdaud') {
    Say ""
    Say "AUDIO PIN IS NOT SET TO THE MONITOR." Yellow
    Say "audio-pin.json names no intcdaud entry, so seat $Seat's sound follows the" Yellow
    Say "console's output device. Fix it ONCE:" Yellow
    Say "  1. play something in seat $Seat" DarkGray
    Say "  2. Settings > Sound > Volume mixer > sdl-freerdp.exe" DarkGray
    Say "     > Output device > 2770 (Intel Display Audio)" DarkGray
    Say "  3. Remove-Item $Root\audio-pin.json -Force" DarkGray
    Say "  4. .\audio-pin.ps1 -Save -App 'sdl-freerdp.exe'" DarkGray
    Say "One entry naming intcdaud means it is right. -Apply then restores it" DarkGray
    Say "on every launch, before the client opens its stream." DarkGray
}

#Requires -Version 7.0
<#
.SYNOPSIS
    Elevated build daemon: trades one UAC prompt per build for one per session.

.DESCRIPTION
    windhawk-cli runs the bundled clang in-process as the calling user, so it
    needs Administrator rights to write the built DLLs. Prompting for that on
    every Ctrl+Shift+B gets old fast. This holds a single elevated process open
    and feeds it build requests over the file queue described in wh-ipc.ps1.

    SECURITY -- read this before enabling it.

    While the daemon is up, any process running as you can queue a build without
    a consent prompt. That is a local privilege escalation, and it is inherent
    rather than a flaw in this implementation: the elevated step compiles source
    from a directory you can write to unelevated, and installs the result as a
    DLL that Windhawk injects into other processes. No amount of request
    validation closes that, because an attacker who can write mods/ or build/ is
    already inside the trust boundary.

    What is actually bounded is the window. The daemon holds no persistent state,
    registers nothing, survives no reboot, and exits on its own after IdleMinutes
    of quiet. The requests it accepts are structured -- a bundle path, an arch,
    and a disabled flag -- so a request can only ever mean "install this bundle",
    never "run this command". The path containment check below is hygiene against
    accidents, not a security boundary; do not mistake it for one.

    Stop it with -Stop when you are done working, and the window closes.

.PARAMETER Serve
    Run the loop. Requires elevation; this is what the elevated relaunch passes.

.PARAMETER Stop
    Ask a running daemon to exit. Unelevated.

.PARAMETER Status
    Report whether a daemon is up, and since when. Unelevated.

.PARAMETER IdleMinutes
    Exit after this long without a request. Default 240.

.EXAMPLE
    .\scripts\wh-daemon.ps1            # start it (prompts once)

.EXAMPLE
    .\scripts\wh-daemon.ps1 -Status
#>
[CmdletBinding()]
param(
    [switch]$Serve,
    [switch]$Stop,
    [switch]$Status,
    [int]$IdleMinutes = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'wh-ipc.ps1')

$Ipc = Get-WhIpc

# ------------------------------------------------------------ unelevated verbs

if ($Status) {
    if (Test-WhDaemonAlive $Ipc) {
        $info = Get-WhDaemonInfo $Ipc
        if ($info) {
            # Epoch seconds, not an ISO string: ConvertFrom-Json silently turns
            # an ISO-8601 field back into a local-kind [datetime], and parsing
            # that again applies the UTC offset a second time.
            $up = [timespan]::FromSeconds(
                [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $info.startedUnix)
            Write-Host ("Daemon running: pid {0}, up {1:hh\:mm\:ss}, idle timeout {2} min" -f
                $info.pid, $up, $info.idleMinutes) -ForegroundColor Green
        } else {
            Write-Host 'Daemon running (no metadata).' -ForegroundColor Green
        }
    } else {
        Write-Host 'No daemon running.' -ForegroundColor DarkGray
    }
    return
}

if ($Stop) { Stop-WhDaemon $Ipc; return }

if (-not $Serve) {
    if (Start-WhDaemon -Ipc $Ipc -IdleMinutes $IdleMinutes) { return }
    exit 1
}

# ------------------------------------------------------------------- the loop

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    throw '-Serve requires an elevated session. Run without -Serve to elevate.'
}

# Resolved inside the elevated process rather than passed in from the client:
# an argument would be one more thing a request could try to influence.
. (Join-Path $PSScriptRoot 'wh-windhawk.ps1')
$Cli = Get-WhCliPath

$BuildRoot = [IO.Path]::GetFullPath((Join-Path $Ipc.Repo 'build'))

# Single-instance guard and the client's liveness signal are the same lock: a
# second daemon cannot take it and bails out here.
try {
    $lock = [IO.File]::Open($Ipc.Lock, [IO.FileMode]::OpenOrCreate,
                            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch [IO.IOException] {
    Write-Host 'Another daemon already holds the lock; exiting.' -ForegroundColor Yellow
    exit 0
}

[pscustomobject]@{
    pid         = $PID
    startedUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    idleMinutes = $IdleMinutes
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $Ipc.Meta -NoNewline

$Host.UI.RawUI.WindowTitle = 'Windhawk: Elevated Build Daemon'
Write-Host '======================================================================================' -ForegroundColor DarkGray
Write-Host '                               Windhawk Build Daemon' -ForegroundColor Cyan
Write-Host '======================================================================================' -ForegroundColor DarkGray
Write-Host ''
Write-Host " Repository Path     : " -NoNewline
Write-Host "$($Ipc.Repo)" -ForegroundColor Yellow
Write-Host " Daemon Idle Timeout : " -NoNewline
Write-Host "$IdleMinutes Minutes" -ForegroundColor Yellow
Write-Host ''
Write-Host ' While this daemon is running, UAC prompts will not be required'
Write-Host ' to compile -> install -> enable Windhawk mods as you work and iterate'
Write-Host ' on them (assuming you are utilizing the VS Code build tasks setup for development).'
Write-Host ''
Write-Host ' Close this window (or run `wh-daemon.ps1 -Stop`) when you finish working, and'
Write-Host ' the UAC "pre-approval" for Windhawk compilation/installation/enablement'
Write-Host ' will get invalidated -> manual UAC prompt approval will be required again.'
Write-Host ''
Write-Host '======================================================================================' -ForegroundColor DarkGray
Write-Host ''

function Invoke-Request {
    param([Parameter(Mandatory)][string]$ReqPath)

    $id   = [IO.Path]::GetFileNameWithoutExtension($ReqPath)
    $log  = Join-Path $Ipc.Dir "$id.log"
    $done = Join-Path $Ipc.Dir "$id.done"
    $code = 1

    try {
        $r = Get-Content -LiteralPath $ReqPath -Raw | ConvertFrom-Json

        # Hygiene, not a boundary (see the header): keeps a malformed or
        # mistyped request from handing windhawk-cli something unrelated.
        $bundle = [IO.Path]::GetFullPath($r.bundle)
        if (-not $bundle.StartsWith($BuildRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "refusing a bundle outside $BuildRoot`: $bundle"
        }
        if ($bundle -notlike '*.wh.cpp') { throw "not a .wh.cpp: $bundle" }
        if (-not (Test-Path -LiteralPath $bundle)) { throw "no such bundle: $bundle" }

        $arch = if ($r.arch -in @('auto', 'x64', 'arm64', 'all')) { $r.arch } else { 'auto' }

        $cliArgs = @('mod', 'install', '--file', $bundle, '--arch', $arch)
        if ($r.disabled) { $cliArgs += '--disabled' }
        
        $BundleBeginTimestamp = [datetime]::Now
        Write-Host ''
        Write-Host ("[{0:HH:mm:ss}] " -f [datetime]::Now) -NoNewline -ForegroundColor DarkGray
        Write-Host ('Compiling and installing ') -ForegroundColor White -NoNewline
        Write-Host ('{0}' -f (Split-Path -Leaf $bundle)) -ForegroundColor Cyan

        $writer = [IO.StreamWriter]::new($log, $true, [Text.UTF8Encoding]::new($false))
        $writer.AutoFlush = $true
        try {
            & $Cli @cliArgs 2>&1 | ForEach-Object { $writer.WriteLine([string]$_) }
            $code = $LASTEXITCODE
        } finally {
            $writer.Dispose()
        }

        $BundleEndTimestamp = [datetime]::Now

        $BenchmarkTime = ($BundleEndTimestamp - $BundleBeginTimestamp).TotalSeconds

        Write-Host ("[{0:HH:mm:ss}] " -f [datetime]::Now) -NoNewline -ForegroundColor DarkGray
        Write-Host ("Exit code: {0}" -f $code) -ForegroundColor $(
            if ($code -eq 0) { 'Green' } else { 'Red' })

        # duration that it generally took to complete
        Write-Host ("[{0:HH:mm:ss}] " -f [datetime]::Now) -NoNewline -ForegroundColor DarkGray
        Write-Host ("Benchmark: {0}" -f $(
            if ($BenchmarkTime -gt 60) { '{0}m{1}s' -f ([math]::Floor($BenchmarkTime / 60)), [math]::Floor($BenchmarkTime - ([math]::Floor($BenchmarkTime / 60)) * 60) } else { '{0:F2}s' -f ($BenchmarkTime) }
        )) -ForegroundColor Gray
    } catch {
        Add-Content -LiteralPath $log -Value "daemon: $($_.Exception.Message)" -Encoding utf8NoBOM
        Write-Host "[ERROR]" -ForegroundColor DarkRed -NoNewline
        Write-Host " $($_.Exception.Message)" -ForegroundColor Red
        $code = 1
    } finally {
        # Written last: the client treats a non-empty .done as "build finished".
        Set-Content -LiteralPath $done -Value $code -NoNewline
        Remove-Item -LiteralPath $ReqPath -ErrorAction SilentlyContinue
    }
}

$idleUntil = [datetime]::UtcNow.AddMinutes($IdleMinutes)
try {
    while ($true) {
        if (Test-Path -LiteralPath $Ipc.Stop) {
            Remove-Item -LiteralPath $Ipc.Stop -ErrorAction SilentlyContinue
            Write-Host 'Stop requested.' -ForegroundColor Yellow
            break
        }

        # Polled rather than FileSystemWatcher-driven: at 120 ms the latency is
        # invisible next to a multi-second compile, and there is no event queue
        # to overflow or resubscribe after an error.
        $reqs = @(Get-ChildItem -LiteralPath $Ipc.Dir -Filter '*.req' -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -ne 'stop.req' } | Sort-Object CreationTimeUtc)

        if ($reqs.Count) {
            foreach ($req in $reqs) { Invoke-Request $req.FullName }
            $idleUntil = [datetime]::UtcNow.AddMinutes($IdleMinutes)
            continue
        }

        if ([datetime]::UtcNow -ge $idleUntil) {
            Write-Host "Idle for $IdleMinutes minutes; exiting." -ForegroundColor Yellow
            break
        }
        Start-Sleep -Milliseconds 120
    }
} finally {
    $lock.Dispose()
    Remove-Item -LiteralPath $Ipc.Meta -ErrorAction SilentlyContinue
}

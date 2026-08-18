#Requires -Version 7.0
<#
.SYNOPSIS
    Shared client/server plumbing for the elevated build daemon. Dot-sourced by
    wh-install.ps1 and wh-daemon.ps1; not useful on its own.

.DESCRIPTION
    The daemon exists so a work session costs one UAC prompt instead of one per
    build. It runs elevated and takes build requests from the unelevated editor
    over a file-drop queue in build/.ipc.

    A file queue rather than a named pipe, because of Windows integrity levels.
    A pipe created by an elevated (High IL) process carries a High mandatory
    label, and the default NO_WRITE_UP policy stops a Medium IL client from
    writing to it -- which is exactly the direction requests need to travel.
    Getting around that means hand-building a security descriptor with a lowered
    SACL label, which .NET's PipeSecurity does not reliably round-trip.

    Instead every file in a transaction is created by the *unelevated* client, so
    all of them carry Medium labels. Writing down from High is always permitted,
    so the daemon can fill them in; the client owns them and can clean them up.
    No labels to manipulate, no privileges beyond the one elevation.

    Transaction layout, all keyed on one GUID:

        <id>.log    client creates empty; daemon appends build output live
        <id>.done   client creates empty; daemon writes the exit code last
        <id>.req    client writes last, by atomic rename, so the daemon never
                    observes a request whose response files are missing

    Liveness is a lock file the client creates and the daemon holds open with
    FileShare.None. A sharing violation means a daemon is up. That doubles as the
    single-instance guard: a second daemon fails to take the lock and exits.
#>

Set-StrictMode -Version Latest

$script:WhClientTimeoutSec = 900   # a cold taskbar-styler build is minutes, not seconds
$script:WhReadyTimeoutSec  = 60
$script:WhStdinAs          = $null

function Get-WhIpc {
    $repo = Split-Path -Parent $PSScriptRoot
    $dir  = Join-Path $repo 'build\.ipc'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [pscustomobject]@{
        Repo = $repo
        Dir  = $dir
        Lock = Join-Path $dir 'daemon.lock'
        Meta = Join-Path $dir 'daemon.json'
        Stop = Join-Path $dir 'stop.req'
    }
}

# The daemon's process object is High IL, so an unelevated Stop-Process on it is
# a write-up and gets denied. Liveness has to be inferred from the lock instead.
function Test-WhDaemonAlive {
    param([Parameter(Mandatory)] $Ipc)

    if (-not (Test-Path -LiteralPath $Ipc.Lock)) { return $false }
    try {
        $fs = [IO.File]::Open($Ipc.Lock, [IO.FileMode]::Open,
                              [IO.FileAccess]::Read, [IO.FileShare]::None)
        $fs.Dispose()
        return $false          # took it exclusively, so nobody is holding it
    } catch [IO.IOException] {
        return $true           # sharing violation: the daemon has it open
    } catch {
        return $false
    }
}

function Get-WhDaemonInfo {
    param([Parameter(Mandatory)] $Ipc)
    if (-not (Test-Path -LiteralPath $Ipc.Meta)) { return $null }
    try { Get-Content -LiteralPath $Ipc.Meta -Raw | ConvertFrom-Json } catch { $null }
}

function Start-WhDaemon {
    param(
        [Parameter(Mandatory)] $Ipc,
        [int]$IdleMinutes = 240
    )

    if (Test-WhDaemonAlive $Ipc) { return $true }

    # Created here, unelevated, so the daemon inherits a Medium-labelled file it
    # can hold but the client can still probe and replace.
    if (-not (Test-Path -LiteralPath $Ipc.Lock)) {
        Set-Content -LiteralPath $Ipc.Lock -Value 'wh-daemon' -NoNewline
    }
    Remove-Item -LiteralPath $Ipc.Stop -ErrorAction SilentlyContinue

    $daemon = Join-Path $PSScriptRoot 'wh-daemon.ps1'
    Write-Host '==> starting elevated build daemon (one prompt for this session)' -ForegroundColor Cyan

    try {
        Start-Process pwsh -Verb RunAs -WindowStyle Minimized -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $daemon, '-Serve', '-IdleMinutes', $IdleMinutes
        ) | Out-Null
    } catch {
        Write-Host 'Elevation was declined -- falling back to a per-build prompt.' -ForegroundColor Yellow
        return $false
    }

    $deadline = [datetime]::UtcNow.AddSeconds($script:WhReadyTimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-WhDaemonAlive $Ipc) {
            Write-Host '==> daemon ready' -ForegroundColor Green
            return $true
        }
        Start-Sleep -Milliseconds 150
    }

    Write-Host 'Daemon did not come up in time.' -ForegroundColor Yellow
    return $false
}

function Stop-WhDaemon {
    param([Parameter(Mandatory)] $Ipc)

    if (-not (Test-WhDaemonAlive $Ipc)) {
        Write-Host 'No daemon running.' -ForegroundColor DarkGray
        return
    }
    # Cooperative: terminating it outright would be a write-up.
    Set-Content -LiteralPath $Ipc.Stop -Value 'stop' -NoNewline

    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while ([datetime]::UtcNow -lt $deadline) {
        if (-not (Test-WhDaemonAlive $Ipc)) {
            Write-Host '==> daemon stopped' -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 150
    }
    Write-Host 'Daemon did not acknowledge the stop request.' -ForegroundColor Yellow
}

<#
    Hands one build to the daemon and mirrors its output as it arrives, so a
    daemon build looks the same in the terminal as an inline one. Returns the
    compiler's exit code, or $null if the daemon never answered -- the caller
    treats that as "fall back to elevating this one build".
#>
function Invoke-WhDaemonBuild {
    param(
        [Parameter(Mandatory)] $Ipc,
        [Parameter(Mandatory)] [string]$Bundle,
        [string]$Arch = 'auto',
        [switch]$Disabled,
        [string]$StdinAs
    )

    # windhawk-cli pipes the source to clang, so anything the bundle's #line
    # directives do not cover is blamed on '<stdin>'. Same rewrite the inline
    # path does, applied as lines stream past.
    $script:WhStdinAs = $StdinAs

    $id   = [guid]::NewGuid().ToString('n')
    $log  = Join-Path $Ipc.Dir "$id.log"
    $done = Join-Path $Ipc.Dir "$id.done"
    $req  = Join-Path $Ipc.Dir "$id.req"
    $tmp  = Join-Path $Ipc.Dir "$id.tmp"

    # Response files first: the daemon must never see a request it cannot answer.
    New-Item -ItemType File -Path $log  -Force | Out-Null
    New-Item -ItemType File -Path $done -Force | Out-Null

    # Structured fields, not a command line. The daemon builds the argument list
    # itself so a request can only ever mean "install this bundle".
    $payload = [pscustomobject]@{
        bundle   = $Bundle
        arch     = $Arch
        disabled = [bool]$Disabled
    } | ConvertTo-Json -Compress

    Set-Content -LiteralPath $tmp -Value $payload -NoNewline
    Move-Item -LiteralPath $tmp -Destination $req   # atomic on one volume

    $offset   = 0L
    $exit     = $null
    $deadline = [datetime]::UtcNow.AddSeconds($script:WhClientTimeoutSec)

    try {
        while ([datetime]::UtcNow -lt $deadline) {
            $offset = Write-WhLogTail -Path $log -Offset $offset

            $code = Read-WhDoneCode -Path $done
            if ($null -ne $code) {
                $offset = Write-WhLogTail -Path $log -Offset $offset   # drain the tail
                $exit = $code
                break
            }

            if (-not (Test-WhDaemonAlive $Ipc)) {
                Write-Host 'Daemon went away mid-build.' -ForegroundColor Yellow
                break
            }
            Start-Sleep -Milliseconds 120
        }
    } finally {
        # Client-created, Medium-labelled, so the client can always clean up.
        Remove-Item -LiteralPath $log, $done, $req, $tmp -ErrorAction SilentlyContinue
    }

    if ($null -eq $exit) { Write-Host 'Daemon build timed out.' -ForegroundColor Yellow }
    return $exit
}

function Write-WhLogTail {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$Offset)

    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open,
                              [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    } catch { return $Offset }

    try {
        if ($fs.Length -le $Offset) { return $Offset }
        $fs.Position = $Offset
        $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false))
        $chunk = $sr.ReadToEnd()
        $new = $Offset + [Text.Encoding]::UTF8.GetByteCount($chunk)
        foreach ($line in ($chunk -split "`r?`n")) {
            if ($line -ne '') { Write-WhBuildLine $line }
        }
        return $new
    } catch {
        return $Offset
    } finally {
        $fs.Dispose()
    }
}

function Read-WhDoneCode {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $raw = [IO.File]::ReadAllText($Path).Trim()
        if ($raw) { return [int]$raw }
    } catch { }
    return $null
}

function Write-WhBuildLine {
    param([Parameter(Mandatory)][string]$Line)
    if ($script:WhStdinAs) { $Line = $Line.Replace('<stdin>', $script:WhStdinAs) }
    if ($Line -match ':\d+:\d+:\s+(error|fatal error):' -or $Line -match '^error:') {
        Write-Host $Line -ForegroundColor Red
    } elseif ($Line -match ':\d+:\d+:\s+warning:') {
        Write-Host $Line -ForegroundColor Yellow
    } else {
        Write-Host $Line
    }
}

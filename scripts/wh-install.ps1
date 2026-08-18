#Requires -Version 7.0
<#
.SYNOPSIS
    Bundle, compile, and install a Windhawk mod from this repo.

.DESCRIPTION
    Windhawk's own directories (C:\ProgramData\Windhawk) are read-only for
    BUILTIN\Users, so ModsSource cannot be edited by a normal editor. This
    script inverts the relationship: the repo holds the source of truth, and
    `windhawk-cli mod install --file` pushes it into Windhawk, which compiles
    it, registers it, and hot-reloads it into running processes.

    Mods live as folders under mods/, so the first step is wh-amalgamate.ps1,
    which flattens mods/<name>/src/main.wh.cpp and its quoted includes into the
    single translation unit Windhawk requires. What gets installed is always the
    generated bundle in build/.

    windhawk-cli runs the bundled clang in-process as the calling user rather
    than delegating to the SYSTEM service, so it needs Administrator rights to
    write the built DLLs. This script elevates only that one command.

.PARAMETER Path
    What to build: a mod name, a mod folder, or any file inside one -- pass
    ${file} from an editor task and the enclosing mod is worked out. A file
    outside every mod (a shared/ header, say) rebuilds the last mod built.

.PARAMETER NoBundle
    Install Path verbatim, skipping amalgamation. For a pre-bundled .wh.cpp.

.PARAMETER Arch
    Target architectures, forwarded to windhawk-cli --arch.

.PARAMETER Enable
    Force the mod enabled after install. Default preserves its current state.

.PARAMETER Disabled
    Force the mod disabled after install. Default preserves its current state.

.PARAMETER NoElevate
    Skip the UAC round-trip. Use when the shell is already elevated.

.PARAMETER NoDaemon
    Always prompt for this build rather than using (or starting) the elevated
    build daemon. See wh-daemon.ps1 for what the daemon costs you in exchange
    for the quiet.

.PARAMETER IdleMinutes
    Idle timeout handed to the daemon if this build is the one that starts it.

.EXAMPLE
    .\scripts\wh-install.ps1 local@windows-animations-fork

.EXAMPLE
    .\scripts\wh-install.ps1 .\mods\local@windows-animations-fork\src\main.wh.cpp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Path,

    [ValidateSet('auto', 'x64', 'arm64', 'all')]
    [string]$Arch = 'auto',

    [switch]$Enable,
    [switch]$Disabled,
    [switch]$NoBundle,
    [switch]$NoElevate,
    [switch]$NoDaemon,
    [int]$IdleMinutes = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Enable -and $Disabled) {
    throw '-Enable and -Disabled are mutually exclusive.'
}

. (Join-Path $PSScriptRoot 'wh-windhawk.ps1')
$Cli = Get-WhCliPath

if ($NoBundle) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No such file: $Path"
    }
    $src = (Resolve-Path -LiteralPath $Path).Path
    if ($src -notlike '*.wh.cpp') {
        throw "Not a Windhawk mod source (expected *.wh.cpp): $src"
    }
} else {
    # Progress from the bundler goes to the host; only the path comes back here.
    $src = & (Join-Path $PSScriptRoot 'wh-amalgamate.ps1') -Mod $Path -AllowFallback
}

# Windhawk prefixes file-installed mods with 'local@', so the id inside the
# file is bare while the installed id is namespaced.
$idMatch = Select-String -LiteralPath $src -Pattern '^\s*//\s*@id\s+(\S+)' | Select-Object -First 1
if (-not $idMatch) {
    throw "No '// @id' line found in $src -- is the ==WindhawkMod== header intact?"
}
$bareId = $idMatch.Matches[0].Groups[1].Value
$modId = "local@$bareId"

# Current install state, so a rebuild doesn't silently flip a disabled mod on.
$installed = $null
try {
    $listed = (& $Cli mod list --json 2>$null | ConvertFrom-Json).data.mods
    $installed = $listed | Where-Object { $_.id -eq $modId } | Select-Object -First 1
    if (-not $installed) {
        $upstream = $listed | Where-Object { $_.id -eq $bareId } | Select-Object -First 1
        if ($upstream) {
            Write-Warning "'$bareId' is installed as an upstream mod. Building from file creates a separate fork '$modId' and leaves the upstream mod untouched."
        }
    }
} catch {
    Write-Warning "Could not read current mod state ($($_.Exception.Message)); continuing with windhawk-cli defaults."
}

$wantDisabled = $Disabled -or (-not $Enable -and $installed -and -not $installed.enabled)

$cliArgs = @('mod', 'install', '--file', $src, '--arch', $Arch)
if ($wantDisabled) { $cliArgs += '--disabled' }

$state = if ($installed) { if ($installed.enabled) { 'enabled' } else { 'disabled' } } else { 'new' }
Write-Host "==> $modId ($state) <- $src" -ForegroundColor Cyan

$log = Join-Path ([IO.Path]::GetTempPath()) "wh-install-$PID.log"
$codeFile = "$log.code"
Remove-Item -LiteralPath $log, $codeFile -ErrorAction SilentlyContinue

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Hand off to the daemon when one can serve this build: it streams its own
# output, so the log replay further down is skipped. $exit stays $null if the
# daemon is unavailable or gives up, and the prompting path below takes over.
$exit = $null
$streamed = $false

# The daemon only accepts bundles under build/, so a -NoBundle install of a file
# from somewhere else has to prompt.
$daemonEligible = -not $NoDaemon -and -not $NoElevate -and -not $isElevated -and
                  $src.StartsWith([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) 'build')),
                                  [StringComparison]::OrdinalIgnoreCase)

if ($daemonEligible) {
    . (Join-Path $PSScriptRoot 'wh-ipc.ps1')
    $ipc = Get-WhIpc
    if (-not (Test-WhDaemonAlive $ipc)) {
        [void](Start-WhDaemon -Ipc $ipc -IdleMinutes $IdleMinutes)
    }
    if (Test-WhDaemonAlive $ipc) {
        $exit = Invoke-WhDaemonBuild -Ipc $ipc -Bundle $src -Arch $Arch `
                                     -Disabled:$wantDisabled -StdinAs $src
        $streamed = $null -ne $exit
    }
}

if ($null -ne $exit) {
    # already handled by the daemon
} elseif ($NoElevate -or $isElevated) {
    & $Cli @cliArgs *> $log
    $exit = $LASTEXITCODE
} else {
    # ShellExecute (-Verb RunAs) cannot redirect streams, so an elevated pwsh
    # does the redirection on our behalf and reports the exit code via a file.
    function Format-PSLiteral([string]$s) { "'" + $s.Replace("'", "''") + "'" }
    $quoted = ($cliArgs | ForEach-Object { Format-PSLiteral $_ }) -join ' '
    $inner = "& $(Format-PSLiteral $Cli) $quoted *> $(Format-PSLiteral $log); " +
             "`$LASTEXITCODE | Set-Content -LiteralPath $(Format-PSLiteral $codeFile)"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))

    try {
        $proc = Start-Process pwsh `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $b64) `
            -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    } catch {
        Write-Host 'Elevation was declined -- the mod was not built.' -ForegroundColor Yellow
        exit 1
    }

    $exit = if (Test-Path -LiteralPath $codeFile) {
        [int](Get-Content -LiteralPath $codeFile -Raw).Trim()
    } else {
        $proc.ExitCode
    }
}

# The bundle's #line directives already anchor most diagnostics to the real
# source file. Anything emitted outside their reach is anchored to '<stdin>',
# because windhawk-cli pipes the source to the compiler; those line and column
# numbers are correct against the bundle, so renaming is enough to make them
# clickable.
if (-not $streamed -and (Test-Path -LiteralPath $log)) {
    foreach ($line in Get-Content -LiteralPath $log) {
        $out = $line.Replace('<stdin>', $src)
        if ($out -match ':\d+:\d+:\s+(error|fatal error):' -or $out -match '^error:') {
            Write-Host $out -ForegroundColor Red
        } elseif ($out -match ':\d+:\d+:\s+warning:') {
            Write-Host $out -ForegroundColor Yellow
        } else {
            Write-Host $out
        }
    }
}
Remove-Item -LiteralPath $log, $codeFile -ErrorAction SilentlyContinue

if ($exit -eq 0) {
    Write-Host "==> OK: $modId built and installed." -ForegroundColor Green
} else {
    Write-Host "==> FAILED: windhawk-cli exited with $exit." -ForegroundColor Red
}
exit $exit

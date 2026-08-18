#Requires -Version 7.0
<#
.SYNOPSIS
    Locate the Windhawk installation. Dot-source it.

.DESCRIPTION
    Every script here shells out to windhawk-cli.exe, which lives wherever
    Windhawk was installed. Hardcoding C:\Program Files\Windhawk works on the
    default install and fails outright on any other, so the path is discovered
    instead -- from an explicit override, then the registry, then the
    conventional locations.

    REGISTRY VIEWS. Windhawk's installer is 32-bit, so on x64 it writes under
    the WOW6432Node redirect:

        HKLM\SOFTWARE\WOW6432Node\Windhawk               install_dir
        HKLM\SOFTWARE\WOW6432Node\...\Uninstall\Windhawk InstallLocation

    These scripts run in 64-bit PowerShell 7, which sees the *native* view, so
    HKLM:\SOFTWARE\Windhawk is a different key entirely -- it exists, holds
    Engine and Settings, and has no install_dir. Both views are therefore
    probed explicitly rather than relying on redirection to sort it out.

    install_dir is preferred over the Uninstall entry's InstallLocation: it is
    what the installer writes for its own use, whereas InstallLocation is
    Add/Remove Programs metadata that an installer is free to leave empty.

    Every candidate is confirmed by the presence of windhawk-cli.exe, so a
    stale registry entry pointing at an uninstalled copy falls through to the
    next candidate rather than producing a confusing failure later on.
#>

Set-StrictMode -Version Latest

$script:WhInstallRoot = $null   # resolved once per session

# Native and WOW6432Node views of both the installer's key and the uninstall
# entry. Order is preference order.
$script:WhRegistryProbes = @(
    @{ Path = 'HKLM:\SOFTWARE\Windhawk';                                           Name = 'install_dir' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Windhawk';                               Name = 'install_dir' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Windhawk'; Name = 'InstallLocation' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Windhawk'; Name = 'InstallLocation' }
)

<#
.SYNOPSIS
    Read one registry value, yielding $null when the key or the value is absent.

.NOTES
    The .NET API rather than Get-ItemPropertyValue, because a missing key or
    value is the *expected* case on three of the four probes and the cmdlet
    signals it by raising. Swallowing four exceptions cost ~50 ms per run --
    material against a bundle step that takes ~200. OpenSubKey and GetValue
    both return null instead, so the whole probe is allocation-cheap and needs
    no try/catch at all.

    A 64-bit process sees the native view here, so the WOW6432Node redirect is
    written out literally in the probe list above rather than left to Wow64.
#>
function Get-WhRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    # 'HKLM:\SOFTWARE\...' -> 'SOFTWARE\...'
    $sub = $Path -replace '^HKLM:\\', ''
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub)
    if (-not $key) { return $null }
    try {
        $value = $key.GetValue($Name)
        if ($value -is [string] -and $value.Trim()) { return $value.Trim() }
    } finally {
        $key.Dispose()
    }
    return $null
}

<#
.SYNOPSIS
    The Windhawk install directory, or $null if it cannot be found.

.PARAMETER Refresh
    Re-probe rather than reusing the cached result.
#>
function Get-WhInstallRoot {
    param([switch]$Refresh)

    if ($script:WhInstallRoot -and -not $Refresh) { return $script:WhInstallRoot }

    $candidates = [Collections.Generic.List[string]]::new()

    # An explicit override always wins -- portable installs, side-by-side
    # builds, and anyone whose registry disagrees with reality.
    if ($env:WINDHAWK_HOME) { $candidates.Add($env:WINDHAWK_HOME) }

    foreach ($probe in $script:WhRegistryProbes) {
        $found = Get-WhRegistryValue -Path $probe.Path -Name $probe.Name
        if ($found) { $candidates.Add($found) }
    }

    # Conventional locations, built from the environment rather than a literal
    # C:\ -- Windows can live on another drive.
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($pf) { $candidates.Add((Join-Path $pf 'Windhawk')) }
    }

    foreach ($candidate in $candidates) {
        # The cli is what every caller actually wants, so its presence -- not
        # the directory's -- is what makes a candidate valid.
        if (Test-Path -LiteralPath (Join-Path $candidate 'windhawk-cli.exe') -PathType Leaf) {
            $script:WhInstallRoot = $candidate.TrimEnd('\')
            return $script:WhInstallRoot
        }
    }

    return $null
}

<#
.SYNOPSIS
    Full path to windhawk-cli.exe. Throws with guidance when Windhawk is absent.
#>
function Get-WhCliPath {
    $root = Get-WhInstallRoot
    if (-not $root) {
        throw ("Could not locate windhawk-cli.exe. Is Windhawk installed?`n" +
               "Set `$env:WINDHAWK_HOME to the Windhawk install directory to point these " +
               'scripts at it explicitly.')
    }
    Join-Path $root 'windhawk-cli.exe'
}

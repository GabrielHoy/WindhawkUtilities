#Requires -Version 7.0
<#
.SYNOPSIS
    Per-mod build hooks: optional scripts a mod runs at defined build stages.
    Dot-source it.

.DESCRIPTION
    A mod may carry a hooks/ folder beside its mod.json:

        mods/<name>/hooks/postBuild.ps1

    Each recognised hook name maps to one stage of the build. A mod with no
    hooks/ folder -- almost all of them -- costs a single Test-Path.

    Hooks exist because a bundle is not always the last word on what should be
    installed. Stamping a build id into the source, appending a licence notice,
    running a mod-specific lint over the flattened translation unit: all of it
    is per-mod policy that has no business living in the shared bundler, and all
    of it wants the *bundle*, not the sources.

    Stages:

        postBuild   after the bundle has been written to build/<name>.wh.cpp and
                    every handle on it closed, but before wh-install.ps1 hands
                    that file to windhawk-cli. The hook may rewrite the file
                    freely -- whatever it leaves behind is what Windhawk
                    compiles.

    A hook is passed -ModDir (the mods/<name> folder that was built) and
    -OutFile (the generated bundle), both absolute:

        param([string]$ModDir, [string]$OutFile)

    Two properties of the invocation are load-bearing:

      * It runs in a child pwsh, not in the caller's session. A hook therefore
        gets its own strict mode, error preferences and working directory
        rather than silently inheriting the bundler's, and -ExecutionPolicy
        Bypass means an unsigned hook runs on a default-policy machine.

      * All of its output -- both streams -- is written to the host. The
        bundler returns the bundle path on its *success* stream and
        wh-install.ps1 captures that into a variable, so anything a hook leaked
        there would be spliced into the path and break the install. For the
        same reason Invoke-WhModHook itself emits nothing.

    A nonzero exit code fails the build. A hook is a build step; a silent
    failure would install a bundle that only half-ran its own policy.

    Hooks run unelevated, before the one command that needs Administrator. That
    is deliberate -- a repo-controlled script never gains admin rights from the
    build, whether or not the daemon is in play.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'wh-hooks.ps1')
    Invoke-WhModHook -ModDir $modDir -Name postBuild -Parameters @{
        ModDir = $modDir; OutFile = $outFile
    }
#>

Set-StrictMode -Version Latest

$script:WhHooksDir = 'hooks'

# The whole vocabulary. Anything else in hooks/ is a typo or a stale
# experiment, and gets warned about rather than silently ignored -- a hook that
# never runs looks exactly like a hook that ran and did nothing.
$script:WhKnownHooks = @('postBuild')

function Get-WhKnownHooks { , $script:WhKnownHooks }

<#
.SYNOPSIS
    Path to a mod's hook script for one stage, or $null if it has none.
#>
function Get-WhModHook {
    param(
        [Parameter(Mandatory)][string]$ModDir,
        [Parameter(Mandatory)][string]$Name
    )

    $dir = Join-Path $ModDir $script:WhHooksDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }

    # @() because a single stray file comes back as a bare object and
    # StrictMode Latest rejects .Count on one of those.
    $strays = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.ps1' |
                Where-Object { $_.BaseName -notin $script:WhKnownHooks })
    foreach ($s in $strays) {
        Write-Warning ("$(Split-Path -Leaf $ModDir)/hooks/$($s.Name) is not a recognised hook and " +
                       "will never run. Known hooks: $($script:WhKnownHooks -join ', ') (.ps1).")
    }

    $path = Join-Path $dir "$Name.ps1"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $path).Path
    }

    return $null
}

<#
.SYNOPSIS
    Run a mod's hook for one stage, if it has one. A no-op otherwise.

.OUTPUTS
    Nothing, ever -- see the note about the success stream above.
#>
function Invoke-WhModHook {
    param(
        [Parameter(Mandatory)][string]$ModDir,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Parameters = @{}
    )

    $hook = Get-WhModHook -ModDir $ModDir -Name $Name
    if (-not $hook) { return }

    # Named parameters, so a hook declares a param() block and gets real
    # binding. A hook that declares none still runs -- the pairs land in $args.
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $hook)
    foreach ($key in @($Parameters.Keys) | Sort-Object) {
        $pwshArgs += "-$key"
        $pwshArgs += [string]$Parameters[$key]
    }

    Write-Host "==> hook $Name -> $([IO.Path]::GetRelativePath($ModDir, $hook).Replace('\','/'))" `
               -ForegroundColor DarkCyan

    # The pwsh currently running, which need not be the one on PATH -- editor
    # tasks launch these scripts by absolute path.
    $pwsh = (Get-Process -Id $PID).Path
    if (-not $pwsh) { $pwsh = 'pwsh' }

    # PowerShell 7.4 turns a nonzero native exit code into a terminating error
    # when $ErrorActionPreference is 'Stop', which would report the failure as a
    # generic command error instead of naming the hook. The exit code is checked
    # explicitly below, so opt out for the duration of the call. Function-scoped
    # assignment; the caller's setting is untouched.
    $PSNativeCommandUseErrorActionPreference = $false

    # 2>&1 merges the hook's error stream in, and Write-Host puts the lot on the
    # host: nothing a hook prints may reach our success stream.
    & $pwsh @pwshArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        throw "$(Split-Path -Leaf $ModDir): $Name hook failed (exit $code) -- $hook"
    }
}

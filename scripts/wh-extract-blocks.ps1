#Requires -Version 7.0
<#
.SYNOPSIS
    Move a mod's metadata, readme and settings blocks out of src/main.wh.cpp
    into their own files, which wh-amalgamate.ps1 splices back in at bundle
    time.

.DESCRIPTION
    Windhawk mods carry their metadata, documentation and settings schema inline
    at the top of main.wh.cpp, as comments:

        // ==WindhawkMod==           // @key value lines
        // ==WindhawkModReadme==     /* several hundred lines of markdown */
        // ==WindhawkModSettings==   /* several hundred lines of YAML */

    That is fine for a single file published to Windhawk's catalogue and
    miserable to actually work in: the editor greys the whole thing out as
    comment, GitHub renders none of the markdown, no YAML or JSON tooling
    engages, and the C++ you came to edit starts several screens down.

    This moves them out, up one level from the C++ they were buried in:

        // ==WindhawkMod==         -> mods/<name>/mod.json
        // ==WindhawkModReadme==   -> mods/<name>/README.md
        // ==WindhawkModSettings== -> mods/<name>/settings.yaml
                                      mods/<name>/src/main.wh.cpp stays put

    and deletes the now-redundant blocks from main.wh.cpp -- which, once all
    three are gone, opens straight onto C++. wh-amalgamate.ps1 splices them back
    into build/<name>.wh.cpp on every build, so what Windhawk compiles and
    installs is unchanged. This is purely a change to how the sources are
    laid out.

    mod.json is generated with a relative "$schema" pointing at
    schemas/WindhawkMod.schema.json, which gives key completion, hover docs and
    enum validation in any editor with JSON Schema support. Repeatable fields
    (@include, @exclude, @architecture) become arrays; locale-suffixed fields
    (@name:zh-CN and friends) are grouped under "localized" by language tag,
    which beats having a mod's twelve translation lines interleaved by key.

    The extraction is content-preserving but not byte-preserving. Blank lines
    padding a /* ... */ wrapper are dropped, and the regenerated metadata block
    is re-sorted into canonical field order with its values re-aligned, which
    normalises the hand-maintained alignment upstream mods tend to drift on.
    Verify a mod by bundling it before and after and diffing -- what remains
    should be the Build Date, the #line numbers (main.wh.cpp is now shorter),
    and metadata whitespace.

.PARAMETER Mod
    One or more mod names, mod folders, or any file inside one. Omit with -All.

.PARAMETER All
    Every local@* mod under mods/. Unprefixed folders are mirrored upstream
    copies kept verbatim so a fork can be diffed against them -- rewriting those
    is exactly what they exist to avoid, so -All skips them unless
    -IncludeMirrors says otherwise. Naming a mirror explicitly always works.

.PARAMETER IncludeMirrors
    Let -All touch the unprefixed upstream mirror folders too.

.PARAMETER Block
    Restrict to certain blocks: Metadata, Readme, Settings. Defaults to all.

.PARAMETER Force
    Overwrite an existing mod.json / README.md / settings.yaml. Without it, a
    mod whose target file already exists is left completely untouched, on the
    assumption that it was already extracted and the inline block is stale.

.EXAMPLE
    .\scripts\wh-extract-blocks.ps1 local@windows-animations-fork -WhatIf

.EXAMPLE
    .\scripts\wh-extract-blocks.ps1 -All -Block Settings
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Mod,

    [switch]$All,

    [switch]$IncludeMirrors,

    [ValidateSet('Metadata', 'Readme', 'Settings')]
    [string[]]$Block,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'wh-blocks.ps1')

$Repo     = Split-Path -Parent $PSScriptRoot
$ModsRoot = Join-Path $Repo 'mods'
$utf8     = Get-WhUtf8

# mods/<name>/mod.json -> schemas/, so two levels up. Written into each file as
# $schema so the editor validates it on its own, independently of the workspace
# glob in .vscode/settings.json.
$SchemaRef = '../../schemas/WindhawkMod.schema.json'

# ---------------------------------------------------------------- which mods

if (-not $All -and -not $Mod) {
    throw 'Name at least one mod, or pass -All.'
}

$modDirs = if ($All) {
    # Unprefixed folders are mirrored upstream sources, kept verbatim so a
    # local@ fork can be diffed against them. Reformatting one destroys the only
    # thing it is there for.
    Get-ChildItem -LiteralPath $ModsRoot -Directory |
        Where-Object { Get-WhModSource -ModDir $_.FullName } |
        Where-Object { $IncludeMirrors -or $_.Name.StartsWith('local@') } |
        ForEach-Object { $_.FullName }
} else {
    $Mod | ForEach-Object {
        $d = Resolve-WhModDir -Spec $_ -ModsRoot $ModsRoot
        if (-not $d) { throw "Could not resolve '$_' to a mod under $ModsRoot." }
        $d
    }
}

# -Block takes friendly names; the table keys off Windhawk's own block names.
$blockNames = @{ Metadata = 'Mod'; Readme = 'ModReadme'; Settings = 'ModSettings' }
$wanted     = if ($Block) { $Block | ForEach-Object { $blockNames[$_] } } else { $null }

# ------------------------------------------------------------------- extract

$touched = 0

foreach ($modDir in $modDirs) {
    $modName = Split-Path -Leaf $modDir
    $source  = Get-WhModSource -ModDir $modDir
    if (-not $source) {
        Write-Warning "$modName has no src\main.wh.cpp; skipped."
        continue
    }
    $entry = $source.Entry
    # For messages: "<mod>/src/main.wh.cpp", or the flat path if not moved yet.
    $entryRel = "$modName/" + [IO.Path]::GetRelativePath($modDir, $entry).Replace('\', '/')

    $lines = ([IO.File]::ReadAllText($entry, $utf8)) -split "`r`n|`n|`r"
    # A file ending in a newline splits to a trailing empty element; the rewrite
    # below re-adds that newline, so keeping it would grow the file by a blank
    # line on every run.
    if ($lines.Count -and -not $lines[-1]) { $lines = $lines[0..($lines.Count - 2)] }

    $blocks = Get-WhHeaderBlocks -Lines $lines
    if (-not $blocks.Count) {
        # No inline blocks is the *finished* state, not a broken one -- but only
        # if the files they moved into are actually there.
        $already = @(Get-WhExternalBlocks | Where-Object {
            $b = $_; @($b.Files | Where-Object { Test-Path -LiteralPath (Join-Path $modDir $_) }).Count
        })
        if ($already.Count) { Write-Verbose "$modName is already fully extracted; nothing to do." }
        else { Write-Warning "$entryRel has no ==WindhawkMod== header run; skipped." }
        continue
    }

    # Line indices to delete, collected across every block extracted from this
    # mod so main.wh.cpp is rewritten exactly once.
    $drop  = [Collections.Generic.HashSet[int]]::new()
    $wrote = @()

    foreach ($ext in (Get-WhExternalBlocks)) {
        if ($wanted -and $ext.Block -notin $wanted) { continue }

        $b = $blocks | Where-Object { $_.Name -ieq $ext.Block } | Select-Object -First 1
        if (-not $b) { continue }

        if ($ext.Kind -eq 'metadata') {
            $meta = ConvertFrom-WhModBlock -Lines $lines -Block $b
            if ($null -eq $meta) {
                Write-Warning ("$modName ==Windhawk$($ext.Block)== holds something that is not a " +
                               '// @key line; left alone rather than guessed at.')
                continue
            }
            # Copied key by key rather than `+`: adding two [ordered] dicts in
            # PowerShell yields a plain Hashtable and loses the ordering that
            # makes the generated file readable.
            $doc = [ordered]@{ '$schema' = $SchemaRef }
            foreach ($k in $meta.Keys) { $doc[$k] = $meta[$k] }

            # Depth 5 clears { localized: { locale: { key: value } } } with room
            # to spare.
            $payload = ($doc | ConvertTo-Json -Depth 5) -split "`r`n|`n|`r"
        } else {
            $payload = Get-WhBlockPayload -Lines $lines -Block $b
            if ($null -eq $payload) {
                Write-Warning ("$modName ==Windhawk$($ext.Block)== is not wrapped in /* ... */; " +
                               'left alone rather than guessed at.')
                continue
            }
        }

        # First candidate is the canonical name; the others exist only so an
        # already-extracted settings.yml is still recognised by the bundler.
        $target = Join-Path $modDir $ext.Files[0]
        $exists = $ext.Files | ForEach-Object { Join-Path $modDir $_ } |
                  Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                  Select-Object -First 1
        if ($exists -and -not $Force) {
            Write-Warning ("$modName/$(Split-Path -Leaf $exists) already exists; skipped. " +
                           'Pass -Force to overwrite it from the inline block.')
            continue
        }
        if ($exists) { $target = $exists }

        if ($PSCmdlet.ShouldProcess("$modName/$(Split-Path -Leaf $target)",
                                    "extract ==Windhawk$($ext.Block)==")) {
            [IO.File]::WriteAllText($target, ($payload -join "`r`n") + "`r`n", $utf8)
        }
        $wrote += Split-Path -Leaf $target

        # The block itself, plus any blank lines directly beneath it, so
        # removing it does not leave a widening gap in the header run.
        for ($i = $b.Start; $i -le $b.End; $i++) { [void]$drop.Add($i) }
        for ($i = $b.End + 1; $i -lt $lines.Count -and -not $lines[$i].Trim(); $i++) {
            [void]$drop.Add($i)
        }
    }

    if (-not $wrote.Count) { continue }

    if ($PSCmdlet.ShouldProcess($entryRel, "remove $($wrote.Count) inline block(s)")) {
        $kept = @(for ($i = 0; $i -lt $lines.Count; $i++) { if (-not $drop.Contains($i)) { $lines[$i] } })
        [IO.File]::WriteAllText($entry, ($kept -join "`r`n") + "`r`n", $utf8)
    }

    $touched++
    Write-Host ("==> $modName -> " + ($wrote -join ' + ')) -ForegroundColor DarkCyan
}

Write-Host "==> extracted from $touched mod(s)." -ForegroundColor Green

#Requires -Version 7.0
<#
.SYNOPSIS
    Shared mod lookup and // ==Windhawk*== header-block parsing. Dot-source it.

.DESCRIPTION
    Every Windhawk mod opens with a run of comment blocks that Windhawk -- not
    the C++ compiler -- parses out of the source:

        // ==WindhawkMod==          @id / @version / @include / ...
        // ==WindhawkModReadme==    /* markdown */
        // ==WindhawkModSettings==  /* yaml */

    The last two are pure payload wrapped in a C block comment, which makes them
    miserable to edit in place: the editor sees several hundred lines of dead
    comment, GitHub renders nothing, and no YAML tooling engages. Both can
    instead live in their own file in the mod folder, and wh-amalgamate.ps1
    splices them back in when it bundles.

    wh-amalgamate.ps1 (splicing files in) and wh-extract-blocks.ps1 (pulling
    inline blocks out into files) must agree exactly on where a block begins and
    ends -- if they drift, a migration silently drops or duplicates content.
    Hence one parser, here, used by both.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'wh-blocks.ps1')
    $blocks = Get-WhHeaderBlocks -Lines $lines
#>

Set-StrictMode -Version Latest

# Windhawk writes these markers itself, always on their own line. The capture
# group is the block name -- 'Mod', 'ModReadme', 'ModSettings'.
$script:WhBlockOpen  = '^\s*//\s*==Windhawk(\w*)==\s*$'
$script:WhBlockClose = '^\s*//\s*==/Windhawk(\w*)==\s*$'

# No BOM: Windhawk's compiler is fed this source over stdin, and these files
# carry emoji in their prose, so the encoding must never be left to the console
# code page.
$script:WhUtf8 = [Text.UTF8Encoding]::new($false)

function Get-WhBlockRegex { [pscustomobject]@{ Open = $script:WhBlockOpen; Close = $script:WhBlockClose } }
function Get-WhUtf8       { $script:WhUtf8 }

<#
.SYNOPSIS
    Resolve a mod name, mod folder, or any file inside one to the mod folder.

.DESCRIPTION
    An existing path is walked up until its parent is mods/, so a build or an
    extraction can be triggered from any file in the mod -- including anything
    under src/ -- rather than only from main.wh.cpp. Anything else is treated as
    a bare mod name, tolerating a trailing .wh.cpp so the old flat filenames
    still resolve.

    Returns $null when nothing matches -- callers decide whether that is a hard
    error or grounds for a fallback.
#>
function Resolve-WhModDir {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$ModsRoot
    )

    if (Test-Path -LiteralPath $Spec) {
        $item = Get-Item -LiteralPath $Spec
        $dir  = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
        while ($dir) {
            $parent = Split-Path -Parent $dir
            if ($parent -and [IO.Path]::GetFullPath($parent).TrimEnd('\') -ieq
                              [IO.Path]::GetFullPath($ModsRoot).TrimEnd('\')) {
                return $dir
            }
            $dir = $parent
        }
    }

    $name      = $Spec -replace '\.wh\.cpp$', '' -replace '[\\/]+$', ''
    $candidate = Join-Path $ModsRoot $name
    if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }

    return $null
}

# C++ lives one level down, so the mod folder itself shows only the things you
# actually configure -- mod.json, README.md, settings.yaml -- instead of burying
# them among headers.
$script:WhSrcDir = 'src'

<#
.SYNOPSIS
    Locate a mod's entry point and the directory its sources live in.

.OUTPUTS
    An object with SrcDir and Entry, or $null when the mod has no main.wh.cpp
    anywhere. Callers decide whether that is fatal.

.NOTES
    src/main.wh.cpp is the layout; a main.wh.cpp sitting directly in the mod
    folder is still accepted, because that is how Windhawk's own ModsSource
    files arrive and how every mod here looked before the split. src/ wins when
    both somehow exist, so a half-finished move cannot quietly build the stale
    copy.
#>
function Get-WhModSource {
    param([Parameter(Mandatory)][string]$ModDir)

    $srcDir = Join-Path $ModDir $script:WhSrcDir
    $nested = Join-Path $srcDir 'main.wh.cpp'
    if (Test-Path -LiteralPath $nested -PathType Leaf) {
        return [pscustomobject]@{ SrcDir = $srcDir; Entry = $nested }
    }

    $flat = Join-Path $ModDir 'main.wh.cpp'
    if (Test-Path -LiteralPath $flat -PathType Leaf) {
        return [pscustomobject]@{ SrcDir = $ModDir; Entry = $flat }
    }

    return $null
}

<#
.SYNOPSIS
    The payload blocks that may be sourced from a file in the mod folder.

.DESCRIPTION
    Returns fresh objects each call, because callers annotate them per-run.

      Block  the ==Windhawk<Block>== name this file provides
      Files  candidate filenames in the mod folder, first existing one wins
      Kind   'metadata' for the // @key lines of ==WindhawkMod==, which are read
             by Windhawk directly; 'comment' for the /* ... */ payload blocks
      First  must open the header run -- Windhawk requires ==WindhawkMod== at
             byte 0, so nothing may be emitted above it
      After  when splicing a file whose block is not present inline at all,
             the block to splice it after; $null means end of the header run

    Order here is the order Windhawk's own mods use, which is also the order
    ==WindhawkMod== -> readme -> settings reads best in.
#>
function Get-WhExternalBlocks {
    , @(
        [pscustomobject]@{ Block = 'Mod';         Files = @('mod.json');                      Kind = 'metadata'; First = $true;  After = $null }
        [pscustomobject]@{ Block = 'ModReadme';   Files = @('README.md');                     Kind = 'comment';  First = $false; After = 'Mod' }
        [pscustomobject]@{ Block = 'ModSettings'; Files = @('settings.yaml', 'settings.yml'); Kind = 'comment';  First = $false; After = $null }
    )
}

<#
.SYNOPSIS
    Locate every // ==Windhawk*== block in the header run.

.PARAMETER Lines
    The file, already split into lines.

.PARAMETER From
    Index to start scanning at. wh-amalgamate.ps1 passes 1 when cpp-bundler
    has prepended a #line directive above the header.

.OUTPUTS
    One object per block, in file order, with Name / Start / End line indices
    (End is the index of the closing marker, inclusive). Empty if the file has
    no header run -- which means it is not a Windhawk mod source.

.NOTES
    Outside a block the scan steps over blank lines and // comments, and stops
    at anything else. The comment tolerance is load-bearing: several upstream
    mods sit a GPL notice and an issue-tracker link between ==/WindhawkMod== and
    ==WindhawkModReadme==, and stopping there would hide every block below it.
    Stopping at the first line of real code still keeps a stray ==Windhawk*==
    marker deeper in the file from being mistaken for part of the header.

    Callers must treat the run as the span from the first block's Start to the
    last block's End and preserve whatever sits *between* the blocks -- that
    notice is part of the source, not scaffolding.
#>
function Get-WhHeaderBlocks {
    param(
        # Source files are full of blank lines, and Mandatory applies its
        # empty-check to every element of a [string[]], not just the array.
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [int]$From = 0
    )

    $blocks  = [Collections.Generic.List[object]]::new()
    $pending = $null

    for ($i = $From; $i -lt $Lines.Count; $i++) {
        if (-not $pending) {
            if ($Lines[$i] -match $script:WhBlockOpen) {
                $pending = @{ Name = $Matches[1]; Start = $i }
                continue
            }
            # Blank lines and // comments are header furniture; anything else is
            # the start of real code and ends the run.
            $t = $Lines[$i].Trim()
            if ($t -and -not $t.StartsWith('//')) { break }
            continue
        }
        if ($Lines[$i] -match $script:WhBlockClose) {
            $pending.End = $i
            $blocks.Add([pscustomobject]$pending)
            $pending = $null
        }
    }

    # `, $blocks` not `$blocks`: PowerShell enumerates a returned collection, so
    # a fully migrated mod -- every block now in its own file, none left inline
    # -- would come back as $null and blow up on .Count under StrictMode.
    , $blocks
}

<#
.SYNOPSIS
    Strip a block down to the payload between its /* and */ wrapper.

.PARAMETER Lines
    The whole file, split into lines.

.PARAMETER Block
    One object from Get-WhHeaderBlocks.

.OUTPUTS
    The payload lines, with the markers, the comment wrapper, and any leading or
    trailing blank lines removed. Returns nothing for a block that is not
    comment-wrapped -- ==WindhawkMod== itself, whose // @metadata lines are read
    by Windhawk directly and cannot be moved out of the source.
#>
function Get-WhBlockPayload {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][object]$Block
    )

    # Interior of the block, markers excluded.
    $first = $Block.Start + 1
    $last  = $Block.End   - 1
    # `, @()` not `@()`: a bare empty array unrolls to nothing on return and the
    # caller sees $null, which is the signal reserved for "not comment-wrapped".
    if ($first -gt $last) { return , @() }

    while ($first -le $last -and -not $Lines[$first].Trim()) { $first++ }
    while ($last -ge $first -and -not $Lines[$last].Trim())  { $last-- }
    # `, @()` not `@()`: a bare empty array unrolls to nothing on return and the
    # caller sees $null, which is the signal reserved for "not comment-wrapped".
    if ($first -gt $last) { return , @() }

    if ($Lines[$first].Trim() -ne '/*' -or $Lines[$last].Trim() -ne '*/') { return $null }

    $first++; $last--
    while ($first -le $last -and -not $Lines[$first].Trim()) { $first++ }
    while ($last -ge $first -and -not $Lines[$last].Trim())  { $last-- }
    # `, @()` not `@()`: a bare empty array unrolls to nothing on return and the
    # caller sees $null, which is the signal reserved for "not comment-wrapped".
    if ($first -gt $last) { return , @() }

    , @($Lines[$first..$last])
}

<#
.SYNOPSIS
    Wrap a file's contents back into a // ==Windhawk<Block>== comment block.

.OUTPUTS
    The block's lines, ready to splice into a bundle.

.NOTES
    Throws on a payload containing */. C has no escape for a nested block
    comment terminator, so such a payload would close the comment early and
    hand the remainder to the compiler as code. Failing loudly at bundle time
    beats mangling the prose or emitting a bundle that cannot compile.
#>
function New-WhPayloadBlock {
    param(
        [Parameter(Mandatory)][string]$Block,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('comment', 'metadata')][string]$Kind = 'comment'
    )

    if ($Kind -eq 'metadata') {
        # PowerShell 7's ConvertFrom-Json tolerates // comments, which is why
        # mod.json is associated as jsonc in .vscode/settings.json -- the schema
        # still applies and notes can sit next to the field they explain.
        $json = [IO.File]::ReadAllText($Path, $script:WhUtf8)
        try { $meta = $json | ConvertFrom-Json }
        catch { throw "$(Split-Path -Leaf $Path) is not valid JSON: $($_.Exception.Message)" }
        if (-not $meta) { throw "$(Split-Path -Leaf $Path) is empty." }

        # Warn rather than fail: the editor already flags this live, Windhawk
        # validates again at install, and a schema that lags a new Windhawk
        # field should not be able to block a build.
        $schemaFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\WindhawkMod.schema.json'
        if (Test-Path -LiteralPath $schemaFile) {
            # Test-Json reports violations as non-terminating errors, so they
            # have to be captured rather than caught.
            $issues = $null
            # Validate the *reserialized* object, not the file text: mod.json is
            # read as JSONC, and Test-Json's parser rejects the // comments that
            # ConvertFrom-Json just accepted. $meta already parsed cleanly, so
            # round-tripping it strips the comments and leaves the data intact.
            $schemaText = [IO.File]::ReadAllText($schemaFile, $script:WhUtf8)
            try {
                Test-Json -Json ($meta | ConvertTo-Json -Depth 10) -Schema $schemaText `
                          -ErrorAction SilentlyContinue -ErrorVariable issues | Out-Null
            } catch {
                # A malformed *schema* is a terminating error, and the callers
                # run with $ErrorActionPreference = 'Stop'. Validation must
                # never be able to fail a build.
                Write-Warning "schema $(Split-Path -Leaf $schemaFile) could not be applied: $($_.Exception.Message)"
                $issues = $null
            }
            foreach ($issue in $issues) {
                Write-Warning "$(Split-Path -Leaf $Path): $($issue.Exception.Message -replace '^The JSON is not valid with the schema: ', '')"
            }
        }

        return ConvertTo-WhModBlock -Meta $meta
    }

    $body = ([IO.File]::ReadAllText($Path, $script:WhUtf8)) -split "`r`n|`n|`r"

    $bad = @(for ($i = 0; $i -lt $body.Count; $i++) { if ($body[$i].Contains('*/')) { $i + 1 } })
    if ($bad.Count) {
        throw ("$(Split-Path -Leaf $Path) contains '*/' on line(s) $($bad -join ', '); that would " +
               "terminate the generated /* ... */ block early. Reword or split those occurrences.")
    }

    # Trailing blank lines are noise once the block has its own terminator.
    $last = $body.Count - 1
    while ($last -ge 0 -and -not $body[$last].Trim()) { $last-- }
    $body = if ($last -ge 0) { $body[0..$last] } else { @() }

    , @(@("// ==Windhawk$Block==", '/*') + $body + @('*/', "// ==/Windhawk$Block=="))
}

# ---------------------------------------------------------------------------
#  ==WindhawkMod== metadata  <->  mod.json
# ---------------------------------------------------------------------------
#
#  Unlike the readme and settings blocks, this one is not a comment-wrapped
#  payload -- it is a list of // @key value lines Windhawk parses itself:
#
#      // @id              taskbar-dock-animation-plus-fork
#      // @name            Taskbar Dock Animation Plus
#      // @name:zh-CN      ...
#      // @include         explorer.exe
#      // @architecture    x86-64
#
#  Three shapes have to survive the round trip: keys that legitimately repeat
#  (@include, @exclude, @architecture), keys carrying a locale suffix, and keys
#  this script has never heard of, because Windhawk may add more.
#
#  Field reference: https://github.com/ramensoftware/windhawk/wiki/Creating-a-new-mod

# Emission order. Windhawk does not care, but a stable order keeps generated
# blocks diffable against the upstream mods they were forked from.
$script:WhMetaOrder = @(
    'id', 'name', 'description', 'version', 'author',
    'github', 'twitter', 'homepage', 'donateUrl',
    'include', 'exclude', 'architecture', 'compilerOptions', 'license'
)

# Documented as repeatable, so these are always arrays in JSON even when a mod
# happens to declare exactly one -- a type that changes shape depending on how
# many entries you have is a trap for both the schema and the caller.
$script:WhMetaMultiple = @('include', 'exclude', 'architecture')

# Documented as localizable via an @key:<tag> suffix.
$script:WhMetaLocalizable = @('name', 'description', 'author')

$script:WhMetaLine = '^\s*//\s*@([A-Za-z][A-Za-z0-9_]*)(?::([A-Za-z0-9_-]+))?(?:[ \t]+(.*))?$'

<#
.SYNOPSIS
    Convert an inline ==WindhawkMod== block into the mod.json object model.

.OUTPUTS
    An ordered hashtable ready for ConvertTo-Json, or $null if the block holds
    anything that is not a // @key line -- in which case the caller should leave
    it alone rather than risk dropping something on the way out.
#>
function ConvertFrom-WhModBlock {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][object]$Block
    )

    $meta      = [ordered]@{}
    $localized = [ordered]@{}

    for ($i = $Block.Start + 1; $i -lt $Block.End; $i++) {
        $line = $Lines[$i]
        if (-not $line.Trim()) { continue }
        if ($line -notmatch $script:WhMetaLine) { return $null }

        # $Matches only carries groups that actually participated, and reading a
        # missing key is an error under StrictMode -- hence Contains, not $null
        # comparisons.
        $key    = $Matches[1]
        $locale = if ($Matches.Contains(2)) { $Matches[2] } else { $null }
        # A key with no value at all is legal and means the empty string.
        $value  = if ($Matches.Contains(3)) { $Matches[3].Trim() } else { '' }

        if ($locale) {
            if (-not $localized.Contains($locale)) { $localized[$locale] = [ordered]@{} }
            $localized[$locale][$key] = $value
            continue
        }

        if ($meta.Contains($key)) {
            # Repeated key: promote to an array, whether or not it is one of the
            # documented multi-value fields. Losing a repeat would be worse than
            # emitting an array the schema did not expect.
            $meta[$key] = @($meta[$key]) + $value
        } elseif ($key -in $script:WhMetaMultiple) {
            $meta[$key] = @($value)
        } else {
            $meta[$key] = $value
        }
    }

    if ($localized.Count) { $meta['localized'] = $localized }
    $meta
}

<#
.SYNOPSIS
    Render a mod.json object back into ==WindhawkMod== block lines.

.PARAMETER Meta
    The parsed mod.json, as a PSCustomObject from ConvertFrom-Json.

.NOTES
    Values are aligned into a column the way Windhawk's own mods are written.
    The width is computed from the longest key present, so a mod with long
    locale suffixes stays aligned rather than inheriting a fixed guess.
#>
function ConvertTo-WhModBlock {
    param([Parameter(Mandatory)][object]$Meta)

    $prop = @{}
    foreach ($p in $Meta.PSObject.Properties) { $prop[$p.Name] = $p.Value }

    # Locale -> ordered key/value, flattened back to @key:locale lines below.
    $localized = [ordered]@{}
    if ($prop.ContainsKey('localized') -and $prop['localized']) {
        foreach ($p in $prop['localized'].PSObject.Properties) { $localized[$p.Name] = $p.Value }
    }

    # Known keys first in canonical order, then anything unrecognised in the
    # order the file declared it, so a future Windhawk field still round-trips.
    $keys = @($script:WhMetaOrder | Where-Object { $prop.ContainsKey($_) })
    $keys += @($prop.Keys | Where-Object {
        $_ -ne 'localized' -and -not $_.StartsWith('$') -and $_ -notin $script:WhMetaOrder
    })

    # Build the flat @key / @key:locale list first: the column width depends on
    # the longest key that actually gets emitted, suffixes included.
    $pairs = [Collections.Generic.List[object]]::new()
    foreach ($k in $keys) {
        foreach ($v in @($prop[$k])) { $pairs.Add([pscustomobject]@{ Key = $k; Value = "$v" }) }
        foreach ($loc in $localized.Keys) {
            $lp = $localized[$loc].PSObject.Properties[$k]
            if ($lp) { $pairs.Add([pscustomobject]@{ Key = "${k}:$loc"; Value = "$($lp.Value)" }) }
        }
    }

    if (-not $pairs.Count) { throw 'mod.json has no metadata fields.' }

    $width = ($pairs | ForEach-Object { $_.Key.Length } | Measure-Object -Maximum).Maximum
    $body  = foreach ($p in $pairs) {
        if ($p.Value) { '// @{0} {1}' -f $p.Key.PadRight($width), $p.Value }
        else          { ('// @{0}' -f $p.Key) }
    }

    , @(@('// ==WindhawkMod==') + $body + @('// ==/WindhawkMod=='))
}

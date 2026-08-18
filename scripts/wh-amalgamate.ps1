#Requires -Version 7.0
<#
.SYNOPSIS
    Bundle a multi-file Windhawk mod into the single .wh.cpp Windhawk demands.

.DESCRIPTION
    Windhawk compiles exactly one translation unit per mod and offers no include
    path, so a mod must ship as one self-contained file. This script keeps the
    *sources* split -- mods/<name>/src/main.wh.cpp plus any headers it and
    shared/ provide -- and uses cpp-bundler to inline every quoted include
    into a single generated file under build/.

    A mod folder separates what you configure from what you compile:

        mods/<name>/mod.json          metadata
        mods/<name>/README.md         documentation
        mods/<name>/settings.yaml     settings schema
        mods/<name>/src/main.wh.cpp   entry point, plus any headers beside it

    A main.wh.cpp sitting directly in the mod folder is still accepted -- that
    is how ModsSource files arrive -- but src/ wins if both exist.

    System includes (<windows.h> and friends) are deliberately left alone: no
    --dir-system is passed, so cpp-bundler cannot resolve them and emits the
    directives untouched for Windhawk's compiler to handle.

    Two fixups are applied to cpp-bundler's output:

      1. --line-directives emits Windows paths raw, e.g.
             #line 2 "\\?\C:\repos\util.h"
         Inside a C string literal that is broken -- \U starts a universal
         character name and \r\t\a are control characters. Paths are rewritten
         to forward slashes with the \\?\ prefix stripped.

      2. cpp-bundler puts its first #line directive above line 1, which would
         push Windhawk's // ==WindhawkMod== block off the top of the file. The
         metadata blocks are hoisted back to byte 0 and the directive re-emitted
         underneath with a corrected line number.

    The payoff is that compiler diagnostics -- and Wh_Log output, which expands
    __LINE__ -- resolve to the real source file you are editing rather than to
    the generated bundle.

    While that header run is being rebuilt, all three of Windhawk's header
    blocks may be sourced from their own files beside main.wh.cpp instead of
    from comments wedged into it:

        mod.json                     -> // ==WindhawkMod==
        README.md                    -> // ==WindhawkModReadme==
        settings.yaml / settings.yml -> // ==WindhawkModSettings==

    The point is that a mod's prose renders on GitHub, its settings get real
    YAML highlighting and folding, and its metadata gets JSON Schema completion
    and validation -- rather than all three being hundreds of lines the editor
    treats as dead comment text. Migrate with wh-extract-blocks.ps1.

    The file on disk wins outright: a matching block left behind inline in
    main.wh.cpp is dropped with a warning, not emitted twice.

    Two shapes are involved. The readme and settings blocks are payload wrapped
    in slash-star / star-slash, so one splice serves both. ==WindhawkMod== is
    not -- it is // @key value lines Windhawk parses itself -- so mod.json is
    rendered back into those lines by ConvertTo-WhModBlock in wh-blocks.ps1,
    and is checked against schemas/WindhawkMod.schema.json on the way through.
    Schema violations warn rather than fail: the editor already flags them live
    and Windhawk validates again at install, so a schema lagging behind a new
    Windhawk field must not be able to block a build.

    Note that a fully migrated main.wh.cpp contains no header blocks at all --
    it opens straight onto C++ -- so an empty header run is only an error when
    there is no mod.json to supply ==WindhawkMod== either.

    Once the bundle is on disk, an optional per-mod hook gets the last word:

        mods/<name>/hooks/postBuild.ps1   -ModDir <mod folder> -OutFile <bundle>

    It runs with the file written and closed, and before wh-install.ps1 hands
    that file to windhawk-cli, so it is free to rewrite the bundle and whatever
    it leaves behind is what Windhawk compiles. See wh-hooks.ps1.

.PARAMETER Mod
    A mod name (folder under mods/), a mod folder path, or any file inside one.
    Given a file, the enclosing mod folder is found by walking up to mods/.

.PARAMETER OutDir
    Where the bundle is written. Defaults to build/ at the repo root.

.PARAMETER AllowFallback
    When Mod names nothing recognisable -- typically because the editor handed
    over a file in shared/, which belongs to no single mod -- rebuild whichever
    mod was built last instead of failing.

.PARAMETER NoLineDirectives
    Omit #line directives. Diagnostics then point at the generated bundle.
    An escape hatch for when a bundle needs to be published as plain source.

.OUTPUTS
    The full path of the generated .wh.cpp, on the success stream. Progress goes
    to the host, so `$bundle = & wh-amalgamate.ps1 foo` captures only the path.

.EXAMPLE
    .\scripts\wh-amalgamate.ps1 local@windows-animations-fork

.EXAMPLE
    .\scripts\wh-amalgamate.ps1 .\mods\local@windows-animations-fork\src\anim.h
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Mod,

    [string]$OutDir,

    [switch]$AllowFallback,

    [switch]$NoLineDirectives
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Header-block parsing is shared with wh-extract-blocks.ps1: the two must agree
# exactly on where a block starts and ends, or extracting one would drop or
# duplicate content the other then splices back.
. (Join-Path $PSScriptRoot 'wh-blocks.ps1')

# Optional per-mod build hooks (mods/<name>/hooks/postBuild.ps1). Dot-sourced
# unconditionally; a mod without a hooks/ folder costs one Test-Path.
. (Join-Path $PSScriptRoot 'wh-hooks.ps1')

$Repo     = Split-Path -Parent $PSScriptRoot

# The bundler is a separate binary rather than something this repo builds, so
# where it lives is a deployment choice, not a fixed path. Searched in priority
# order; every candidate is absolute or PATH-resolved, never relative to the
# caller's working directory -- these scripts are launched from editor tasks and
# from arbitrary shells, and a CWD-relative lookup breaks the second case.
$ToolName   = 'cpp-bundler.exe'
$candidates = @(
    $env:WH_BUNDLER                        # explicit override wins
    (Join-Path $Repo "tools/$ToolName")    # conventional home for vendored tools
    (Join-Path $Repo "build/$ToolName")
    (Join-Path $Repo $ToolName)
) | Where-Object { $_ }

$Tool = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $Tool) {
    # PATH last: a system-wide install is fine, it just shouldn't shadow a copy
    # deliberately vendored into the repo. Assigned in two steps because under
    # StrictMode reading .Source off a no-match ($null) is a terminating error.
    $onPath = Get-Command $ToolName -CommandType Application -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($onPath) { $Tool = $onPath.Source }
}
if (-not $Tool) {
    throw ("$ToolName not found. Set `$env:WH_BUNDLER to its full path, put it on PATH, or " +
           "drop it at one of:`n" + (($candidates | ForEach-Object { "  $_" }) -join "`n"))
}

$ModsRoot = Join-Path $Repo 'mods'
$Shared   = Join-Path $Repo 'shared'
if (-not $OutDir) { $OutDir = Join-Path $Repo 'build' }

# ---------------------------------------------------------------- resolve mod

function Resolve-ModDir([string]$spec) { Resolve-WhModDir -Spec $spec -ModsRoot $ModsRoot }

$modDir = Resolve-ModDir $Mod

if (-not $modDir -and $AllowFallback) {
    $lastFile = Join-Path $OutDir '.last-mod'
    if (Test-Path -LiteralPath $lastFile) {
        $last = (Get-Content -LiteralPath $lastFile -Raw).Trim()
        $modDir = Resolve-ModDir $last
        if ($modDir) {
            Write-Host "'$(Split-Path -Leaf $Mod)' is outside any mod; rebuilding last mod '$last'." -ForegroundColor Yellow
        }
    }
}

if (-not $modDir) {
    $known = (Get-ChildItem -LiteralPath $ModsRoot -Directory |
              Where-Object { Get-WhModSource -ModDir $_.FullName } |
              ForEach-Object { "  $($_.Name)" }) -join "`n"
    throw "Could not resolve '$Mod' to a mod under $ModsRoot.`nKnown mods:`n$known"
}

$modName = Split-Path -Leaf $modDir
$source  = Get-WhModSource -ModDir $modDir
if (-not $source) {
    throw "$modDir has no src\main.wh.cpp."
}
$srcDir = $source.SrcDir
$entry  = $source.Entry
# For messages: "<mod>/src/main.wh.cpp", or the flat path if not moved yet.
$entryRel = "$modName/" + [IO.Path]::GetRelativePath($modDir, $entry).Replace('\', '/')

# ------------------------------------------------------------------- bundling

$OutputtedFileInfoBlockMessage = "
/*

|-=->-------------------------------------------------<-=-|
|-=-<                                                 >-=-|
|-=-<                      Hello!                     >-=-|
|-=-<         Thanks for checking out the mod!        >-=-|
|-=-<                                                 >-=-|
|-=-<     This file was automatically generated       >-=-|
|-=-<     by a CD script to allow for multi-file      >-=-|
|-=-<          Windhawk mod development.              >-=-|
|-=-<                                                 >-=-|
|-=-<   It's probably not pretty, due to things like  >-=-|
|-=-<    included #line sourcemapping directives!     >-=-|
|-=-<                                                 >-=-|
|-=-<  If you'd rather not deal with spaghetti, try   >-=-|
|-=-<    to modify the original repositories code     >-=-|
|-=-<      where possible instead of this file!       >-=-|
|-=-<                                                 >-=-|
|-=->-------------------------------------------------<-=-|

*/

/*
|-=->-------------------------------------------------<-=-|
|-=-<  Bundle Metadata
|-=->-------------------------------------------------<-=-|
|-=->  Directory Name: ""$modName""
|-=->  Build Date: $(Get-Date -Format 'yyyy-MM-dd @ HH:mm:ss')
|-=->-------------------------------------------------<-=-|
*/"

$tmp = Join-Path ([IO.Path]::GetTempPath()) "wh-amalgamate-$PID.cpp"

# --dir-quote only: system includes stay as directives because no search path
# can resolve them. Unresolvable quote includes are an error rather than a
# passthrough, so a typo'd path fails here instead of as a puzzling diagnostic
# about a header Windhawk's compiler was never going to find.
$toolArgs = @(
    '--dir-quote', $srcDir
    '--dir-quote', $Repo       # lets any mod write #include "shared/foo.h"
    '--unresolvable-quote-include', 'error'
    '--cyclic-include', 'error'
    '-o', $tmp
)
# Only distinct when the mod uses src/. Kept searchable so a header still
# sitting in the mod folder resolves rather than failing the build outright.
if ($srcDir -ne $modDir) { $toolArgs += @('--dir-quote', $modDir) }
if (Test-Path -LiteralPath $Shared -PathType Container) {
    $toolArgs += @('--dir-quote', $Shared)
}
if (-not $NoLineDirectives) { $toolArgs += '--line-directives' }
$toolArgs += $entry

Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
$stderr = & $Tool @toolArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    $stderr | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    throw "cpp-bundler failed for '$modName' (exit $LASTEXITCODE)."
}
$stderr | Where-Object { $_ } | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }

# Read through UTF-8 explicitly; these sources carry emoji in their readme
# blocks and the console code page must not get a say in it.
$utf8 = Get-WhUtf8
$text = [IO.File]::ReadAllText($tmp, $utf8)
Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue

$lines = $text -split "`r`n|`n|`r"

# ------------------------------------------------------- fixup 1: #line paths

function Format-LinePath([string]$p) {
    # \\?\C:\x -> C:/x ; \\?\UNC\srv\s -> //srv/s
    if ($p.StartsWith('\\?\UNC\')) { $p = '\\' + $p.Substring(8) }
    elseif ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    $p.Replace('\', '/').Replace('"', '\"')
}

$lineDirective = '^#line\s+(\d+)\s+"(.*)"\s*$'
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $lineDirective) {
        $lines[$i] = '#line {0} "{1}"' -f $Matches[1], (Format-LinePath $Matches[2])
    }
}

# ------------------------ fixup 2: rebuild the Windhawk header run at the top

# Windhawk reads its metadata from a run of // ==Windhawk*== comment blocks at
# the head of the file, so nothing may precede them -- and only the leading
# #line directive ever does. That run is dismantled here and reassembled, which
# both gets the directive out of the way and gives external README.md /
# settings.yaml files a place to be spliced in.

# ---- which blocks come from their own file, and where they get anchored

# `After` names the block a splice follows when the mod has no inline block for
# it to replace; $null means "at the end of the header run".
$externals = Get-WhExternalBlocks
foreach ($ext in $externals) {
    $found = $ext.Files | ForEach-Object { Join-Path $modDir $_ } |
             Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
             Select-Object -First 1
    Add-Member -InputObject $ext -NotePropertyName 'Source' -NotePropertyValue $found
    Add-Member -InputObject $ext -NotePropertyName 'Lines' -NotePropertyValue `
               $(if ($found) { New-WhPayloadBlock -Block $ext.Block -Path $found -Kind $ext.Kind } else { $null })
}

# ---- locate every block in the header run

$hasLead  = (-not $NoLineDirectives) -and $lines.Count -and ($lines[0] -match $lineDirective)
$leadPath = if ($hasLead) { $Matches[2] } else { $null }

# With a leading directive lines[0] is that directive and lines[i] holds source
# line i -- exactly the offset needed to rebuild it after the hoist. Without
# one, nothing was prepended and the scan simply starts at the top.
$scanFrom = if ($hasLead) { 1 } else { 0 }
$blocks   = Get-WhHeaderBlocks -Lines $lines -From $scanFrom

# ---- reassemble

# Once a mod is fully migrated, main.wh.cpp holds no header blocks at all and
# every one of them comes from a file -- so an empty run is only an error when
# there is no mod.json to supply ==WindhawkMod== either.
$hasModSource = $blocks.Count -or ($externals | Where-Object { $_.Block -eq 'Mod' -and $_.Lines })

if ($hasModSource) {
    # Where main.wh.cpp's own content resumes. With no inline run that is the
    # top of the file; the whole thing is body.
    $bodyStart = if ($blocks.Count) { $blocks[$blocks.Count - 1].End + 1 }
                 elseif ($hasLead)  { 1 }
                 else               { 0 }

    # A List, not an array: every splice below appends, and `+=` on an array
    # reallocates the whole thing each time.
    $header = [Collections.Generic.List[string]]::new()
    $splice = {
        param([string[]]$block)
        if ($header.Count) { $header.Add('') }
        $header.AddRange([string[]]$block)
    }

    # Which block names main.wh.cpp still carries inline. An external whose
    # block is in here takes that block's position; only the ones missing
    # entirely need an anchor. Deciding this up front matters: resolving it
    # inside the walk would anchor a readme after ==/WindhawkMod== and then, on
    # reaching the inline readme further down, emit that one as well.
    $inline = @{}
    foreach ($b in $blocks) { $inline[$b.Name.ToLower()] = $true }

    # ==WindhawkMod== must open the file, so its external is placed before the
    # walk rather than waiting for an anchor that may never come.
    foreach ($e in $externals) {
        if ($e.Lines -and $e.First -and -not $inline.ContainsKey($e.Block.ToLower())) {
            & $splice $e.Lines
            $e.Lines = $null
            # Anything anchored to it can now be placed too.
            foreach ($f in $externals) {
                if ($f.Lines -and $f.After -ieq $e.Block -and -not $inline.ContainsKey($f.Block.ToLower())) {
                    & $splice $f.Lines
                    $f.Lines = $null
                }
            }
        }
    }

    # The inline header run is copied verbatim and only the block ranges are
    # substituted. Rebuilding it from the blocks alone would silently drop
    # whatever sits between them -- several upstream mods keep their GPL notice
    # and issue-tracker link right there, between ==/WindhawkMod== and the
    # readme, and that text is part of the source.
    if ($blocks.Count) {
        # From the top of the file, not from the first block: once
        # ==WindhawkMod== has moved to mod.json, whatever used to sit *between*
        # it and the readme -- the GPL notice several upstream mods carry --
        # now sits *above* the first remaining block, and starting at that
        # block would drop it silently.
        $i = $scanFrom
        if ($header.Count -and $i -lt $bodyStart -and $lines[$i].Trim()) { $header.Add('') }

        while ($i -lt $bodyStart) {
            $b = $blocks | Where-Object { $_.Start -eq $i } | Select-Object -First 1
            if (-not $b) { $header.Add($lines[$i]); $i++; continue }

            $ext = $externals | Where-Object { $_.Lines -and $_.Block -ieq $b.Name } | Select-Object -First 1
            if ($ext) {
                # The file on disk is the source of truth; the inline block is
                # stale leftovers from before the payload was extracted out.
                Write-Host ("==> $entryRel still has an inline ==Windhawk$($b.Name)== block; " +
                            "$(Split-Path -Leaf $ext.Source) supersedes it -- delete the inline block.") `
                           -ForegroundColor Yellow
                # No separator added here: the walk is verbatim, so the blank
                # line that preceded the inline block has already been emitted.
                $header.AddRange([string[]]$ext.Lines)
                $ext.Lines = $null   # spliced; must not be appended again below
            } else {
                for ($j = $b.Start; $j -le $b.End; $j++) { $header.Add($lines[$j]) }
            }
            $i = $b.End + 1

            # Anchored splices, for files whose block does not exist inline.
            foreach ($e in $externals) {
                if ($e.Lines -and $e.After -and $e.After -ieq $b.Name -and
                    -not $inline.ContainsKey($e.Block.ToLower())) {
                    & $splice $e.Lines
                    $e.Lines = $null
                }
            }
        }
    }

    # Whatever is left over -- After = $null, or an anchor block that turned out
    # not to exist in this mod -- lands at the end of the run.
    foreach ($e in $externals) {
        if ($e.Lines) { & $splice $e.Lines; $e.Lines = $null }
    }

    # PowerShell ranges count *down* when the start exceeds the end, so a file
    # with no body must be guarded rather than silently reversed.
    $tail = if ($bodyStart -le ($lines.Count - 1)) {
        $lines[$bodyStart..($lines.Count - 1)]
    } else { @() }

    # Order matters here: #line resets the compiler's count outright, so
    # anything *above* it is free, while anything between it and the first real
    # source line offsets every diagnostic and every Wh_Log __LINE__ by its own
    # length. The banner therefore goes first and the directive last.
    $lines = @($header) +
             @($OutputtedFileInfoBlockMessage) +
             $(if ($hasLead) { @('#line {0} "{1}"' -f $bodyStart, $leadPath) } else { @() }) +
             @($tail)
} else {
    Write-Warning "$modName has no ==WindhawkMod== block in $entryRel and no mod.json."
    Write-Warning "Is this is a valid Windhawk mod? or did you run this script on the wrong file?"
    Write-Warning "If you're pointing at a valid mod file, something's wrong with scripts/wh-amalgamate.ps1"
}

# --------------------------------------------------------------------- output

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir "$modName.wh.cpp"
[IO.File]::WriteAllText($outFile, ($lines -join "`r`n") + "`r`n", $utf8)

# @() matters: a lone match comes back as a bare string, and StrictMode Latest
# rejects .Count on one of those.
$inlined = @($lines | Where-Object { $_ -match $lineDirective }).Count
$spliced = @($externals | Where-Object { $_.Source } | ForEach-Object { Split-Path -Leaf $_.Source })

Write-Host ("==> bundled {0} ({1} lines{2}{3}) -> {4}" -f
    $modName, $lines.Count,
    $(if ($inlined -gt 1) { ", $($inlined - 1) include splices" } else { '' }),
    $(if ($spliced.Count) { ", $($spliced -join ' + ')" } else { '' }),
    $outFile) -ForegroundColor DarkCyan

# Remembered so a build triggered from shared/ still knows what to rebuild.
[IO.File]::WriteAllText((Join-Path $OutDir '.last-mod'), $modName, $utf8)

# The bundle is finished and every handle on it is closed, so a postBuild hook
# may rewrite the file in place -- and this runs before wh-install.ps1 feeds it
# to windhawk-cli, so whatever the hook leaves behind is what Windhawk compiles.
# Invoke-WhModHook writes only to the host: nothing may reach the success stream
# below, which callers capture as the bundle path.
Invoke-WhModHook -ModDir $modDir -Name 'postBuild' -Parameters @{
    ModDir  = $modDir
    OutFile = $outFile
}

$outFile

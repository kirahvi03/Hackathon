<#
.SYNOPSIS
    DSH hackathon environment self-check.

.DESCRIPTION
    Verifies that the toolchain configured for this workspace is present and
    that the versions seen in a fresh shell are the intended ones.

    Run it from anywhere:
        pwsh -File .\scripts\env-check.ps1

    Exit code 0 = all required checks passed, 1 = something required is broken.
#>

[CmdletBinding()]
param(
    # Report optional tooling (gh, docker, soffice) as failures too.
    [switch]$Strict
)

$ErrorActionPreference = 'Continue'

# Make sure the persisted PATH (HKCU) is what we test against, even when the
# calling process was started before the environment was configured.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path    = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'

$script:Failures = 0
$script:Warnings = 0

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Test-Tool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$VersionArgs = @('--version'),
        [switch]$Required,
        [string]$Expect
    )

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $level = if ($Required) { 'FAIL' } else { 'WARN' }
        if ($Required) { $script:Failures++ } else { $script:Warnings++ }
        $color = if ($Required) { 'Red' } else { 'DarkYellow' }
        Write-Host ("  [{0}] {1,-8} not found on PATH" -f $level, $Name) -ForegroundColor $color
        return
    }

    $version = $null
    try {
        $version = (& $Name @VersionArgs 2>&1 | Select-Object -First 1)
    } catch {
        $version = 'version query failed'
    }

    $note = ''
    if ($Expect -and ($version -notmatch $Expect)) {
        $script:Warnings++
        $note = "  (expected to match /$Expect/)"
        Write-Host ("  [WARN] {0,-8} {1}  -> {2}{3}" -f $Name, $version, $cmd.Source, $note) -ForegroundColor DarkYellow
        return
    }

    Write-Host ("  [ OK ] {0,-8} {1}" -f $Name, $version) -ForegroundColor Green
    Write-Host ("         {0}" -f $cmd.Source) -ForegroundColor DarkGray
}

function Test-PythonModules {
    $python = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $python) { return }

    $modules = @{
        'numpy'      = 'numpy'
        'pandas'     = 'pandas'
        'openpyxl'   = 'openpyxl'
        'docx'       = 'python-docx'
        'pptx'       = 'python-pptx'
        'PIL'        = 'Pillow'
        'lxml'       = 'lxml'
        'xlsxwriter' = 'XlsxWriter'
    }

    $probe = ($modules.Keys | ForEach-Object {
        "try:`n import $_`n print('OK $_')`nexcept Exception as e:`n print('MISS $_')"
    }) -join "`n"

    $result = & $python.Source -c $probe 2>&1
    foreach ($line in $result) {
        if ($line -match '^OK (\S+)') {
            Write-Host ("  [ OK ] module   {0,-10} ({1})" -f $Matches[1], $modules[$Matches[1]]) -ForegroundColor Green
        } elseif ($line -match '^MISS (\S+)') {
            $script:Warnings++
            Write-Host ("  [WARN] module   {0,-10} ({1}) missing" -f $Matches[1], $modules[$Matches[1]]) -ForegroundColor DarkYellow
        }
    }
}

$root = Split-Path -Parent $PSScriptRoot
Write-Host 'DSH hackathon environment check' -ForegroundColor White
Write-Host ("workspace : {0}" -f $root)
Write-Host ("timestamp : {0:yyyy-MM-dd HH:mm:ss} ({1})" -f (Get-Date), (Get-TimeZone).Id)

Write-Section 'Runtimes'
Test-Tool -Name 'node'   -VersionArgs @('-v') -Required
Test-Tool -Name 'npm'    -VersionArgs @('-v') -Required
Test-Tool -Name 'pnpm'   -VersionArgs @('--version') -Required
Test-Tool -Name 'python' -VersionArgs @('-c', 'import sys; print(sys.version.split()[0])') -Required
Test-Tool -Name 'pip'    -VersionArgs @('--version') -Required

Write-Section 'Version control'
Test-Tool -Name 'git' -VersionArgs @('--version') -Required

$helper = (git config --global --get credential.helper 2>$null)
if ($helper) {
    Write-Host ("  [ OK ] credential.helper = {0}" -f $helper) -ForegroundColor Green
} else {
    $script:Warnings++
    Write-Host '  [WARN] credential.helper is not configured (git push to GitHub may prompt)' -ForegroundColor DarkYellow
}

Push-Location $root
try {
    $insideRepo = (git rev-parse --is-inside-work-tree 2>$null)
    if ($insideRepo -eq 'true') {
        $branch = git rev-parse --abbrev-ref HEAD 2>$null
        Write-Host ("  [ OK ] git repository on branch '{0}'" -f $branch) -ForegroundColor Green
        $remote = git remote get-url origin 2>$null
        if ($remote) {
            Write-Host ("  [ OK ] origin -> {0}" -f $remote) -ForegroundColor Green
        } else {
            $script:Warnings++
            Write-Host '  [WARN] no git remote named origin' -ForegroundColor DarkYellow
        }
    } else {
        $script:Warnings++
        Write-Host '  [WARN] workspace is not a git repository' -ForegroundColor DarkYellow
    }
} finally {
    Pop-Location
}

Write-Section 'Python libraries'
Test-PythonModules

Write-Section 'Optional tooling'
Test-Tool -Name 'gh'      -VersionArgs @('--version')
Test-Tool -Name 'docker'  -VersionArgs @('--version')
Test-Tool -Name 'code'    -VersionArgs @('--version')
Test-Tool -Name 'ffmpeg'  -VersionArgs @('-version')

Write-Section 'Result'
if ($script:Failures -gt 0) {
    Write-Host ("FAILED: {0} required check(s) failed, {1} warning(s)." -f $script:Failures, $script:Warnings) -ForegroundColor Red
    exit 1
}
if ($script:Warnings -gt 0) {
    Write-Host ("PASSED with {0} warning(s)." -f $script:Warnings) -ForegroundColor Yellow
    if ($Strict) { exit 1 }
    exit 0
}
Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
exit 0

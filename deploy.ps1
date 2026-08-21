<#
.SYNOPSIS
  Deploy dashboard data files to GitHub Pages via Contents API.

.DESCRIPTION
  Uploads data.json and weekly-summaries.json to the dashboard repo
  using the GitHub Contents API (avoids git push latency).

  Required env:  DASHBOARD_PAT  (fine-grained PAT, Contents R+W)
  Optional env:  DASHBOARD_REPO, DASHBOARD_BRANCH

.PARAMETER Path
  Path to the dashboard folder. Defaults to the script directory.

.PARAMETER DryRun
  Show what would change without pushing.

.PARAMETER Message
  Commit message.
#>

[CmdletBinding()]
param(
    [string]$Path,
    [switch]$DryRun,
    [string]$Message = ''
)

# Default $Path to script directory
if (-not $Path) { $Path = $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Force UTF-8 output (Chinese Windows)
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    if ($Host.UI.RawUI) {
        $Host.UI.RawUI.WindowTitle = 'Dashboard Deploy'
    }
} catch {}

# --- config ---
$REPO   = if ($env:DASHBOARD_REPO)   { $env:DASHBOARD_REPO }   else { 'buerdeshanaijun/dashboard' }
$BRANCH = if ($env:DASHBOARD_BRANCH) { $env:DASHBOARD_BRANCH } else { 'main' }
$FILES  = @('data.json', 'weekly-summaries.json')

# Default commit message
if (-not $Message) {
    $Message = 'dashboard quick update ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
}

# Cache lives in LOCALAPPDATA to avoid issues with non-ASCII paths in PS5.1
$CACHE_DIR = Join-Path $env:LOCALAPPDATA 'dashboard-deploy'
$CACHE     = Join-Path $CACHE_DIR 'cache.json'
if (-not (Test-Path $CACHE_DIR)) {
    New-Item -ItemType Directory -Path $CACHE_DIR -Force | Out-Null
}

# --- preflight ---
if (-not $DryRun) {
    if (-not $env:DASHBOARD_PAT) {
        Write-Host 'ERROR: DASHBOARD_PAT env var not set.' -ForegroundColor Red
        Write-Host 'Set it like: $env:DASHBOARD_PAT = "github_pat_xxx"'
        exit 1
    }
}

# --- helpers ---
function Get-CachedSha($f) {
    if (Test-Path $CACHE) {
        try {
            $raw = Get-Content $CACHE -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            $c = $raw | ConvertFrom-Json
            if ($c.PSObject.Properties[$f]) { return $c.$f }
        } catch {}
    }
    return $null
}

function Set-CachedSha($f, $sha) {
    $bag = [ordered]@{}
    if (Test-Path $CACHE) {
        try {
            $raw = Get-Content $CACHE -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $ex = $raw | ConvertFrom-Json
                foreach ($p in $ex.PSObject.Properties) { $bag[$p.Name] = $p.Value }
            }
        } catch {}
    }
    $bag[$f] = $sha
    try {
        (ConvertTo-Json -InputObject $bag) | Set-Content -Path $CACHE -Encoding UTF8
    } catch {
        Write-Host ('WARN: cache write failed: ' + $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Get-RemoteSha($f) {
    $ts = Get-Date -Format o
    $amp = [char]38
    $url = 'https://api.github.com/repos/' + $REPO + '/contents/' + $f + '?ref=' + $BRANCH + $amp + 't=' + $ts
    $headers = @{
        'Authorization' = 'Bearer ' + $env:DASHBOARD_PAT
        'Accept'        = 'application/vnd.github+json'
        'User-Agent'    = 'dashboard-deploy'
    }
    $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 15
    return $resp.sha
}

function Put-File($f, $b64, $sha) {
    if ($DryRun) {
        $sizeKB = [math]::Round(($b64.Length * 0.75) / 1KB, 1)
        $shaShort = if ($sha) { $sha.Substring(0,7) } else { 'NEW' }
        $msg = '  [DRY] PUT ' + $f + ' (' + $sizeKB + ' KB, sha=' + $shaShort + ')'
        Write-Host $msg -ForegroundColor DarkYellow
        return
    }
    $url = 'https://api.github.com/repos/' + $REPO + '/contents/' + $f
    $headers = @{
        'Authorization' = 'Bearer ' + $env:DASHBOARD_PAT
        'Accept'        = 'application/vnd.github+json'
        'Content-Type'  = 'application/json'
        'User-Agent'    = 'dashboard-deploy'
    }
    $bodyObj = @{
        message = $Message
        content = $b64
        branch  = $BRANCH
    }
    if ($sha) { $bodyObj.sha = $sha }
    $body = $bodyObj | ConvertTo-Json
    $resp = Invoke-RestMethod -Method Put -Uri $url -Headers $headers -Body $body -TimeoutSec 30
    if ($resp.commit.sha) {
        $shortSha = $resp.commit.sha.Substring(0,7)
        $msg = '  OK ' + $f + ' uploaded (commit ' + $shortSha + ')'
        Write-Host $msg -ForegroundColor Green
        Set-CachedSha $f $resp.content.sha
    } else {
        $msg = '  FAIL ' + $f + ': ' + $resp.message
        Write-Host $msg -ForegroundColor Red
    }
}

# --- main ---
$header1 = 'Deploy dashboard to https://github.com/' + $REPO
Write-Host $header1 -ForegroundColor Cyan
$modeStr = if ($DryRun) { 'DRY-RUN' } else { 'LIVE' }
$header2 = '   branch: ' + $BRANCH + ', mode: ' + $modeStr
Write-Host $header2
Write-Host ''

$anyChanges = $false
foreach ($f in $FILES) {
    $local = Join-Path $Path $f
    if (-not (Test-Path $local)) {
        $msg = '  SKIP missing file: ' + $f
        Write-Host $msg -ForegroundColor DarkGray
        continue
    }
    $bytes = [System.IO.File]::ReadAllBytes($local)
    $b64   = [Convert]::ToBase64String($bytes)

    try {
        $remoteSha = Get-RemoteSha $f
        $cachedSha = Get-CachedSha $f
        if ($remoteSha -eq $cachedSha) {
            $msg = '  - ' + $f + ' unchanged (sha match), skip'
            Write-Host $msg -ForegroundColor DarkGray
            continue
        }
        $anyChanges = $true
        $sizeStr = [math]::Round($bytes.Length/1KB,1)
        $shortR = $remoteSha.Substring(0,7)
        $msg = '  -> ' + $f + ' pending (local ' + $sizeStr + ' KB, remote sha=' + $shortR + ')'
        Write-Host $msg
        Put-File $f $b64 $remoteSha
    } catch {
        $em = $_.Exception.Message
        if ($em -match '404') {
            $msg = '  -> ' + $f + ' remote missing, first create'
            Write-Host $msg
            $anyChanges = $true
            Put-File $f $b64 $null
        } else {
            $msg = '  FAIL ' + $f + ': ' + $em
            Write-Host $msg -ForegroundColor Red
        }
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'DRY-RUN done. No changes pushed.' -ForegroundColor Yellow
    Write-Host 'Run without -DryRun and set DASHBOARD_PAT to deploy for real.' -ForegroundColor Yellow
} elseif ($anyChanges) {
    Write-Host 'Deployed. GitHub Pages will update in ~30s.' -ForegroundColor Green
    Write-Host 'https://buerdeshanaijun.github.io/dashboard/'
} else {
    Write-Host 'No changes detected.' -ForegroundColor DarkGray
}

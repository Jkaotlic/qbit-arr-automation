# Cleanup job for the SSD download cache.
#
# 1. Pre-flight: verify all *arr APIs respond and all configured paths exist.
# 2. Build one in-memory index per library (hashtable key = "<ext>|<size>").
#    *arr renames files on import, but size is preserved byte-for-byte, so
#    (ext, size) is a solid O(1) fingerprint. A single Get-ChildItem -Recurse
#    per library beats the old "recurse on every candidate" pattern by ~50x.
# 3. Walk D:\completed\{tv-sonarr,radarr,music}:
#      - in *arr queue  → skip
#      - fingerprint found in library → delete (imported)
#      - older than OrphanCompletedHours → delete (orphan)
#      - else → keep, log reason
# 4. Walk D:\incompleted\*: anything older than OrphanIncompletedDays → delete.
# 5. Emit a summary line: GB released, items deleted.
#
# Usage:
#   .\cleanup-completed.ps1              # live
#   .\cleanup-completed.ps1 -DryRun      # reports only, no Remove-Item

[CmdletBinding()]
param(
    [switch]$DryRun
)

. "$PSScriptRoot\config.ps1"

$LogFile    = Join-Path $Config.LogDir 'cleanup.log'
$MaxLogSize = 1MB

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $MaxLogSize) {
        Move-Item $LogFile "$LogFile.old" -Force
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Script,
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySec = 5,
        [string]$OpName = 'operation'
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Script
        } catch {
            if ($attempt -ge $MaxAttempts) { throw }
            $delay = [int]([Math]::Pow(3, $attempt - 1) * $InitialDelaySec)  # 5, 15, 45
            Write-Log "  Retry $OpName ($attempt/$MaxAttempts) after error: $($_.Exception.Message); sleeping ${delay}s"
            Start-Sleep -Seconds $delay
        }
    }
}

$VideoExt = @('.mkv', '.mp4', '.avi', '.ts', '.m2ts', '.mov', '.wmv')
$AudioExt = @('.flac', '.mp3', '.m4a', '.opus', '.ogg', '.wav', '.alac', '.aac')

# Working folders owned by other services. Never a cleanup candidate.
$ReservedNames = @('Incomplete', 'incomplete', '.incomplete', '.partial', 'temp', '.tmp')

# ExtraRoots: download folders that live OUTSIDE $Config.Paths.Completed.
# The qBittorrent category 'music' has its own save path on G:, so downloads never
# appear under D:\completed\music and used to pile up forever (36 GB / 134 days old).
$Categories = @(
    @{ Name = 'tv-sonarr'; ArrName='Sonarr'; Arr = $Config.Sonarr; Exts = $VideoExt; ExtraRoots = @() }
    @{ Name = 'radarr';    ArrName='Radarr'; Arr = $Config.Radarr; Exts = $VideoExt; ExtraRoots = @() }
    @{ Name = 'music';     ArrName='Lidarr'; Arr = $Config.Lidarr; Exts = $AudioExt; ExtraRoots = @('G:\Music\Downloads', 'G:\Music\Soulseek\Downloads') }
)

function Test-Preflight {
    $ok = $true
    foreach ($cat in $Categories) {
        try {
            $st = Invoke-WithRetry -OpName "$($cat.ArrName) status" -Script {
                Invoke-RestMethod -Uri "$($cat.Arr.Url)/system/status" `
                    -Headers @{'X-Api-Key' = $cat.Arr.Key} -TimeoutSec 5
            }
            Write-Log "  Preflight OK: $($cat.ArrName) v$($st.version)"
        } catch {
            Write-Log "  Preflight FAIL: $($cat.ArrName) - $($_.Exception.Message)"
            $ok = $false
        }
        $libRoots = @($cat.Arr.Library)
        $missing  = @($libRoots | Where-Object { -not (Test-Path $_) })
        if ($missing.Count -eq $libRoots.Count) {
            Write-Log "  Preflight FAIL: no library path exists: $($libRoots -join ', ')"
            $ok = $false
        } elseif ($missing.Count -gt 0) {
            Write-Log "  Preflight WARN: library root(s) missing (skipped): $($missing -join ', ')"
        }
    }
    foreach ($p in @($Config.Paths.Completed, $Config.Paths.Incompleted)) {
        if (-not (Test-Path $p)) {
            Write-Log "  Preflight FAIL: path missing: $p"
            $ok = $false
        }
    }
    return $ok
}

function Build-LibraryIndex {
    param([string]$libraryRoot, [string[]]$allowedExts)

    $index = @{}
    if (-not (Test-Path $libraryRoot)) { return $index }

    $count = 0
    Get-ChildItem -LiteralPath $libraryRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $allowedExts -contains $_.Extension.ToLower() } |
        ForEach-Object {
            $key = "$($_.Extension.ToLower())|$($_.Length)"
            $index[$key] = $_.FullName
            $count++
        }
    Write-Log "  Indexed $libraryRoot - $count files"
    return $index
}

function Test-FileImported {
    param($sourceFile, [hashtable]$libraryIndex)
    $key = "$($sourceFile.Extension.ToLower())|$($sourceFile.Length)"
    return $libraryIndex.ContainsKey($key)
}

function Test-InArrQueue {
    param($arrCfg, [string]$itemName)
    try {
        $queue = Invoke-WithRetry -OpName 'queue' -MaxAttempts 2 -Script {
            Invoke-RestMethod -Uri "$($arrCfg.Url)/queue?page=1&pageSize=100" `
                -Headers @{'X-Api-Key' = $arrCfg.Key} -TimeoutSec 10
        }
        foreach ($rec in $queue.records) {
            # Plain substring match. -like would treat [ ] * ? in release titles as
            # wildcards and silently mismatch (release names are full of brackets).
            if ($rec.title -and $itemName.IndexOf($rec.title, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    } catch {
        Write-Log "  WARN: queue check failed: $($_.Exception.Message)"
    }
    return $false
}

function Get-MediaFiles {
    param($item, [string[]]$allowedExts)
    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $allowedExts -contains $_.Extension.ToLower() }
    } elseif ($allowedExts -contains $item.Extension.ToLower()) {
        @($item)
    } else {
        @()
    }
}

function Get-ItemSize {
    param($item)
    if ($item.PSIsContainer) {
        (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    } else {
        $item.Length
    }
}

function Get-QbitTrackedItems {
    try {
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $pw = Get-Content -LiteralPath $Config.Qbit.PassFile -Raw -ErrorAction Stop
        $login = Invoke-WebRequest -Uri "$($Config.Qbit.Url)/api/v2/auth/login" -Method Post -Body "username=$($Config.Qbit.User)&password=$pw" -WebSession $session -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($login.Content -ne 'Ok.') { throw 'qBittorrent login failed' }
        $tracked = @{}
        $torrents = @(Invoke-RestMethod -Uri "$($Config.Qbit.Url)/api/v2/torrents/info?filter=all" -WebSession $session -TimeoutSec 20 -ErrorAction Stop)
        foreach ($torrent in $torrents) {
            if ($torrent.content_path) {
                $key = $torrent.content_path.TrimEnd('\').ToLowerInvariant()
                $tracked[$key] = $torrent.state
            }
        }
        return $tracked
    } catch {
        Write-Log "  WARN: qBittorrent tracked-item check failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-QbitTrackedState {
    param($item, [hashtable]$tracked)
    $itemPath = $item.FullName.TrimEnd('\').ToLowerInvariant()
    foreach ($entry in $tracked.GetEnumerator()) {
        if ($entry.Key -eq $itemPath -or $entry.Key.StartsWith("$itemPath\")) {
            return $entry.Value
        }
    }
    return $null
}

function Remove-SafeItem {
    param($item, [string]$reason, [ref]$stats)
    $size = [long](Get-ItemSize $item)
    if ($null -eq $size) { $size = 0 }
    $prefix = if ($DryRun) { 'WOULD DELETE' } else { 'DELETE' }
    Write-Log ("  {0} ({1}, {2:N2} MB): {3}" -f $prefix, $reason, ($size / 1MB), $item.FullName)
    if ($DryRun) {
        $stats.Value.Freed += $size
        $stats.Value.Deleted++
        return
    }
    try {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $item.FullName) {
            throw 'path still exists after Remove-Item'
        }
    } catch {
        Write-Log "  FAILED DELETE: $($item.FullName) - $($_.Exception.Message)"
        return
    }
    $stats.Value.Freed += $size
    $stats.Value.Deleted++
}

# ===========================================================================
$mode = if ($DryRun) { 'DRY-RUN' } else { 'LIVE' }
Write-Log "=== Cleanup started (mode=$mode) ==="

if (-not (Test-Preflight)) {
    Write-Log '!!! Pre-flight failed — aborting to avoid data loss'
    exit 1
}

$stats = @{ Freed = 0L; Deleted = 0 }
$QbitTracked = Get-QbitTrackedItems
if ($null -eq $QbitTracked) {
    Write-Log '!!! qBittorrent tracked-item check failed; aborting cleanup to avoid deleting active content'
    exit 1
}

# Build library indexes once per run.
$Indexes = @{}
foreach ($cat in $Categories) {
    $merged = @{}
    foreach ($root in @($cat.Arr.Library)) {
        $idx = Build-LibraryIndex -libraryRoot $root -allowedExts $cat.Exts
        foreach ($k in $idx.Keys) { $merged[$k] = $idx[$k] }
    }
    $Indexes[$cat.Name] = $merged
}

# --- 1. D:\completed — per-category ---
foreach ($cat in $Categories) {
  $roots = @((Join-Path $Config.Paths.Completed $cat.Name)) + @($cat.ExtraRoots)
  foreach ($folder in $roots) {
    if (-not (Test-Path -LiteralPath $folder)) { continue }

    $items = @(Get-ChildItem -LiteralPath $folder -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { continue }

    Write-Log "Checking $folder ($($items.Count) items)"
    $libraryIndex = $Indexes[$cat.Name]

    foreach ($item in $items) {
        # Service directories of neighbouring apps must never be touched:
        # slskd keeps partial downloads in "Incomplete", qBit/Whisparr in ".incomplete".
        # Without this guard a two-day Soulseek idle would trip the orphan rule
        # and delete the live working folder.
        if ($ReservedNames -contains $item.Name) {
            Write-Log "  SKIP (reserved service folder): $($item.Name)"
            continue
        }

        $age = (Get-Date) - $item.LastWriteTime

        if ($age.TotalHours -lt $Config.MinAgeHours) {
            Write-Log "  SKIP (too new, $([math]::Round($age.TotalHours,1))h): $($item.Name)"
            continue
        }

        if (Test-InArrQueue $cat.Arr $item.Name) {
            Write-Log "  SKIP (in $($cat.ArrName) queue): $($item.Name)"
            continue
        }

        $qbitState = Get-QbitTrackedState $item $QbitTracked
        if ($qbitState) {
            Write-Log "  SKIP (tracked by qBittorrent: $qbitState): $($item.Name)"
            continue
        }

        $mediaFiles = Get-MediaFiles $item $cat.Exts
        $imported = $false
        foreach ($mf in $mediaFiles) {
            if (Test-FileImported $mf $libraryIndex) { $imported = $true; break }
        }

        if ($imported) {
            Remove-SafeItem $item "imported to $(@($cat.Arr.Library) -join ', ')" ([ref]$stats)
        } elseif ($age.TotalHours -gt $Config.OrphanCompletedHours) {
            Remove-SafeItem $item "orphan, $([math]::Round($age.TotalHours,0))h" ([ref]$stats)
        } else {
            Write-Log "  KEEP (not yet imported, $([math]::Round($age.TotalHours,1))h): $($item.Name)"
        }
    }
  }
}

# --- 2. D:\incompleted — stale half-downloads ---
if (Test-Path -LiteralPath $Config.Paths.Incompleted) {
    foreach ($cat in $Categories) {
        $folder = Join-Path $Config.Paths.Incompleted $cat.Name
        if (-not (Test-Path -LiteralPath $folder)) { continue }

        foreach ($item in (Get-ChildItem -LiteralPath $folder -ErrorAction SilentlyContinue)) {
            $ageDays = ((Get-Date) - $item.LastWriteTime).TotalDays
            if ($ageDays -gt $Config.OrphanIncompletedDays) {
                $qbitState = Get-QbitTrackedState $item $QbitTracked
                if ($qbitState) {
                    Write-Log "  SKIP (tracked by qBittorrent: $qbitState): $($item.Name)"
                    continue
                }
                Remove-SafeItem $item "stale incompleted, $([math]::Round($ageDays,1))d" ([ref]$stats)
            }
        }
    }
}

$freedGb = [math]::Round($stats.Freed / 1GB, 2)
Write-Log "=== Cleanup finished (mode=$mode): released ${freedGb} GB across $($stats.Deleted) items ==="

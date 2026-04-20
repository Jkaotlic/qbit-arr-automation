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

$Categories = @(
    @{ Name = 'tv-sonarr'; ArrName='Sonarr'; Arr = $Config.Sonarr; Exts = $VideoExt }
    @{ Name = 'radarr';    ArrName='Radarr'; Arr = $Config.Radarr; Exts = $VideoExt }
    @{ Name = 'music';     ArrName='Lidarr'; Arr = $Config.Lidarr; Exts = $AudioExt }
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
        if (-not (Test-Path $cat.Arr.Library)) {
            Write-Log "  Preflight FAIL: library path missing: $($cat.Arr.Library)"
            $ok = $false
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
    Get-ChildItem $libraryRoot -Recurse -File -ErrorAction SilentlyContinue |
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
            if ($rec.title -and $itemName -like "*$($rec.title)*") { return $true }
        }
    } catch {
        Write-Log "  WARN: queue check failed: $($_.Exception.Message)"
    }
    return $false
}

function Get-MediaFiles {
    param($item, [string[]]$allowedExts)
    if ($item.PSIsContainer) {
        Get-ChildItem $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
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
        (Get-ChildItem $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    } else {
        $item.Length
    }
}

function Remove-SafeItem {
    param($item, [string]$reason, [ref]$stats)
    $size = [long](Get-ItemSize $item)
    if ($null -eq $size) { $size = 0 }
    $prefix = if ($DryRun) { 'WOULD DELETE' } else { 'DELETE' }
    Write-Log ("  {0} ({1}, {2:N2} MB): {3}" -f $prefix, $reason, ($size / 1MB), $item.FullName)
    if (-not $DryRun) {
        Remove-Item $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
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

# Build library indexes once per run.
$Indexes = @{}
foreach ($cat in $Categories) {
    $Indexes[$cat.Name] = Build-LibraryIndex -libraryRoot $cat.Arr.Library -allowedExts $cat.Exts
}

# --- 1. D:\completed — per-category ---
foreach ($cat in $Categories) {
    $folder = Join-Path $Config.Paths.Completed $cat.Name
    if (-not (Test-Path $folder)) { continue }

    $items = Get-ChildItem $folder -ErrorAction SilentlyContinue
    if ($items.Count -eq 0) { continue }

    Write-Log "Checking $folder ($($items.Count) items)"
    $libraryIndex = $Indexes[$cat.Name]

    foreach ($item in $items) {
        $age = (Get-Date) - $item.LastWriteTime

        if ($age.TotalHours -lt $Config.MinAgeHours) {
            Write-Log "  SKIP (too new, $([math]::Round($age.TotalHours,1))h): $($item.Name)"
            continue
        }

        if (Test-InArrQueue $cat.Arr $item.Name) {
            Write-Log "  SKIP (in $($cat.ArrName) queue): $($item.Name)"
            continue
        }

        $mediaFiles = Get-MediaFiles $item $cat.Exts
        $imported = $false
        foreach ($mf in $mediaFiles) {
            if (Test-FileImported $mf $libraryIndex) { $imported = $true; break }
        }

        if ($imported) {
            Remove-SafeItem $item "imported to $($cat.Arr.Library)" ([ref]$stats)
        } elseif ($age.TotalHours -gt $Config.OrphanCompletedHours) {
            Remove-SafeItem $item "orphan, $([math]::Round($age.TotalHours,0))h" ([ref]$stats)
        } else {
            Write-Log "  KEEP (not yet imported, $([math]::Round($age.TotalHours,1))h): $($item.Name)"
        }
    }
}

# --- 2. D:\incompleted — stale half-downloads ---
if (Test-Path $Config.Paths.Incompleted) {
    foreach ($cat in $Categories) {
        $folder = Join-Path $Config.Paths.Incompleted $cat.Name
        if (-not (Test-Path $folder)) { continue }

        foreach ($item in (Get-ChildItem $folder -ErrorAction SilentlyContinue)) {
            $ageDays = ((Get-Date) - $item.LastWriteTime).TotalDays
            if ($ageDays -gt $Config.OrphanIncompletedDays) {
                Remove-SafeItem $item "stale incompleted, $([math]::Round($ageDays,1))d" ([ref]$stats)
            }
        }
    }
}

$freedGb = [math]::Round($stats.Freed / 1GB, 2)
Write-Log "=== Cleanup finished (mode=$mode): released ${freedGb} GB across $($stats.Deleted) items ==="

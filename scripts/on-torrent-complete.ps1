# Called by qBittorrent on torrent completion (via on-torrent-complete.bat).
# 1. Triggers the matching *arr "Downloaded*Scan" command.
# 2. Polls command status until terminal state (up to 5 minutes).
# 3. Removes the torrent entry from qBittorrent — files stay on disk,
#    cleanup-completed.ps1 handles SSD cleanup later.
# NOTE: qBittorrent's autorun command passes %F (content path), not %D (category
# save path) — %D pointed at the shared category folder, not this torrent's own
# folder/file, which broke import matching for multi-file torrents (season packs).

param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Category,
    [Parameter(Mandatory=$true)][string]$SavePath,
    [Parameter(Mandatory=$true)][string]$Hash
)

. "$PSScriptRoot\config.ps1"

$LogFile = Join-Path $Config.LogDir 'torrent-complete.log'

function Write-Log($msg) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -Encoding UTF8
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

function Remove-TorrentFromQbt {
    param([string]$hash)
    try {
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $pw = Get-Content $Config.Qbit.PassFile -ErrorAction SilentlyContinue

        $login = Invoke-WithRetry -OpName 'qBit login' -Script {
            Invoke-WebRequest -Uri "$($Config.Qbit.Url)/api/v2/auth/login" `
                -Method Post -Body "username=$($Config.Qbit.User)&password=$pw" `
                -WebSession $session -UseBasicParsing -TimeoutSec 10
        }

        if ($login.Content -ne 'Ok.') {
            Write-Log 'WARN: qBittorrent login failed'
            return
        }

        Invoke-WithRetry -OpName 'qBit delete' -Script {
            Invoke-WebRequest -Uri "$($Config.Qbit.Url)/api/v2/torrents/delete" `
                -Method Post -Body "hashes=$hash&deleteFiles=false" `
                -WebSession $session -UseBasicParsing -TimeoutSec 10 | Out-Null
        }
        Write-Log "Torrent removed from qBittorrent: $hash"
    } catch {
        Write-Log "WARN: Could not remove torrent: $_"
    }
}

function Invoke-ArrScan {
    param(
        [string]$ArrName,
        [hashtable]$ArrConfig,
        [string]$CommandName
    )

    Write-Log "Triggering $ArrName import for: $SavePath"

    try {
        $body = @{
            name             = $CommandName
            path             = $SavePath
            downloadClientId = $Hash
            importMode       = 'auto'
        } | ConvertTo-Json

        $resp = Invoke-WithRetry -OpName "$ArrName POST /command" -Script {
            Invoke-RestMethod -Uri "$($ArrConfig.Url)/command" -Method Post `
                -Headers @{'X-Api-Key' = $ArrConfig.Key; 'Content-Type' = 'application/json'} `
                -Body $body -TimeoutSec 30
        }
        Write-Log "$ArrName scan queued: id=$($resp.id) status=$($resp.status)"

        # Poll for terminal status up to 5 minutes (every 5s).
        $deadline = (Get-Date).AddSeconds(300)
        $cmd = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            try {
                $cmd = Invoke-RestMethod -Uri "$($ArrConfig.Url)/command/$($resp.id)" `
                    -Headers @{'X-Api-Key' = $ArrConfig.Key} -TimeoutSec 10
            } catch {
                # transient — loop will retry on next tick
                continue
            }
            if ($cmd.status -in 'completed', 'failed', 'aborted') { break }
        }

        if ($null -eq $cmd) {
            Write-Log "$ArrName import status: unreachable - not removing torrent (native completed-download handling will retry)"
            return $false
        }

        $elapsed = if ($cmd.ended -and $cmd.queued) {
            [int]((Get-Date $cmd.ended) - (Get-Date $cmd.queued)).TotalSeconds
        } else { -1 }
        Write-Log "$ArrName import status=$($cmd.status) result=$($cmd.result) elapsed=${elapsed}s"

        return ($cmd.status -eq 'completed' -and $cmd.result -eq 'successful')
    } catch {
        Write-Log "ERROR triggering ${ArrName}: $_"
        return $false
    }
}

Write-Log "=== Torrent completed: Name=$Name Category=$Category Path=$SavePath Hash=$Hash ==="

Start-Sleep -Seconds 5  # let filesystem flush

$importOk = switch ($Category) {
    'tv-sonarr' { Invoke-ArrScan 'Sonarr' $Config.Sonarr 'DownloadedEpisodesScan' }
    'radarr'    { Invoke-ArrScan 'Radarr' $Config.Radarr 'DownloadedMoviesScan' }
    'music'     { Invoke-ArrScan 'Lidarr' $Config.Lidarr 'DownloadedAlbumsScan' }
    default     { Write-Log "Unknown category: $Category - skipping"; $false }
}

if ($importOk -and $Hash) {
    Start-Sleep -Seconds 5
    Remove-TorrentFromQbt $Hash
} elseif ($Hash) {
    Write-Log "Import not confirmed successful - leaving torrent in qBittorrent for native completed-download handling / retry"
}

Write-Log '=== Done ==='

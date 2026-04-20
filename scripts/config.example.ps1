# Copy this file to config.ps1 and fill in real values.
# config.ps1 is gitignored — never commit it.

$Config = @{
    Sonarr = @{
        Url     = 'http://localhost:8989/api/v3'
        Key     = 'YOUR_SONARR_API_KEY'
        Library = 'G:\tv-sonarr'
    }
    Radarr = @{
        Url     = 'http://localhost:7878/api/v3'
        Key     = 'YOUR_RADARR_API_KEY'
        Library = 'G:\radarr'
    }
    Lidarr = @{
        Url     = 'http://localhost:8686/api/v1'
        Key     = 'YOUR_LIDARR_API_KEY'
        Library = 'G:\Music\Library'
    }
    Qbit = @{
        Url      = 'http://localhost:8080'
        User     = 'server'
        PassFile = 'C:\Users\Anex\scripts\.qbt_pass'
    }
    Paths = @{
        Completed   = 'D:\completed'
        Incompleted = 'D:\incompleted'
    }

    LogDir                 = 'C:\Users\Anex\scripts'
    MinAgeHours            = 2     # wait at least this long before considering cleanup
    OrphanCompletedHours   = 48    # delete non-imported leftovers after N hours
    OrphanIncompletedDays  = 14    # delete stale half-downloads from D:\incompleted after N days
}

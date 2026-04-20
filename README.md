# qbit-arr-automation

Автоматизация split-volume setup'а **qBittorrent + Sonarr / Radarr / Lidarr** на Windows, когда `downloads` на SSD, а `library` на HDD.

## Зачем

*arr stack использует флаг `copyUsingHardlinks: true`, но **hardlink невозможен между разными томами NTFS**. Фактически происходит полная copy, и файл остаётся на обоих дисках. Без регулярной чистки SSD быстро забивается — особенно на 4K-контенте.

Эти два скрипта решают проблему:

- **`on-torrent-complete.ps1`** — hook qBittorrent'а, запускает импорт в нужный *arr и выкидывает торрент из списка.
- **`cleanup-completed.ps1`** — scheduled task, каждые 2 часа сносит с SSD всё, что подтверждённо перекочевало в библиотеку.

## Архитектура

```
  [ торрент завершён ]
           │
           ▼
   qBit hook ── on-torrent-complete.bat ── on-torrent-complete.ps1
                                                     │
              ┌──────────────────────────────────────┤
              │                                      │
              ▼                                      ▼
   *arr POST /command              poll /command/{id}  (5s × 60, до 5 минут)
   DownloadedEpisodesScan           │
   DownloadedMoviesScan             │    *arr копирует D:\completed\* → G:\library\*
   DownloadedAlbumsScan             │
              │                     ▼
              └──► qBit DELETE hash (deleteFiles=false)

                                    ⏱  через 2 часа

   Task Scheduler ── cleanup-completed.ps1
              │
              ├─ pre-flight health check (3× API + все пути)
              ├─ build library index  (hashtable "ext|size" → path,  O(1) lookup)
              ├─ walk D:\completed\{tv-sonarr,radarr,music}
              │     ├─ в *arr queue  → skip
              │     ├─ match в индексе → DELETE (imported)
              │     └─ старше 48ч не имп. → DELETE (orphan)
              ├─ walk D:\incompleted\*  →  старше 14д → DELETE
              └─ итог: "released X GB across Y items"
```

## Фичи

| | |
|---|---|
| **Size-based matching** | *arr переименовывает файлы при импорте, но байты копии = байты оригинала. `(extension, size)` — надёжный fingerprint, коллизии < 0.01% на реальных библиотеках. |
| **Single-pass index** | Одно `Get-ChildItem -Recurse` на библиотеку в начале прогона, lookup O(1). На библиотеке ~1 TB — разница со старым подходом в 30-50×. |
| **Pre-flight check** | Перед чисткой проверяются все три API и пути. При фейле скрипт выходит с `exit 1`, не трогая файлы. |
| **Polling hook** | Запрос к `/command/{id}` каждые 5с до terminal-статуса. Без жёстких `Start-Sleep 30`. |
| **Retry с backoff** | 3 попытки, задержки 5s → 15s → 45s (экспоненциальный × 3). |
| **Dry-run** | `.\cleanup-completed.ps1 -DryRun` показывает `WOULD DELETE` без реального удаления. |
| **Метрики** | В итоговой строке — освобождённые GB и количество items. |
| **Категории** | `tv-sonarr` → Sonarr, `radarr` → Radarr, `music` → Lidarr. |

## Установка

### 1. Склонировать и настроить

```powershell
git clone https://github.com/Jkaotlic/qbit-arr-automation.git C:\Tools\qbit-arr-automation
cd C:\Tools\qbit-arr-automation\scripts
Copy-Item config.example.ps1 config.ps1
notepad config.ps1   # заполнить API-ключи, пути
```

Положить пароль qBit в файл, указанный в `$Config.Qbit.PassFile`:

```powershell
'your-qbit-password' | Out-File -NoNewline -Encoding ASCII C:\Users\<you>\scripts\.qbt_pass
```

### 2. qBittorrent hook

**Options → Downloads → Run external program on torrent finished:**

```
C:\Tools\qbit-arr-automation\scripts\on-torrent-complete.bat "%N" "%L" "%D" "%I"
```

Параметры:
- `%N` — name
- `%L` — category (`tv-sonarr` / `radarr` / `music`)
- `%D` — save path
- `%I` — info hash

### 3. Категории в qBit

Убедись что в qBittorrent есть три категории со стандартными save paths:

| Category | Save path |
|---|---|
| `tv-sonarr` | `D:\completed\tv-sonarr` |
| `radarr` | `D:\completed\radarr` |
| `music` | `D:\completed\music` |

И в Sonarr / Radarr / Lidarr: **Settings → Download Clients → qBittorrent → Category** выставлено соответственно.

### 4. *arr settings

- **Settings → Media Management → `Use Hardlinks Instead of Copy`**: можно выключить (hardlink между томами всё равно не работает, флаг только вводит в заблуждение).
- Download client: **Remove Completed** = `off` (или оставь on, hook сам чистит).

### 5. Scheduled Task для cleanup

```powershell
$action  = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Tools\qbit-arr-automation\scripts\cleanup-completed.ps1"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Hours 2)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskName 'cleanup-completed' -Action $action -Trigger $trigger -Principal $principal
```

## Использование

```powershell
# проверить что будет удалено, ничего не трогая
.\cleanup-completed.ps1 -DryRun

# реальный прогон
.\cleanup-completed.ps1
```

## Логи

| Файл | Что там |
|---|---|
| `<LogDir>\torrent-complete.log` | события hook'а: completion, scan, poll, qBit delete |
| `<LogDir>\cleanup.log` | работа cleanup (rotate при > 1 MB → `.old`) |

Формат строк: `yyyy-MM-dd HH:mm:ss <message>`.

## FAQ

**Почему `copyUsingHardlinks: false`?**
Флаг имеет значение только когда downloads и library на одном NTFS-томе. На разных томах *arr молча фолбэкается на copy независимо от флага. `false` — просто честнее в логах.

**Что если импорт занимает дольше 5 минут?**
Hook выходит с `status=unreachable` — это не ошибка. Cleanup при следующем прогоне (≤ 2ч) всё равно найдёт файл в G: и удалит с D:.

**Почему orphan-порог 48 часов?**
Большие 4K-релизы могут сидеть в качалке дольше нормы. 48 часов — компромисс между быстрой очисткой SSD и терпимостью к медленному импорту. Меняется в `config.ps1` → `OrphanCompletedHours`.

**Почему `D:\incompleted` трогается только через 14 дней?**
Активные торренты продолжают писать в файлы, `LastWriteTime` обновляется. 14 дней без записи = торрент точно мёртв.

**Music cleanup через Lidarr — работает ли?**
Да, Lidarr `DownloadedAlbumsScan` эквивалентен Sonarr/Radarr scan-командам. На практике музыка чаще идёт через slskd (Soulseek), но если качаешь альбомы торрентами — pipeline тот же.

## Требования

- Windows 10/11, PowerShell 5.1+
- qBittorrent 4.4+ с включённым WebUI
- Sonarr (API v3), Radarr (API v3), Lidarr (API v1)

## Лицензия

MIT

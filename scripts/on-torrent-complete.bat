@echo off
REM qBittorrent "Run external program on torrent finished" wrapper.
REM Arguments forwarded by qBittorrent: %N (name) %L (category) %D (save path) %I (info hash)
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0on-torrent-complete.ps1" -Name "%~1" -Category "%~2" -SavePath "%~3" -Hash "%~4"

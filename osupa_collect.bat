@echo off
rem osu!PA replay collector: starts osupa_collect.ps1 (open that file in Notepad to read exactly what it does).
rem It only reads your osu! folders and writes zip files into a new folder next to this file.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0osupa_collect.ps1" %*
pause

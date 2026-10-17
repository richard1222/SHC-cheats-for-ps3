@echo off
title SHC God Mode - HP LOCK (Ctrl+C to stop)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0shc_godmode.ps1" -Mode on
echo.
pause

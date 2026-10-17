@echo off
title SHC God Mode - OFF
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0shc_godmode.ps1" -Mode off
echo.
pause

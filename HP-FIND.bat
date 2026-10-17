@echo off
title SHC God Mode - FIND HP FIELD (read only)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0shc_godmode.ps1" -Mode find
echo.
pause

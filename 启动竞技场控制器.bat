@echo off
setlocal
chcp 65001 >nul
title CM70 Arena Season Controller V5
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Arena.ps1"
set "CM70_ARENA_EXIT=%ERRORLEVEL%"
if not "%CM70_ARENA_EXIT%"=="0" pause
exit /b %CM70_ARENA_EXIT%

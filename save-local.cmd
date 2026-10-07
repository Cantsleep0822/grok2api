@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\save-local.ps1" %*
exit /b %ERRORLEVEL%

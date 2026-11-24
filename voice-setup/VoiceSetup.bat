@echo off
rem Vault-Talk voice setup: runs VoiceSetup.ps1 (next to this file) in this window. Read it first if you like:
rem it is plain text and says what it downloads and where it writes.
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VoiceSetup.ps1" %*
echo.
pause

@echo off
REM =====================================================================
REM  6_LOGS — Tail del log operativo del harness.
REM =====================================================================
setlocal
set LOGFILE=%~dp0..\03_HARNESS\server\logs\bridge.log

if not exist "%LOGFILE%" (
  echo [GIGI] Nessun log trovato in: %LOGFILE%
  echo        Avvia prima 1_START_ALL.bat
  pause
  exit /b 1
)

echo [GIGI] Tailing %LOGFILE%
echo       CTRL+C per uscire.
echo.
powershell -NoProfile -Command "Get-Content -Path '%LOGFILE%' -Tail 40 -Wait"

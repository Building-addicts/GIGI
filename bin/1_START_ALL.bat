@echo off
REM =====================================================================
REM  1_START_ALL — Avvia i due servizi Node di GIGI in background.
REM
REM    - harness   (porta 7779) : API iOS + WebSocket stream Claude
REM    - panel     (porta 7777) : UI setup wizard e pair QR
REM
REM  Dopo lo start apre il browser su http://localhost:7777/setup
REM  cosi' vedi subito lo stato dei tunnel e puoi scegliere la modalita'.
REM =====================================================================
setlocal
cd /d "%~dp0\..\03_HARNESS\server"

echo [GIGI] Avvio harness su 7779...
start "GIGI Harness" /MIN cmd /c "node server.js"

REM Piccolo delay cosi' harness ha tempo di bindare la porta prima del panel
timeout /t 2 /nobreak >nul

echo [GIGI] Avvio panel su 7777...
start "GIGI Panel" /MIN cmd /c "node panel.js"

timeout /t 2 /nobreak >nul

echo.
echo [GIGI] Pronto. Verifica rapida:
curl -s -o nul -w "  http 7779 harness /health: %%{http_code}\n" http://127.0.0.1:7779/api/ios/health -H "Authorization: Bearer QkJPxkR4SpE6EvPtmIOJdohLjcGZGHOuVj7SN3Gu"
curl -s -o nul -w "  http 7777 panel   /setup : %%{http_code}\n" http://127.0.0.1:7777/setup

echo.
echo [GIGI] Apro il wizard nel browser...
start "" "http://localhost:7777/setup"

echo.
echo Ora puoi chiudere questa finestra — harness e panel girano in background.
pause

@echo off
REM Windows-friendly launcher per start-harness.sh.
REM Doppio-click su questo file:
REM   1. Apre una nuova finestra cmd, lancia bash start-harness.sh, mantiene
REM      il prompt aperto per vedere log + QR + Ctrl+C.
REM   2. Aspetta che il panel sia raggiungibile su http://localhost:7777/
REM      e apre automaticamente il browser sulla dashboard.

cd /d "%~dp0"
set TITLE=GIGI Harness — panel 7777 + bridge 7779

REM 1. Lancia il harness in una nuova finestra cmd (non blocca questa).
start "%TITLE%" /D "%~dp0" cmd /K "bash start-harness.sh & echo. & echo --- Harness terminato. Premi un tasto per chiudere. --- & pause >nul"

REM 2. Attendi che il panel sia su (max ~30s, ping ogni 2s con curl), poi apri browser.
REM    Se curl non disponibile, fallback a ping classico + apertura blind dopo 8s.
echo Attendo che il panel sia pronto su http://localhost:7777/ ...
set WAITED=0
:WAIT_PANEL
curl -sS -o NUL -m 1 http://localhost:7777/ >NUL 2>&1
if not errorlevel 1 goto OPEN_BROWSER
timeout /t 2 /nobreak >NUL
set /a WAITED+=2
if %WAITED% LSS 30 goto WAIT_PANEL
echo Timeout aspettando il panel ^(30s^). Apro comunque il browser \(il panel potrebbe non essere ancora pronto^).

:OPEN_BROWSER
echo Panel pronto, apro http://localhost:7777/ nel browser default ...
start "" "http://localhost:7777/"

REM Questa finestra cmd si chiude da sola dopo qualche secondo (il vero harness vive nella prima finestra).
timeout /t 3 /nobreak >NUL

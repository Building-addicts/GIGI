@echo off
REM Windows-friendly launcher per start-harness.sh.
REM Doppio-click su questo file: apre una nuova finestra cmd, lancia bash
REM start-harness.sh, mantiene il prompt aperto per vedere log + Ctrl+C.
REM
REM Equivalent unix: ./start-harness.sh

cd /d "%~dp0"
set TITLE=GIGI Harness — panel 7777 + bridge 7779

REM Open in a new window so log is visible + bash can be terminated with Ctrl+C
start "%TITLE%" /D "%~dp0" cmd /K "bash start-harness.sh & echo. & echo --- Harness terminato. Premi un tasto per chiudere. --- & pause >nul"

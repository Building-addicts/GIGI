@echo off
REM =====================================================================
REM  2_STOP_ALL — Termina tutti i processi GIGI.
REM
REM    Uccide ogni `node` (harness, panel, RPC) piu' ogni `cloudflared`
REM    lanciato dal manager (tunnel quick/named + login).
REM
REM  ATTENZIONE: chiude anche eventuali altri script node che stessero
REM  girando sul tuo PC. Se usi Node per altro, usa 2B_STOP_GIGI_ONLY.bat
REM  (piu' selettivo, uccide solo i processi sotto C:\Users\arman\Desktop\GIGI).
REM =====================================================================
echo [GIGI] Stop tutti i node + cloudflared...
taskkill /F /IM node.exe 2>nul
taskkill /F /IM cloudflared.exe 2>nul
echo [GIGI] Fatto.
timeout /t 2 /nobreak >nul

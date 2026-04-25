@echo off
REM =====================================================================
REM  3_STATUS — Controlla cosa sta girando e con che URL pubblico.
REM =====================================================================
echo.
echo =========================================
echo   GIGI status check
echo =========================================
echo.

echo [porte in ascolto]
netstat -ano | findstr /R /C:":7777 " /C:":7778 " /C:":7779 " | findstr LISTENING
echo.

echo [health 7779 harness]
curl -s http://127.0.0.1:7779/api/ios/health -H "Authorization: Bearer QkJPxkR4SpE6EvPtmIOJdohLjcGZGHOuVj7SN3Gu"
echo.
echo.

echo [setup state]
curl -s http://127.0.0.1:7779/api/setup/status
echo.
echo.

echo [pair payload]
curl -s http://127.0.0.1:7779/api/pair
echo.
echo.

echo [processi cloudflared attivi]
tasklist /FI "IMAGENAME eq cloudflared.exe" 2>nul | findstr cloudflared
echo.

pause

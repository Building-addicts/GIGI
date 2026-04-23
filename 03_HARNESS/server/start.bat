@echo off
cd /d "%~dp0"
start "" "http://localhost:7777"
node panel.js

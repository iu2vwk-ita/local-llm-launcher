@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Llama Launcher

if not exist "%~dp0Avvia-Modelli.ps1" (
    echo ERRORE: Avvia-Modelli.ps1 non trovato accanto a questo file.
    pause
    exit /b 1
)

rem PowerShell 7 se presente, altrimenti Windows PowerShell 5.1
where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Avvia-Modelli.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Avvia-Modelli.ps1"
)
pause

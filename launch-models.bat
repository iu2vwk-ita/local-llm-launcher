@echo off
cd /d "%~dp0"
title Local LLM Launcher
where pwsh >nul 2>&1
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0llama-launcher.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0llama-launcher.ps1" %*
)
if "%~1"=="" pause

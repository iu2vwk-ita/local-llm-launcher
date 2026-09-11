@echo off
REM switch-model.bat - start llama-server with one model, replacing any running server.
REM Usage: switch-model.bat <model.gguf|name> [context] [port]
REM   name     : resolved in .\models\ first, otherwise used as-is
REM   context  : default 16384
REM   port     : default 1234
setlocal
set "ROOT=%~dp0"

if "%~1"=="" (
  echo Usage: %~nx0 ^<model.gguf^> [context] [port]
  exit /b 1
)
if not exist "%ROOT%llama-server.exe" (
  echo llama-server.exe not found next to this script: %ROOT%
  exit /b 1
)

set "MODEL=%~1"
if exist "%ROOT%models\%~1" set "MODEL=%ROOT%models\%~1"
set "CTX=%~2"
if "%CTX%"=="" set "CTX=16384"
set "PORT=%~3"
if "%PORT%"=="" set "PORT=1234"

taskkill /F /IM llama-server.exe 2>nul
start "" "%ROOT%llama-server.exe" -m "%MODEL%" -c %CTX% --host 127.0.0.1 --port %PORT% --jinja
echo llama-server -^> http://127.0.0.1:%PORT%  (%MODEL%)

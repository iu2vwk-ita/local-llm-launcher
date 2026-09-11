# start-router.ps1 - start llama-server in router mode (several models from models.ini)
# and launch the Pi coding agent against it.
$ErrorActionPreference = 'Stop'
$Root      = $PSScriptRoot
$serverExe = Join-Path $Root 'llama-server.exe'
$modelsIni = Join-Path $Root 'models.ini'

if (-not (Test-Path $serverExe)) { Write-Host "llama-server.exe not found in $Root" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $modelsIni)) { Write-Host "models.ini not found (copy models.ini.example)" -ForegroundColor Red; exit 1 }

Write-Host "--- llama-server (router mode) ---" -ForegroundColor Cyan
Start-Process -FilePath $serverExe -ArgumentList "--models-preset `"$modelsIni`" --port 8080" -WindowStyle Minimized

Start-Sleep -Seconds 2
Write-Host "--- Pi coding agent ---" -ForegroundColor Green
try { Start-Process "pi" -ArgumentList "start" }
catch { Write-Host "Command 'pi' not found. Start your agent manually." -ForegroundColor Red }

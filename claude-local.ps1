# claude-local.ps1 - launch Claude Code against local models via claude-code-router.
#
# Requires a local OpenAI-compatible server:
#   - llama-server on 127.0.0.1:1234  (provider "llamacpp", model "local-model")
#   - or Ollama on 127.0.0.1:11434    (provider "ollama")
#
# Routing is configured in ~/.claude-code-router/config.json
# Switch model inside Claude Code with:  /model llamacpp,local-model

$ErrorActionPreference = 'Stop'
$env:PATH = "$env:PATH;$env:APPDATA\npm"

$configPath = Join-Path $env:USERPROFILE '.claude-code-router\config.json'
if (-not (Test-Path $configPath)) {
    throw "Missing router config: $configPath"
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json

# Verify the backend named by the default route is actually reachable.
$defaultProvider = ($config.Router.default -split ',')[0]
$provider = $config.Providers | Where-Object { $_.name -eq $defaultProvider }
if (-not $provider) {
    throw "Default route '$($config.Router.default)' names unknown provider '$defaultProvider'."
}
$uri = [uri]$provider.api_base_url
if (-not (Test-NetConnection -ComputerName $uri.Host -Port $uri.Port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Write-Host "Backend '$defaultProvider' is not listening on $($uri.Host):$($uri.Port)." -ForegroundColor Red
    Write-Host "Start the model server first, then re-run this script." -ForegroundColor Yellow
    # Launched from a shortcut the window closes instantly, so hold it open.
    if ($Host.UI.RawUI) { Write-Host "`nPress any key to close..."; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    exit 1
}

# ccr start is a no-op when the service is already running.
ccr start | Out-Null

Write-Host "Router : http://$($config.HOST):$($config.PORT)" -ForegroundColor DarkGray
Write-Host "Model  : $($config.Router.default)" -ForegroundColor DarkGray
Write-Host "Note   : the first reply takes ~30-60s (long system prompt). It is not stuck." -ForegroundColor DarkGray

ccr code @args

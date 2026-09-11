# llama-launcher.ps1 - scan .\models\, choose a GGUF, start llama-server.
#
# Interactive menu (double-click launch-models.bat) or non-interactive:
#   .\llama-launcher.ps1 -Model my-model.gguf -Context 32768
#
# VRAM is filled automatically: -ngl defaults to auto and --fit is on, so n_gpu_layers
# and (unless -Context is given) the context size are chosen to fit device memory.
param(
    [string]$Model,      # model file name (in .\models\) or full path; skips the menu
    [int]$Context = 0,   # 0 = let llama.cpp --fit pick the context size
    [int]$Port = 1234,
    [switch]$List,       # print the scanned models and exit
    [switch]$NoProxy,    # do not start llama-proxy.js
    [switch]$Opencode    # launch OpenCode against the local model
)
$ErrorActionPreference = 'Stop'
$Root      = $PSScriptRoot
$ModelsDir = Join-Path $Root 'models'
$Server    = Join-Path $Root 'llama-server.exe'

if (-not (Test-Path $Server))    { Write-Host "llama-server.exe not found in $Root" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $ModelsDir)) { Write-Host "models\ folder not found in $Root" -ForegroundColor Red; exit 1 }

# Read general.architecture from the GGUF header. It is the first key in practice.
function Get-GgufArch([string]$Path) {
    $fs = $null; $br = $null
    try {
        $fs = [IO.File]::OpenRead($Path)
        $br = New-Object IO.BinaryReader($fs)
        if ([Text.Encoding]::ASCII.GetString($br.ReadBytes(4)) -ne 'GGUF') { return '?' }
        [void]$br.ReadUInt32(); [void]$br.ReadUInt64(); [void]$br.ReadUInt64()   # version, tensor count, kv count
        $klen = [int]$br.ReadUInt64()
        $key  = [Text.Encoding]::UTF8.GetString($br.ReadBytes($klen))
        if ($key -ne 'general.architecture') { return '?' }
        $t = $br.ReadUInt32()
        if ($t -eq 8) {
            $vlen = [int]$br.ReadUInt64()
            return [Text.Encoding]::UTF8.GetString($br.ReadBytes($vlen))
        }
        return '?'
    } catch { return '?' } finally { if ($br) { $br.Dispose() } elseif ($fs) { $fs.Dispose() } }
}

$files = @(Get-ChildItem $ModelsDir -Filter *.gguf -File |
           Where-Object { $_.Name -notmatch 'mmproj' } | Sort-Object Name)
if ($files.Count -eq 0) { Write-Host "No .gguf models in $ModelsDir" -ForegroundColor Red; exit 1 }

function Show-Models($list) {
    Write-Host ''
    Write-Host '  LOCAL LLM LAUNCHER' -ForegroundColor Cyan
    Write-Host "  $ModelsDir" -ForegroundColor DarkGray
    Write-Host ''
    for ($i = 0; $i -lt $list.Count; $i++) {
        $f = $list[$i]
        $gb = [math]::Round($f.Length / 1GB, 2)
        Write-Host ("  [{0,2}] {1,-56} {2,6} GB  {3}" -f ($i + 1), $f.Name, $gb, (Get-GgufArch $f.FullName))
    }
    Write-Host ''
}

if ($List) { Show-Models $files; exit 0 }

if ($Model) {
    $sel = $files | Where-Object { $_.Name -eq $Model -or $_.FullName -eq $Model } | Select-Object -First 1
    if (-not $sel -and (Test-Path -LiteralPath $Model)) { $sel = Get-Item -LiteralPath $Model }
    if (-not $sel) { Write-Host "Model not found: $Model" -ForegroundColor Red; exit 1 }
} else {
    Show-Models $files
    $choice = Read-Host "  Choose (1-$($files.Count)) or Enter to cancel"
    if ([string]::IsNullOrWhiteSpace($choice)) { exit 0 }
    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $files.Count) {
        Write-Host '  Invalid choice.' -ForegroundColor Red; exit 1
    }
    $sel = $files[$idx - 1]
}

$argStr = '-m "' + $sel.FullName + '" --host 127.0.0.1 --port ' + $Port +
          ' -fa on -ctk q8_0 -ctv q8_0 --jinja --alias local-model -n -1'
if ($Context -gt 0) { $argStr += ' -c ' + $Context }

Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process -FilePath $Server -ArgumentList $argStr -WindowStyle Minimized

if (-not $NoProxy -and (Get-Command node -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $Root 'llama-proxy.js'))) {
    Start-Process -FilePath 'node' -ArgumentList (Join-Path $Root 'llama-proxy.js') -WindowStyle Hidden
}
if ($Opencode) { Start-Process 'opencode' -ArgumentList '-m', 'llamacpp/local-model' }

Write-Host ''
Write-Host "  llama-server -> http://127.0.0.1:$Port   ($($sel.Name))" -ForegroundColor Cyan
Write-Host "  Wait for 'model loaded' before sending requests." -ForegroundColor DarkGray

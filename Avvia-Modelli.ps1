param([switch]$SelfTest)

# =====================================================================
#  LLAMA LAUNCHER - run GGUF models with llama.cpp
#  Scans the folder for models, reads the real metadata from each GGUF
#  (layers, embedding, GQA, MoE, quantization) and computes the launch
#  parameters from the VRAM and RAM declared by the user.
#
#  Usage: put this file in the folder with the .gguf files and run it.
# =====================================================================

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'launcher.config.json'
$CachePath  = Join-Path $ScriptDir '.gguf-cache.json'
$LogDir     = Join-Path $ScriptDir 'logs'
$BasePort   = 1234

# ---------------------------------------------------------------- UI --

$C = @{
    Frame = 'DarkCyan'; Title = 'Cyan'; Key = 'Yellow'; Dim = 'DarkGray'
    Ok = 'Green'; Warn = 'Yellow'; Err = 'Red'; Val = 'White'
}

function Write-Rule([string]$Text, [string]$Color = $C.Frame) {
    $w = 78
    if ([string]::IsNullOrEmpty($Text)) {
        Write-Host ('─' * $w) -ForegroundColor $Color
    } else {
        $t = " $Text "
        Write-Host ('─── ' + $t.Trim() + ' ' + ('─' * [Math]::Max(0, $w - $t.Length - 5))) -ForegroundColor $Color
    }
}

function Write-Banner {
    try { Clear-Host } catch { }   # redirected console: no screen to clear
    Write-Host ''
    Write-Host '  ╔════════════════════════════════════════════════════════════════════════╗' -ForegroundColor $C.Frame
    Write-Host '  ║' -NoNewline -ForegroundColor $C.Frame
    Write-Host '   L L A M A   L A U N C H E R                                          ' -NoNewline -ForegroundColor $C.Title
    Write-Host '║' -ForegroundColor $C.Frame
    Write-Host '  ║' -NoNewline -ForegroundColor $C.Frame
    Write-Host '   parameters computed from the real model metadata                     ' -NoNewline -ForegroundColor $C.Dim
    Write-Host '║' -ForegroundColor $C.Frame
    Write-Host '  ╚════════════════════════════════════════════════════════════════════════╝' -ForegroundColor $C.Frame
    Write-Host ''
}

function Write-Field([string]$Label, [string]$Value, [string]$Color = 'White') {
    Write-Host ('   {0,-22}' -f $Label) -NoNewline -ForegroundColor $C.Dim
    Write-Host $Value -ForegroundColor $Color
}

function Write-Bar([int]$Used, [int]$Total, [int]$Width = 40) {
    if ($Total -le 0) { return }
    $pct = [Math]::Min(1.0, $Used / [double]$Total)
    $fill = [int][Math]::Round($pct * $Width)
    $col = $C.Ok
    if ($pct -gt 0.85) { $col = $C.Warn }
    if ($pct -gt 0.97) { $col = $C.Err }
    Write-Host '   [' -NoNewline -ForegroundColor $C.Dim
    Write-Host ('█' * $fill) -NoNewline -ForegroundColor $col
    Write-Host ('·' * ($Width - $fill)) -NoNewline -ForegroundColor $C.Dim
    Write-Host ('] {0,5:N1} / {1:N0} GB  ({2:P0})' -f ($Used / 1024), ($Total / 1024), $pct) -ForegroundColor $C.Dim
}

# ------------------------------------------------------- GGUF reader --
# Format: magic "GGUF" | version u32 | n_tensor u64 | n_kv u64 | kv...

$GgufFixedSize = @{ 0 = 1; 1 = 1; 2 = 2; 3 = 2; 4 = 4; 5 = 4; 6 = 4; 7 = 1; 10 = 8; 11 = 8; 12 = 8 }

function Read-GgufStr($br) {
    $len = $br.ReadUInt64()
    [System.Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$len))
}

function Read-GgufScalar($br, [int]$t) {
    switch ($t) {
        0  { return [int]$br.ReadByte() }
        1  { return [int]$br.ReadSByte() }
        2  { return [int]$br.ReadUInt16() }
        3  { return [int]$br.ReadInt16() }
        4  { return [int64]$br.ReadUInt32() }
        5  { return [int64]$br.ReadInt32() }
        6  { return [double]$br.ReadSingle() }
        7  { return [bool]$br.ReadByte() }
        8  { return (Read-GgufStr $br) }
        10 { return [int64]$br.ReadUInt64() }
        11 { return [int64]$br.ReadInt64() }
        12 { return [double]$br.ReadDouble() }
        default { throw "unsupported GGUF type: $t" }
    }
}

function Skip-GgufValue($br, [int]$t) {
    $s = $br.BaseStream
    if ($t -eq 8) { $len = $br.ReadUInt64(); [void]$s.Seek([int64]$len, 'Current'); return }
    if ($t -eq 9) {
        $at = [int]$br.ReadUInt32(); $n = $br.ReadUInt64()
        if ($at -eq 8) {
            for ($i = 0; $i -lt $n; $i++) { $l = $br.ReadUInt64(); [void]$s.Seek([int64]$l, 'Current') }
        } elseif ($at -eq 9) {
            for ($i = 0; $i -lt $n; $i++) { Skip-GgufValue $br 9 }
        } else {
            [void]$s.Seek([int64]($n * $GgufFixedSize[$at]), 'Current')
        }
        return
    }
    [void]$s.Seek([int64]$GgufFixedSize[$t], 'Current')
}

function Read-GgufValue($br, [int]$t) {
    if ($t -ne 9) { return (Read-GgufScalar $br $t) }
    $at = [int]$br.ReadUInt32(); $n = [int]$br.ReadUInt64()
    if ($at -eq 9) { Skip-GgufValue $br 9; return $null }
    if ($n -gt 4096) { # huge array (vocabulary): not needed
        if ($at -eq 8) { for ($i = 0; $i -lt $n; $i++) { $l = $br.ReadUInt64(); [void]$br.BaseStream.Seek([int64]$l, 'Current') } }
        else { [void]$br.BaseStream.Seek([int64]($n * $GgufFixedSize[$at]), 'Current') }
        return $null
    }
    $out = New-Object object[] $n
    for ($i = 0; $i -lt $n; $i++) { $out[$i] = Read-GgufScalar $br $at }
    return $out
}

# quantization type names (general.file_type)
$FileTypeNames = @{
    0='F32'; 1='F16'; 2='Q4_0'; 3='Q4_1'; 7='Q8_0'; 8='Q5_0'; 9='Q5_1'; 10='Q2_K'
    11='Q3_K_S'; 12='Q3_K_M'; 13='Q3_K_L'; 14='Q4_K_S'; 15='Q4_K_M'; 16='Q5_K_S'
    17='Q5_K_M'; 18='Q6_K'; 19='IQ2_XXS'; 20='IQ2_XS'; 21='Q2_K_S'; 22='IQ3_XS'
    23='IQ3_XXS'; 24='IQ1_S'; 25='IQ4_NL'; 26='IQ3_S'; 27='IQ3_M'; 28='IQ2_S'
    29='IQ2_M'; 30='IQ4_XS'; 31='IQ1_M'; 32='BF16'; 36='TQ1_0'; 37='TQ2_0'
    38='MXFP4'; 39='NVFP4'
}

# sampler presets per architecture family (source: official model docs)
# Qwen3 / Qwen3.8: https://unsloth.ai/docs/models/qwen3.8
$SamplerPresets = @{
    'qwen3' = @{
        Thinking    = @{ Temp = 1.0; TopP = 0.95; TopK = 20; MinP = 0.0; PresencePenalty = 0.0; RepeatPenalty = 1.0 }
        NonThinking = @{ Temp = 0.7; TopP = 0.80; TopK = 20; MinP = 0.0; PresencePenalty = 1.5; RepeatPenalty = 1.0 }
    }
}

function Get-GgufMeta([string]$Path) {
    $wanted = @(
        'general.architecture','general.file_type','general.parameter_count','general.name',
        '.block_count','.embedding_length','.attention.head_count','.attention.head_count_kv',
        '.expert_count','.expert_used_count','.context_length','.rope.freq_base',
        '.attention.key_length','.attention.value_length'
    )
    $kv = @{}
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    $bs = New-Object System.IO.BufferedStream($fs, 262144)
    $br = New-Object System.IO.BinaryReader($bs)
    try {
        if ($br.ReadUInt32() -ne 0x46554747) { return $null }   # 'GGUF'
        [void]$br.ReadUInt32()                                   # version
        $nTensor = $br.ReadUInt64()
        $nKv = $br.ReadUInt64()
        for ($i = 0; $i -lt $nKv; $i++) {
            $key = Read-GgufStr $br
            $t   = [int]$br.ReadUInt32()
            $keep = $false
            foreach ($w in $wanted) { if ($key -eq $w -or $key.EndsWith($w)) { $keep = $true; break } }
            if ($keep) { $kv[$key] = Read-GgufValue $br $t } else { Skip-GgufValue $br $t }
        }
        # walk the tensor names: if a native MTP head ("nextn") is found
        # the model can do speculative decoding without an external draft
        $hasMtp = $false
        for ($ti = 0; $ti -lt $nTensor; $ti++) {
            $tname = Read-GgufStr $br
            if ($tname -match '\.nextn\.') { $hasMtp = $true; break }
            $nDims = $br.ReadUInt32()
            for ($d = 0; $d -lt $nDims; $d++) { [void]$br.ReadUInt64() }
            [void]$br.ReadUInt32()   # ggml type
            [void]$br.ReadUInt64()   # offset
        }
    } finally { $br.Dispose(); $bs.Dispose(); $fs.Dispose() }

    function K($suffix) {
        foreach ($k in $kv.Keys) { if ($k -eq $suffix -or $k.EndsWith($suffix)) { return $kv[$k] } }
        return $null
    }
    $arch  = K 'general.architecture'
    $nHead = K '.attention.head_count'
    $nKvH  = K '.attention.head_count_kv'
    if ($nHead -is [array]) { $nHead = ($nHead | Measure-Object -Maximum).Maximum }
    if ($nKvH  -is [array]) { $nKvH  = ($nKvH  | Measure-Object -Maximum).Maximum }
    $ft = K 'general.file_type'
    $quant = 'unknown'
    if ($null -ne $ft -and $FileTypeNames.ContainsKey([int]$ft)) { $quant = $FileTypeNames[[int]$ft] }

    [pscustomobject]@{
        Arch      = $arch
        Quant     = $quant
        Params    = K 'general.parameter_count'
        NLayer    = [int](K '.block_count')
        NEmbd     = [int](K '.embedding_length')
        NHead     = [int]$nHead
        NHeadKv   = [int]$nKvH
        KeyLen    = [int](K '.attention.key_length')
        ValLen    = [int](K '.attention.value_length')
        NExpert   = [int](K '.expert_count')
        NExpertUsed = [int](K '.expert_used_count')
        CtxTrain  = [int64](K '.context_length')
        HasNativeMtp = $hasMtp
    }
}

function Get-MetaCached([System.IO.FileInfo]$File) {
    $cache = @{}
    if (Test-Path $CachePath) {
        try { (Get-Content $CachePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cache[$_.Name] = $_.Value } } catch { }
    }
    $key = '{0}|{1}|{2}' -f $File.FullName, $File.Length, $File.LastWriteTimeUtc.Ticks
    if ($cache.ContainsKey($key)) { return $cache[$key] }
    $meta = Get-GgufMeta $File.FullName
    if ($null -ne $meta) {
        $cache[$key] = $meta
        try { $cache | ConvertTo-Json -Depth 5 | Set-Content $CachePath -Encoding UTF8 } catch { }
    }
    return $meta
}

# ------------------------------------------------- find models --

function Get-Models {
    $dirs = @($ScriptDir)
    if ($cfg -and $cfg.ExtraDirs) { $dirs += $cfg.ExtraDirs }
    $dirs += (Join-Path $ScriptDir 'models')
    $dirs = $dirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $files = @()
    foreach ($d in $dirs) {
        $files += Get-ChildItem -Path $d -Filter '*.gguf' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue
    }
    $files = $files | Where-Object { $_.Name -notmatch 'mmproj|dflash|dspark' } | Sort-Object FullName -Unique

    # multi-file shards: keep only the first part, sum the sizes
    $out = @()
    $seen = @{}
    foreach ($f in $files) {
        if ($f.Name -match '^(?<base>.+)-(?<idx>\d{5})-of-(?<tot>\d{5})\.gguf$') {
            $base = $Matches.base
            if ($seen.ContainsKey($base)) { continue }
            if ([int]$Matches.idx -ne 1) { continue }
            $seen[$base] = $true
            $parts = Get-ChildItem -Path $f.DirectoryName -Filter "$base-*-of-*.gguf" -File
            $out += [pscustomobject]@{ File = $f; Name = $base; Bytes = ($parts | Measure-Object Length -Sum).Sum; Shards = $parts.Count }
        } else {
            $out += [pscustomobject]@{ File = $f; Name = $f.BaseName; Bytes = $f.Length; Shards = 1 }
        }
    }
    return $out | Sort-Object Name
}

# "draft" models for speculative decoding (DFlash/DSpark): same folder,
# name with "dflash"/"dspark", matched to the target by family prefix
# (e.g. "Qwen3.8-27B-Q4_K_M" <-> "Qwen3.8-27B-DFlash2-Q8_0")
function Get-DraftModels {
    $dirs = @($ScriptDir)
    if ($cfg -and $cfg.ExtraDirs) { $dirs += $cfg.ExtraDirs }
    $dirs += (Join-Path $ScriptDir 'models')
    $dirs = $dirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    $files = @()
    foreach ($d in $dirs) { $files += Get-ChildItem -Path $d -Filter '*.gguf' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue }
    return $files | Where-Object { $_.Name -match 'dflash|dspark' } | Sort-Object Name -Unique
}

function Get-ModelFamily([string]$Name) {
    if ($Name -match '^([A-Za-z0-9]+\.?[0-9]*-[0-9]+[A-Za-z]?)') { return $Matches[1] }
    return $Name
}

function Find-DraftFor($m, $drafts) {
    $fam = Get-ModelFamily $m.Name
    return $drafts | Where-Object { (Get-ModelFamily $_.BaseName) -eq $fam } | Select-Object -First 1
}

# ------------------------------------------------------- fit calc ---

$CacheBytes = @{ 'f16' = 2.0; 'q8_0' = 1.0625; 'q5_1' = 0.75; 'q4_0' = 0.5625 }

function Get-KvPerTokenMB($meta, [string]$cacheType) {
    if ($meta.NLayer -le 0 -or $meta.NEmbd -le 0) { return 0.0 }
    $headDim = $meta.KeyLen
    if ($headDim -le 0 -and $meta.NHead -gt 0) { $headDim = [int]($meta.NEmbd / $meta.NHead) }
    if ($headDim -le 0) { $headDim = 128 }
    $kvHeads = $meta.NHeadKv
    if ($kvHeads -le 0) { $kvHeads = $meta.NHead }
    if ($kvHeads -le 0) { $kvHeads = 8 }
    $embdKv = $headDim * $kvHeads
    $bpe = $CacheBytes[$cacheType]
    # K + V per layer
    return (2.0 * $meta.NLayer * $embdKv * $bpe) / 1MB
}

# VRAM split: weights per layer + KV per layer + compute buffer.
# ponytail: MoE expert share estimated at 80% of the layer; retunable
# by watching "load_tensors" in the log if the fit looks optimistic.
$MoeShare = 0.80

function Solve-Fit {
    param($m, $meta, [int]$Ctx, [string]$CacheType, [int]$VramMB, [int]$RamMB, [int]$UBatch = 512)

    $nl = $meta.NLayer
    $weightsMB = $m.Bytes / 1MB
    # embedding + output weigh about ~1 extra layer
    $perLayerMB = $weightsMB / ($nl + 1)
    $kvPerLayerMB = (Get-KvPerTokenMB $meta $CacheType) * $Ctx / $nl

    # compute buffer: logits + ubatch activation graph
    $computeMB = 320 + ($UBatch * $meta.NEmbd * 2 * 8) / 1MB
    $reserveMB = [Math]::Min(1400, $VramMB * 0.10)   # desktop, driver, other apps
    $availMB = $VramMB - $reserveMB - $computeMB

    $perLayerTotal = $perLayerMB + $kvPerLayerMB
    $ngl = [int][Math]::Floor($availMB / $perLayerTotal)
    if ($ngl -lt 0) { $ngl = 0 }
    $nCpuMoe = 0

    if ($ngl -ge $nl) {
        $ngl = $nl
    } elseif ($meta.NExpert -gt 0) {
        # MoE: better to keep all layers on GPU and move only the experts
        $needMB = ($nl * $perLayerTotal) - $availMB
        $freedPerLayer = $perLayerMB * $MoeShare
        $nCpuMoe = [int][Math]::Ceiling($needMB / $freedPerLayer)
        if ($nCpuMoe -ge $nl) { $nCpuMoe = $nl; $ngl = $nl }
        else { $ngl = $nl }
    }

    if ($ngl -ge $nl -and $nCpuMoe -eq 0) {
        $vramUsed = $nl * $perLayerTotal + $computeMB + 60
        $ramUsed = 300
    } elseif ($nCpuMoe -gt 0) {
        $vramUsed = ($nl * $perLayerTotal) - ($nCpuMoe * $perLayerMB * $MoeShare) + $computeMB + 60
        $ramUsed = ($nCpuMoe * $perLayerMB * $MoeShare) + 400
    } else {
        $vramUsed = $ngl * $perLayerTotal + $computeMB + 60
        $ramUsed = ($nl - $ngl) * $perLayerTotal + 400
    }

    [pscustomobject]@{
        Ngl = $ngl; NCpuMoe = $nCpuMoe; Ctx = $Ctx; CacheType = $CacheType
        VramMB = [int]$vramUsed; RamMB = [int]$ramUsed
        FullGpu = ($ngl -ge $nl -and $nCpuMoe -eq 0)
        FitsVram = ($vramUsed -le ($VramMB - $reserveMB * 0.5))
        FitsRam = ($ramUsed -le ($RamMB * 0.80))
        PerLayerMB = $perLayerMB; KvPerLayerMB = $kvPerLayerMB
    }
}

function Find-MaxCtx {
    param($m, $meta, [string]$CacheType, [int]$VramMB, [int]$RamMB, [int]$Cap = 0)
    $hi = [int]$meta.CtxTrain
    if ($hi -le 0) { $hi = 32768 }
    if ($Cap -gt 0) { $hi = [Math]::Min($hi, $Cap) }
    $lo = 1024
    $best = 0
    while ($lo -le $hi) {
        $mid = [int](([Math]::Floor((($lo + $hi) / 2) / 1024)) * 1024)
        if ($mid -lt 1024) { $mid = 1024 }
        $fit = Solve-Fit $m $meta $mid $CacheType $VramMB $RamMB
        if ($fit.FullGpu -and $fit.FitsVram) { $best = $mid; $lo = $mid + 1024 } else { $hi = $mid - 1024 }
    }
    return $best
}

# --------------------------------------------------------- profiles -----

function Get-Profiles($meta) {
    $trained = [int]$meta.CtxTrain
    if ($trained -le 0) { $trained = 32768 }
    @(
        [pscustomobject]@{ Id='1'; Name='FAST'; Desc='short chat, max speed'; Ctx=[Math]::Min(8192,$trained);   Cache='f16';  UBatch=512;  Batch=2048 }
        [pscustomobject]@{ Id='2'; Name='BALANCED'; Desc='normal use, code, prose'; Ctx=[Math]::Min(32768,$trained); Cache='q8_0'; UBatch=512;  Batch=2048 }
        [pscustomobject]@{ Id='3'; Name='LONG'; Desc='documents, repos, analysis';       Ctx=[Math]::Min(131072,$trained); Cache='q8_0'; UBatch=1024; Batch=4096 }
        [pscustomobject]@{ Id='4'; Name='MAX'; Desc='full trained context'; Ctx=$trained;                     Cache='q4_0'; UBatch=1024; Batch=4096 }
        [pscustomobject]@{ Id='5'; Name='AUTO-FIT'; Desc='largest ctx fully in VRAM'; Ctx=-1; Cache='q8_0'; UBatch=512; Batch=2048 }
        [pscustomobject]@{ Id='6'; Name='MANUAL'; Desc='pick the context yourself';        Ctx=-2; Cache='q8_0'; UBatch=512;  Batch=2048 }
    )
}

# --------------------------------------------- install llama.cpp --

function Find-Server {
    $cands = @()
    if ($cfg -and $cfg.ServerExe) { $cands += $cfg.ServerExe }
    $cands += Join-Path $ScriptDir 'llama-server.exe'
    $cands += Join-Path $ScriptDir 'llama.cpp\llama-server.exe'
    $cands += 'G:\LLAMA\llama-server.exe'
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path } }
    $cmd = Get-Command llama-server.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-ServerHelp([string]$exe) {
    try { return (& $exe --help 2>&1 | Out-String) } catch { return '' }
}

function Install-LlamaCpp {
    Write-Banner
    Write-Rule 'INSTALL / UPDATE llama.cpp'
    Write-Host ''
    $gpu = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '
    Write-Field 'GPUs detected' $gpu
    Write-Host ''
    Write-Host '   [1] CUDA   - NVIDIA (fastest, also downloads the CUDA runtime)' -ForegroundColor $C.Val
    Write-Host '   [2] Vulkan - AMD / Intel / generic NVIDIA' -ForegroundColor $C.Val
    Write-Host '   [3] CPU    - no GPU' -ForegroundColor $C.Val
    Write-Host '   [Q] cancel' -ForegroundColor $C.Key
    Write-Host ''
    $b = (Read-Host '   Backend').Trim().ToUpper()
    if ($b -eq 'Q') { return }
    $pattern = switch ($b) { '1' { 'bin-win-cuda' } '2' { 'bin-win-vulkan' } '3' { 'bin-win-cpu' } default { $null } }
    if (-not $pattern) { Write-Host '   invalid choice' -ForegroundColor $C.Err; Start-Sleep 2; return }

    Write-Host ''
    Write-Host '   Querying GitHub...' -ForegroundColor $C.Dim
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest' -Headers @{ 'User-Agent' = 'llama-launcher' }
    $asset = $rel.assets | Where-Object { $_.name -like "*$pattern*x64.zip" -and $_.name -notlike 'cudart*' } | Select-Object -First 1
    if (-not $asset) { Write-Host "   no '$pattern' package in release $($rel.tag_name)" -ForegroundColor $C.Err; Read-Host '   Enter'; return }

    $dest = Join-Path $ScriptDir 'llama.cpp'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $tmp = Join-Path $env:TEMP $asset.name
    Write-Host "   Downloading $($asset.name) ($([math]::Round($asset.size/1MB)) MB)..." -ForegroundColor $C.Title
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing
    Expand-Archive -Path $tmp -DestinationPath $dest -Force
    Remove-Item $tmp -Force

    if ($b -eq '1') {
        $cud = $rel.assets | Where-Object { $_.name -like 'cudart-*x64.zip' } | Select-Object -First 1
        if ($cud) {
            $tmp2 = Join-Path $env:TEMP $cud.name
            Write-Host "   Downloading $($cud.name)..." -ForegroundColor $C.Title
            Invoke-WebRequest -Uri $cud.browser_download_url -OutFile $tmp2 -UseBasicParsing
            Expand-Archive -Path $tmp2 -DestinationPath $dest -Force
            Remove-Item $tmp2 -Force
        }
    }

    # the package sometimes extracts into a subfolder: flatten it
    $exe = Get-ChildItem -Path $dest -Filter 'llama-server.exe' -Recurse -File | Select-Object -First 1
    if (-not $exe) { Write-Host '   llama-server.exe not found in the package' -ForegroundColor $C.Err; Read-Host '   Enter'; return }

    $cfg.ServerExe = $exe.FullName
    $cfg.ServerHelp = $null
    Save-Config
    Write-Host ''
    Write-Host "   Installed: $($exe.FullName)   [$($rel.tag_name)]" -ForegroundColor $C.Ok
    Read-Host '   press Enter to continue'
}

# ---------------------------------------------------- configuration ---

function Get-DetectedVram {
    try {
        $out = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return [int]([int]($out -split "`n")[0] / 1024) }
    } catch { }
    try {
        $v = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
             Where-Object { $_.AdapterRAM -gt 0 } | Sort-Object AdapterRAM -Descending | Select-Object -First 1
        if ($v) { return [int][Math]::Round($v.AdapterRAM / 1GB) }
    } catch { }
    return 0
}

function Save-Config { $cfg | ConvertTo-Json -Depth 4 | Set-Content $ConfigPath -Encoding UTF8 }

function Ask-Hardware {
    Write-Banner
    Write-Rule 'HARDWARE SETUP'
    Write-Host ''
    $sizes = @(4,6,8,10,11,12,16,20,24,32,40,48,64,80,96,128,192,256)
    $detV = Get-DetectedVram
    $detR = [int][Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $cores = 0
    try { $cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum } catch { }
    if ($cores -le 0) { $cores = [Environment]::ProcessorCount / 2 }

    Write-Host '   Video card VRAM (GB):' -ForegroundColor $C.Title
    Write-Host ''
    for ($i = 0; $i -lt $sizes.Count; $i += 6) {
        $row = ''
        for ($j = $i; $j -lt [Math]::Min($i + 6, $sizes.Count); $j++) {
            $row += ('  [{0,2}] {1,3} GB' -f ($j + 1), $sizes[$j])
        }
        Write-Host "  $row" -ForegroundColor $C.Val
    }
    Write-Host ''
    if ($detV -gt 0) { Write-Host "   detected: $detV GB  (Enter to accept)" -ForegroundColor $C.Ok }
    Write-Host '   You can also type the GB directly (4-256).' -ForegroundColor $C.Dim
    $ans = (Read-Host '   VRAM').Trim()
    $vram = 0
    if ($ans -eq '' -and $detV -gt 0) { $vram = $detV }
    elseif ($ans -match '^\d+$') {
        $n = [int]$ans
        if ($n -ge 1 -and $n -le $sizes.Count -and $n -lt 4) { $vram = $sizes[$n - 1] }
        elseif ($n -ge 4 -and $n -le 256) { $vram = $n }
        elseif ($n -ge 1 -and $n -le $sizes.Count) { $vram = $sizes[$n - 1] }
    }
    if ($vram -lt 1) { $vram = if ($detV -gt 0) { $detV } else { 8 } }

    Write-Host ''
    Write-Host "   System RAM in GB (detected: $detR, Enter to accept):" -ForegroundColor $C.Title
    $ansR = (Read-Host '   RAM').Trim()
    $ram = $detR
    if ($ansR -match '^\d+$' -and [int]$ansR -ge 2) { $ram = [int]$ansR }

    Write-Host ''
    Write-Host "   Physical CPU cores (detected: $cores, Enter to accept):" -ForegroundColor $C.Title
    $ansC = (Read-Host '   Core').Trim()
    if ($ansC -match '^\d+$' -and [int]$ansC -ge 1) { $cores = [int]$ansC }

    $cfg.VramGB = $vram
    $cfg.RamGB = $ram
    $cfg.Cores = [int]$cores
    Save-Config

    Write-Host ''
    Write-Field 'VRAM' "$vram GB" $C.Ok
    Write-Field 'RAM' "$ram GB" $C.Ok
    Write-Field 'Physical cores' "$cores" $C.Ok
    Write-Host ''
    Read-Host '   press Enter to continue'
}

# --------------------------------------------------------- launch -------

function Get-ArgList {
    param($m, $meta, $fit, $prof, [string]$help, [int]$Port, [int]$Threads, [bool]$Hybrid,
          [hashtable]$Sampler = $null, [string]$Reasoning = $null, [string]$ReasoningEffort = $null,
          [string]$DraftModel = $null, [string]$SpecType = $null)

    $a = @('-m', $m.File.FullName, '--host', '127.0.0.1', '--port', "$Port")
    $a += @('-ngl', "$($fit.Ngl)", '-c', "$($fit.Ctx)", '-b', "$($prof.Batch)", '-ub', "$($prof.UBatch)")
    $a += @('-t', "$Threads", '-tb', "$Threads")

    if ($help -match '--flash-attn') {
        if ($help -match '--flash-attn\s*[,\s].{0,60}(on\|off|auto)') { $a += @('--flash-attn', 'on') } else { $a += '--flash-attn' }
    }
    if ($fit.CacheType -ne 'f16' -and $help -match '--cache-type-k') {
        $a += @('--cache-type-k', $fit.CacheType, '--cache-type-v', $fit.CacheType)
    }
    if ($fit.NCpuMoe -gt 0) {
        if ($help -match '--n-cpu-moe') { $a += @('--n-cpu-moe', "$($fit.NCpuMoe)") }
        elseif ($help -match '--override-tensor') { $a += @('--override-tensor', 'ffn_(up|down|gate)_exps=CPU') }
    }
    # mlock is only useful when part stays in RAM and RAM is plentiful
    if ($Hybrid -and ($fit.RamMB -lt $cfg.RamGB * 1024 * 0.6)) {
        if ($help -match '--load-mode') { $a += @('--load-mode', 'mlock') }
        elseif ($help -match '--mlock') { $a += '--mlock' }
    }
    if ($help -match '--jinja') { $a += '--jinja' }
    if ($help -match '--no-warmup' -and $fit.Ctx -ge 65536) { $a += '--no-warmup' }
    if ($Sampler) {
        if ($help -match '--temp\b')             { $a += @('--temp', "$($Sampler.Temp)") }
        if ($help -match '--top-p\b')             { $a += @('--top-p', "$($Sampler.TopP)") }
        if ($help -match '--top-k\b')             { $a += @('--top-k', "$($Sampler.TopK)") }
        if ($help -match '--min-p\b')             { $a += @('--min-p', "$($Sampler.MinP)") }
        if ($help -match '--presence-penalty\b')  { $a += @('--presence-penalty', "$($Sampler.PresencePenalty)") }
        if ($help -match '--repeat-penalty\b')    { $a += @('--repeat-penalty', "$($Sampler.RepeatPenalty)") }
    }
    if ($Reasoning -and $help -match '--reasoning\b') { $a += @('--reasoning', $Reasoning) }
    if ($ReasoningEffort -and $help -match '--chat-template-kwargs') {
        $a += @('--chat-template-kwargs', "{`"reasoning_effort`":`"$ReasoningEffort`"}")
    }
    if ($DraftModel -and $help -match '--spec-draft-model') {
        $a += @('--spec-draft-model', $DraftModel)
        if ($help -match '--spec-type') {
            $specKind = if ($DraftModel -match 'dspark') { 'draft-dspark' } else { 'draft-dflash' }
            $a += @('--spec-type', $specKind)
        }
        if ($help -match '--spec-draft-ngl') { $a += @('--spec-draft-ngl', 'all') }
    } elseif ($SpecType -and $help -match '--spec-type') {
        # self-speculative: MTP head already in the model weights, no draft file
        $a += @('--spec-type', $SpecType)
    }
    $a += @('--alias', 'local-model', '-n', '-1')
    return $a
}

function Wait-Health([int]$Port, [int]$Seconds, [string]$LogFile, $Proc = $null) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $spin = '|/-\'
    $i = 0
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { Write-Host "`r   load complete in $([int]$sw.Elapsed.TotalSeconds)s          " -ForegroundColor $C.Ok; return $true }
        } catch { }
        if ($Proc -and $Proc.HasExited) {
            Write-Host "`r   process exited after $([int]$sw.Elapsed.TotalSeconds)s (crash on startup)          " -ForegroundColor $C.Err
            return $false
        }
        Write-Host ("`r   {0} loading... {1,3}s" -f $spin[$i % 4], [int]$sw.Elapsed.TotalSeconds) -NoNewline -ForegroundColor $C.Dim
        $i++
        Start-Sleep -Milliseconds 700
    }
    Write-Host ''
    return $false
}

function Show-Plan($m, $meta, $fit, $prof, $threads, $argList, [int]$Port) {
    Write-Host ''
    Write-Rule 'LAUNCH PLAN'
    Write-Host ''
    Write-Field 'Model' $m.Name $C.Title
    Write-Field 'Architecture' ("{0}  |  quant {1}  |  {2} layer" -f $meta.Arch, $meta.Quant, $meta.NLayer)
    if ($meta.NExpert -gt 0) { Write-Field 'MoE' ("{0} experts, {1} active per token" -f $meta.NExpert, $meta.NExpertUsed) $C.Title }
    Write-Field 'Profile' ("{0} - {1}" -f $prof.Name, $prof.Desc) $C.Title
    Write-Host ''
    Write-Field 'Context' ("{0:N0} token (max addestrato {1:N0})" -f $fit.Ctx, $meta.CtxTrain)
    Write-Field 'Layers on GPU' ("{0} / {1}" -f $fit.Ngl, $meta.NLayer) $(if ($fit.Ngl -ge $meta.NLayer) { $C.Ok } else { $C.Warn })
    if ($fit.NCpuMoe -gt 0) { Write-Field 'Experts on CPU' ("{0} layers (--n-cpu-moe)" -f $fit.NCpuMoe) $C.Warn }
    Write-Field 'KV cache' ("{0}  ({1:N0} MB per {2:N0} token)" -f $fit.CacheType, ($fit.KvPerLayerMB * $meta.NLayer), $fit.Ctx)
    Write-Field 'Batch / ubatch' ("{0} / {1}" -f $prof.Batch, $prof.UBatch)
    Write-Field 'Thread' "$threads"
    Write-Field 'Port' "http://127.0.0.1:$Port"
    Write-Host ''
    Write-Host '   Estimated VRAM' -ForegroundColor $C.Dim
    Write-Bar $fit.VramMB ($cfg.VramGB * 1024)
    Write-Host '   Estimated RAM ' -ForegroundColor $C.Dim
    Write-Bar $fit.RamMB ($cfg.RamGB * 1024)
    Write-Host ''
    if (-not $fit.FitsVram) { Write-Host '   ! model does not fit: partial offload will be used, reduced speed' -ForegroundColor $C.Warn }
    if (-not $fit.FitsRam)  { Write-Host '   ! not enough RAM for the CPU part: swap risk' -ForegroundColor $C.Err }
    Write-Rule
    Write-Host ('   ' + ($argList -join ' ')) -ForegroundColor $C.Dim
    Write-Host ''
}

function Start-Model($m, $meta, $fit, $prof, [string]$exe, [string]$help, [int]$Port,
                      [hashtable]$Sampler = $null, [string]$Reasoning = $null, [string]$ReasoningEffort = $null,
                      [string]$DraftModel = $null, [string]$SpecType = $null) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $log = Join-Path $LogDir ("{0}.log" -f $m.Name)
    $hybrid = -not $fit.FullGpu
    $threads = if ($hybrid) { [Math]::Max(1, $cfg.Cores - 1) } else { [Math]::Min(8, $cfg.Cores) }
    $argList = Get-ArgList $m $meta $fit $prof $help $Port $threads $hybrid $Sampler $Reasoning $ReasoningEffort $DraftModel $SpecType

    Show-Plan $m $meta $fit $prof $threads $argList $Port
    $go = (Read-Host '   [Enter] start   [n] cancel').Trim().ToLower()
    if ($go -eq 'n') { return $false }

    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 600
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Minimized `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru

    Write-Host ''
    if (-not (Wait-Health $Port 300 $log $proc)) {
        Write-Host '   the server is not responding. Last log lines:' -ForegroundColor $C.Err
        if (Test-Path "$log.err") { Get-Content "$log.err" -Tail 15 | ForEach-Object { Write-Host "     $_" -ForegroundColor $C.Dim } }
        Read-Host '   Enter'
        return $false
    }
    Write-Host ''
    Write-Host "   Server ready:   http://127.0.0.1:$Port" -ForegroundColor $C.Ok
    Write-Host "   Web UI:         http://127.0.0.1:$Port" -ForegroundColor $C.Ok
    Write-Host "   Log:            $log" -ForegroundColor $C.Dim
    Write-Host ''
    return $true
}

# ----------------------------------------------------------- menu ------

function Show-ModelList($models, $metas) {
    Write-Banner
    $srv = Find-Server
    Write-Field 'llama-server' $(if ($srv) { $srv } else { 'NOT FOUND - press [I] to install it' }) $(if ($srv) { $C.Ok } else { $C.Err })
    Write-Field 'Hardware' ("VRAM {0} GB  |  RAM {1} GB  |  {2} core" -f $cfg.VramGB, $cfg.RamGB, $cfg.Cores)
    Write-Field 'Folder' $ScriptDir
    Write-Host ''
    Write-Rule ("MODELS FOUND: {0}" -f $models.Count)
    Write-Host ''
    Write-Host '    #  model                                          size quant    layer    ctx max  fit' -ForegroundColor $C.Dim
    Write-Host '   ───────────────────────────────────────────────────────────────────────────────────' -ForegroundColor $C.Frame
    for ($i = 0; $i -lt $models.Count; $i++) {
        $m = $models[$i]; $meta = $metas[$i]
        $name = $m.Name
        if ($name.Length -gt 40) { $name = $name.Substring(0, 37) + '...' }
        $gb = $m.Bytes / 1GB
        if ($null -eq $meta) {
            Write-Host ('   {0,2}. {1,-42} {2,5:N1}G  {3}' -f ($i + 1), $name, $gb, 'unreadable GGUF') -ForegroundColor $C.Err
            continue
        }
        $fit = Solve-Fit $m $meta ([Math]::Min(8192, [int]$meta.CtxTrain)) 'q8_0' ($cfg.VramGB * 1024) ($cfg.RamGB * 1024)
        $badge = '  partial'; $bcol = $C.Warn
        if ($fit.FullGpu) { $badge = '  full GPU'; $bcol = $C.Ok }
        elseif ($fit.NCpuMoe -gt 0) { $badge = '  MoE->CPU'; $bcol = $C.Title }
        if (-not $fit.FitsRam) { $badge = '  too large'; $bcol = $C.Err }
        $moe = if ($meta.NExpert -gt 0) { '*' } else { ' ' }
        Write-Host ('   {0,2}. ' -f ($i + 1)) -NoNewline -ForegroundColor $C.Key
        Write-Host ('{0,-42}' -f $name) -NoNewline -ForegroundColor $C.Val
        Write-Host ('{0,5:N1}G  {1,-7}{2} {3,4}  {4,9:N0}' -f $gb, $meta.Quant, $moe, $meta.NLayer, $meta.CtxTrain) -NoNewline -ForegroundColor $C.Dim
        Write-Host $badge -ForegroundColor $bcol
    }
    Write-Host ''
    Write-Host '   * = MoE model (experts can be moved to CPU)' -ForegroundColor $C.Dim
    Write-Rule
    Write-Host '   [1-9] start model      [K] stop the active servers   [H] hardware' -ForegroundColor $C.Key
    Write-Host '   [I]   install/update llama.cpp                       [D] add model folder' -ForegroundColor $C.Key
    Write-Host '   [B]   benchmark model                               [Q] quit' -ForegroundColor $C.Key
    Write-Host ''
}

function Choose-Profile($m, $meta) {
    $vram = $cfg.VramGB * 1024; $ram = $cfg.RamGB * 1024
    $profs = Get-Profiles $meta
    Write-Host ''
    Write-Rule ("PROFILE FOR: {0}" -f $m.Name)
    Write-Host ''
    foreach ($p in $profs) {
        if ($p.Ctx -eq -2) {
            Write-Host ('   [{0}] {1,-11} {2}' -f $p.Id, $p.Name, $p.Desc) -ForegroundColor $C.Val
            continue
        }
        $ctx = $p.Ctx
        if ($ctx -eq -1) { $ctx = Find-MaxCtx $m $meta $p.Cache $vram $ram }
        if ($ctx -le 0) {
            Write-Host ('   [{0}] {1,-11} {2,-34} does not fit in VRAM' -f $p.Id, $p.Name, $p.Desc) -ForegroundColor $C.Err
            continue
        }
        $fit = Solve-Fit $m $meta $ctx $p.Cache $vram $ram $p.UBatch
        $tag = 'CPU+GPU'; $col = $C.Warn
        if ($fit.FullGpu) { $tag = 'GPU'; $col = $C.Ok }
        elseif ($fit.NCpuMoe -gt 0) { $tag = "MoE:$($fit.NCpuMoe)"; $col = $C.Title }
        Write-Host ('   [{0}] ' -f $p.Id) -NoNewline -ForegroundColor $C.Key
        Write-Host ('{0,-11}' -f $p.Name) -NoNewline -ForegroundColor $C.Val
        Write-Host ('{0,-32}' -f $p.Desc) -NoNewline -ForegroundColor $C.Dim
        Write-Host ('ctx {0,7:N0}  kv {1,-5} {2,5:N1}GB VRAM  ' -f $ctx, $fit.CacheType, ($fit.VramMB / 1024)) -NoNewline -ForegroundColor $C.Dim
        Write-Host $tag -ForegroundColor $col
    }
    Write-Host ''
    $sel = (Read-Host '   Profile [1-6, Enter=2]').Trim()
    if ($sel -eq '') { $sel = '2' }
    $p = $profs | Where-Object { $_.Id -eq $sel } | Select-Object -First 1
    if (-not $p) { return $null }

    $ctx = $p.Ctx
    if ($ctx -eq -1) { $ctx = Find-MaxCtx $m $meta $p.Cache $vram $ram }
    if ($ctx -eq -2) {
        $maxFull = Find-MaxCtx $m $meta 'q8_0' $vram $ram
        Write-Host "   max fully in VRAM with q8_0 cache: $maxFull tokens" -ForegroundColor $C.Dim
        $c = (Read-Host '   Context size in tokens').Trim()
        if ($c -match '^\d+$') { $ctx = [int]$c } else { return $null }
        $k = (Read-Host '   KV cache [f16/q8_0/q4_0, Enter=q8_0]').Trim().ToLower()
        if ($CacheBytes.ContainsKey($k)) { $p.Cache = $k }
    }
    if ($ctx -le 0) { Write-Host '   invalid context' -ForegroundColor $C.Err; Start-Sleep 2; return $null }

    $fit = Solve-Fit $m $meta $ctx $p.Cache $vram $ram $p.UBatch
    # automatic cache downgrade if it does not fit
    foreach ($ct in @('q8_0','q4_0')) {
        if ($fit.FullGpu -or $fit.NCpuMoe -gt 0) { break }
        $try = Solve-Fit $m $meta $ctx $ct $vram $ram $p.UBatch
        if ($try.Ngl -gt $fit.Ngl) { $fit = $try; $p.Cache = $ct }
    }

    $sampler = $null; $reasoning = $null; $reasoningEffort = $null
    if ($meta.Arch -match 'qwen3') {
        Write-Host ''
        Write-Rule 'QWEN3 MODE'
        Write-Host '   [1] Thinking    explicit reasoning, slower     (temp 1.0, top_p .95, top_k 20)' -ForegroundColor $C.Val
        Write-Host '   [2] Instruct    direct answer, faster          (temp 0.7, top_p .80, presence_penalty 1.5)' -ForegroundColor $C.Val
        Write-Host '   [Enter] auto    let the chat template decide' -ForegroundColor $C.Dim
        $mm = (Read-Host '   Mode [1/2, Enter=auto]').Trim()
        switch ($mm) {
            '1' { $sampler = $SamplerPresets.qwen3.Thinking; $reasoning = 'on' }
            '2' { $sampler = $SamplerPresets.qwen3.NonThinking; $reasoning = 'off' }
            default { $reasoning = 'auto' }
        }
        if ($sampler -and $reasoning -eq 'on' -and $cfg.ServerHelp -match '--chat-template-kwargs') {
            $eff = (Read-Host '   Reasoning effort [xhigh/high/medium/low/none, Enter=model default]').Trim().ToLower()
            if ($eff -in @('xhigh', 'high', 'medium', 'low', 'none')) { $reasoningEffort = $eff }
        }
    }

    $draftModel = $null; $specType = $null
    $cand = Find-DraftFor $m (Get-DraftModels)
    $specOptions = @()
    if ($cand) { $specOptions += [pscustomobject]@{ Key = '1'; Label = ("External draft: {0} ({1:N1} GB)" -f $cand.Name, ($cand.Length / 1GB)); Kind = 'external' } }
    if ($meta.HasNativeMtp) { $specOptions += [pscustomobject]@{ Key = "$($specOptions.Count + 1)"; Label = 'Native MTP (no external file, uses the head already in the model)'; Kind = 'native' } }
    if ($specOptions.Count -gt 0) {
        Write-Host ''
        Write-Rule 'SPECULATIVE DECODING'
        foreach ($so in $specOptions) {
            Write-Host ('   [{0}] ' -f $so.Key) -NoNewline -ForegroundColor $C.Key
            Write-Host $so.Label -ForegroundColor $C.Val
        }
        Write-Host '   [Enter] none (no risk, normal behavior)' -ForegroundColor $C.Dim
        $sc = (Read-Host '   Choice [Enter=none]').Trim()
        $chosen = $specOptions | Where-Object { $_.Key -eq $sc } | Select-Object -First 1
        if ($chosen) {
            if ($chosen.Kind -eq 'external') { $draftModel = $cand.FullName } else { $specType = 'draft-mtp' }
        }
    }

    return @{ Fit = $fit; Profile = $p; Sampler = $sampler; Reasoning = $reasoning; ReasoningEffort = $reasoningEffort; DraftModel = $draftModel; SpecType = $specType }
}

function Invoke-Bench($models, $metas) {
    $exe = Find-Server
    if (-not $exe) { return }
    $bench = Join-Path (Split-Path $exe) 'llama-bench.exe'
    if (-not (Test-Path $bench)) { Write-Host '   llama-bench.exe not present' -ForegroundColor $C.Err; Read-Host; return }
    $i = (Read-Host '   Number of the model to test').Trim()
    if ($i -notmatch '^\d+$' -or [int]$i -lt 1 -or [int]$i -gt $models.Count) { return }
    $idx = [int]$i - 1
    $m = $models[$idx]; $meta = $metas[$idx]
    $fit = Solve-Fit $m $meta ([Math]::Min(8192, [int]$meta.CtxTrain)) 'q8_0' ($cfg.VramGB * 1024) ($cfg.RamGB * 1024)
    Write-Host ''
    Write-Host "   llama-bench with -ngl $($fit.Ngl) (pp512 = prompt, tg128 = generation)" -ForegroundColor $C.Dim
    Write-Host ''
    & $bench -m $m.File.FullName -ngl $fit.Ngl -p 512 -n 128 -r 2
    Write-Host ''
    Read-Host '   Enter'
}

# ------------------------------------------------------------ main -----

$cfg = [pscustomobject]@{ VramGB = 0; RamGB = 0; Cores = 0; ServerExe = $null; ServerHelp = $null; ExtraDirs = @() }
if (Test-Path $ConfigPath) {
    try {
        $loaded = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    } catch { }
}
if ($SelfTest) {
    # minimal check: real GGUF parsing + fit computation consistency
    if (-not $cfg.VramGB) { $cfg.VramGB = 10; $cfg.RamGB = 32; $cfg.Cores = 8 }
    $models = @(Get-Models)
    if ($models.Count -eq 0) { throw 'self-test: no .gguf found' }
    $vram = $cfg.VramGB * 1024; $ram = $cfg.RamGB * 1024
    foreach ($m in $models) {
        $meta = Get-MetaCached $m.File
        if ($null -eq $meta) { throw "self-test: unreadable metadata $($m.Name)" }
        if ($meta.NLayer -le 0 -or $meta.NEmbd -le 0) { throw "self-test: absurd dimensions $($m.Name)" }
        $small = Solve-Fit $m $meta 4096   'q8_0' $vram $ram
        $big   = Solve-Fit $m $meta 131072 'q8_0' $vram $ram
        if ($big.Ngl -gt $small.Ngl) { throw "self-test: larger ctx cannot increase ngl ($($m.Name))" }
        if ($big.VramMB -lt $small.VramMB -and $small.FullGpu -and $big.FullGpu) { throw "self-test: VRAM not monotonic ($($m.Name))" }
        if ((Get-KvPerTokenMB $meta 'q4_0') -ge (Get-KvPerTokenMB $meta 'f16')) { throw "self-test: q4_0 must weigh less than f16 ($($m.Name))" }
        $f16 = Solve-Fit $m $meta 8192 'f16'  $vram $ram
        $q4  = Solve-Fit $m $meta 8192 'q4_0' $vram $ram
        if ($q4.Ngl -lt $f16.Ngl) { throw "self-test: lighter cache cannot reduce GPU layers ($($m.Name))" }
        $mx = Find-MaxCtx $m $meta 'q8_0' $vram $ram
        if ($mx -gt 0) {
            $fit = Solve-Fit $m $meta $mx 'q8_0' $vram $ram
            if (-not $fit.FullGpu) { throw "self-test: Find-MaxCtx returned a non full-GPU ctx ($($m.Name))" }
        }
        '{0,-52} {1,-8} L{2,-4} kv/tok {3,6:N3} MB  maxctx {4,7:N0}' -f `
            $m.Name.Substring(0, [Math]::Min(50, $m.Name.Length)), $meta.Quant, $meta.NLayer, (Get-KvPerTokenMB $meta 'q8_0'), $mx
    }
    # argument building: check on a model that needs offload
    $exe = Find-Server
    if ($exe) {
        $help = Get-ServerHelp $exe
        foreach ($m in $models) {
            $meta = Get-MetaCached $m.File
            $prof = (Get-Profiles $meta)[1]
            $fit  = Solve-Fit $m $meta ([Math]::Min(32768, [int]$meta.CtxTrain)) 'q8_0' $vram $ram $prof.UBatch
            $al   = Get-ArgList $m $meta $fit $prof $help 1234 8 (-not $fit.FullGpu)
            $s = $al -join ' '
            if ($s -notmatch '-ngl \d+') { throw "self-test: -ngl missing ($($m.Name))" }
            if ($s -notmatch '-c \d+')   { throw "self-test: -c missing ($($m.Name))" }
            if ($fit.CacheType -ne 'f16' -and $s -notmatch 'cache-type-k') { throw "self-test: cache-type missing ($($m.Name))" }
            if ($fit.NCpuMoe -gt 0 -and $s -notmatch 'n-cpu-moe|override-tensor') { throw "self-test: MoE offload not passed ($($m.Name))" }
            '  args: {0}' -f ($s -replace [regex]::Escape($m.File.FullName), '<model>')

            if ($meta.Arch -match 'qwen3') {
                $alQ = Get-ArgList $m $meta $fit $prof $help 1234 8 (-not $fit.FullGpu) $SamplerPresets.qwen3.NonThinking 'off' 'medium'
                $sq = $alQ -join ' '
                if ($sq -notmatch '--temp 0\.7') { throw "self-test: qwen3 sampler preset not applied ($($m.Name))" }
                if ($sq -notmatch '--reasoning off') { throw "self-test: --reasoning not passed ($($m.Name))" }
                if ($help -match '--chat-template-kwargs' -and $sq -notmatch 'reasoning_effort') { throw "self-test: reasoning_effort not passed ($($m.Name))" }

                $alD = Get-ArgList $m $meta $fit $prof $help 1234 8 (-not $fit.FullGpu) $null $null $null 'C:\fake\draft-dflash.gguf'
                $sd = $alD -join ' '
                if ($help -match '--spec-draft-model' -and $sd -notmatch '--spec-draft-model') { throw "self-test: draft model not passed ($($m.Name))" }
                if ($help -match '--spec-type' -and $sd -notmatch '--spec-type draft-dflash') { throw "self-test: spec-type draft-dflash not passed ($($m.Name))" }

                if ($meta.HasNativeMtp) {
                    $alM = Get-ArgList $m $meta $fit $prof $help 1234 8 (-not $fit.FullGpu) $null $null $null $null 'draft-mtp'
                    $sm = $alM -join ' '
                    if ($sm -match '--spec-draft-model') { throw "self-test: native draft-mtp must not pass --spec-draft-model ($($m.Name))" }
                    if ($help -match '--spec-type' -and $sm -notmatch '--spec-type draft-mtp') { throw "self-test: spec-type draft-mtp not passed ($($m.Name))" }
                }
            }
        }
    }

    # target <-> DFlash/DSpark draft matching by family prefix
    if ((Get-ModelFamily 'Qwen3.8-27B-Q4_K_M') -ne (Get-ModelFamily 'Qwen3.8-27B-DFlash2-Q8_0')) {
        throw 'self-test: target/draft DFlash family matching does not work'
    }
    Write-Host 'self-test OK' -ForegroundColor Green
    exit 0
}

if (-not $cfg.VramGB -or $cfg.VramGB -lt 1) { Ask-Hardware }

while ($true) {
    $models = @(Get-Models)
    if ($models.Count -eq 0) {
        Write-Banner
        Write-Host "   No .gguf file found in:" -ForegroundColor $C.Err
        Write-Host "     $ScriptDir" -ForegroundColor $C.Dim
        Write-Host ''
        Write-Host '   [D] set the model folder               [Q] quit' -ForegroundColor $C.Key
        $a = (Read-Host '   >').Trim().ToUpper()
        if ($a -eq 'Q') { exit 0 }
        if ($a -eq 'D') {
            $d = (Read-Host '   Path').Trim('"').Trim()
            if (Test-Path $d) { $cfg.ExtraDirs = @($cfg.ExtraDirs + $d | Where-Object { $_ } | Select-Object -Unique); Save-Config }
        }
        continue
    }

    Write-Host '   reading GGUF metadata...' -ForegroundColor $C.Dim
    $metas = @()
    foreach ($m in $models) { try { $metas += (Get-MetaCached $m.File) } catch { $metas += $null } }

    Show-ModelList $models $metas
    $sel = (Read-Host '   >').Trim().ToUpper()

    switch -Regex ($sel) {
        '^Q$' { exit 0 }
        '^K$' {
            $p = Get-Process llama-server -ErrorAction SilentlyContinue
            if ($p) { $p | Stop-Process -Force; Write-Host "   $($p.Count) server(s) stopped." -ForegroundColor $C.Warn }
            else { Write-Host '   no active server.' -ForegroundColor $C.Dim }
            Start-Sleep 1
        }
        '^H$' { Ask-Hardware }
        '^I$' { Install-LlamaCpp }
        '^B$' { Invoke-Bench $models $metas }
        '^D$' {
            $d = (Read-Host '   Path of the model folder').Trim('"').Trim()
            if (Test-Path $d) { $cfg.ExtraDirs = @(@($cfg.ExtraDirs) + $d | Where-Object { $_ } | Select-Object -Unique); Save-Config }
            else { Write-Host '   path does not exist' -ForegroundColor $C.Err; Start-Sleep 2 }
        }
        '^\d+$' {
            $idx = [int]$sel - 1
            if ($idx -lt 0 -or $idx -ge $models.Count) { continue }
            $meta = $metas[$idx]
            if ($null -eq $meta) { Write-Host '   unreadable metadata for this file' -ForegroundColor $C.Err; Start-Sleep 2; continue }
            $exe = Find-Server
            if (-not $exe) { Write-Host '   llama-server not found: use [I] to install it' -ForegroundColor $C.Err; Start-Sleep 2; continue }
            if (-not $cfg.ServerHelp) { $cfg.ServerHelp = Get-ServerHelp $exe; Save-Config }
            $choice = Choose-Profile $models[$idx] $meta
            if ($null -eq $choice) { continue }
            if (Start-Model $models[$idx] $meta $choice.Fit $choice.Profile $exe $cfg.ServerHelp $BasePort $choice.Sampler $choice.Reasoning $choice.ReasoningEffort $choice.DraftModel $choice.SpecType) {
                Write-Host '   [Enter] back to the menu   [Q] quit leaving the server running' -ForegroundColor $C.Key
                if ((Read-Host '   >').Trim().ToUpper() -eq 'Q') { exit 0 }
            }
        }
        default { }
    }
}

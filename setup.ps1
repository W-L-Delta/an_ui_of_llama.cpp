# ============================================================
#  llama-local-chat 一键安装
#
#  用法（在项目根目录）：
#     powershell -ExecutionPolicy Bypass -File setup.ps1
#     powershell -ExecutionPolicy Bypass -File setup.ps1 -Model D:\models\qwen3-8b-q4.gguf -VramGb 8
#
#  它会：
#     1. 检查环境（PowerShell / .NET 编译器 / 显卡）
#     2. 下载 llama.cpp 二进制（GitHub，失败自动换镜像）
#     3. 下载 WebView2 托管库（NuGet）
#     4. 编译 chat-app\llama-chat.exe
#     5. 生成 scripts\llama.conf.ini
#     6. 自检（二进制、配置、外壳）
# ============================================================

[CmdletBinding()]
param(
    # 你的模型文件（.gguf）；不给就留占位，之后自己改配置
    [string]$Model = "",
    # 显存大小（GB），用来选默认的 ngl / 上下文
    [int]$VramGb = 8,
    # 计算后端：cuda（N 卡）或 vulkan（通用）
    [ValidateSet('auto', 'cuda', 'vulkan')]
    [string]$Backend = 'auto',
    # 下载加速前缀，可多个，用逗号分隔；空字符串表示直连
    [string]$Mirror = 'https://gh-proxy.com/,https://ghfast.top/',
    # 跳过分步（已有文件时用）
    [switch]$SkipDownload,
    [switch]$SkipBuild,
    # 只打印计划，不实际执行
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $Root 'panel\app.py'))) {
    # 脚本被放在根目录时的情形
    if (Test-Path (Join-Path $PSScriptRoot 'panel\app.py')) { $Root = $PSScriptRoot }
    else { throw "找不到项目根目录（panel\app.py 不存在）。请把 setup.ps1 放在项目根目录运行。" }
}

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Step($n, $msg) { Write-Host ""; Write-Host "[$n] $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "    OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    !!  $msg" -ForegroundColor Yellow }
function Die($msg) { Write-Host "    XX  $msg" -ForegroundColor Red; exit 1 }

function Invoke-WithMirror {
    param([string]$Url, [string]$OutFile, [string]$Label)
    $prefixes = @('')
    if ($Mirror) { $prefixes += ($Mirror -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $lastErr = $null
    foreach ($p in $prefixes) {
        $try = if ($p) { $p.TrimEnd('/') + '/' + $Url } else { $Url }
        $tag = if ($p) { "镜像 $p" } else { "直连" }
        try {
            Say "    下载 $Label（$tag）…"
            if ($DryRun) { Ok "（dry-run 跳过）"; return $true }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Invoke-WebRequest -Uri $try -OutFile $OutFile -TimeoutSec 1800 -UseBasicParsing
            $mb = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
            Ok ("下载完成 {0} MB / {1:N0} 秒" -f $mb, $sw.Elapsed.TotalSeconds)
            return $true
        } catch {
            $lastErr = $_.Exception.Message
            Warn "失败：$lastErr"
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
        }
    }
    Die "下载失败（所有源都不可用）：$lastErr"
}

# ------------------------------------------------------------ 1. 环境
Step 1 "检查环境"

$psv = $PSVersionTable.PSVersion
Ok "PowerShell $psv"

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { Die "找不到 csc.exe，需要 .NET Framework 4.x（Windows 自带）" }
Ok "C# 编译器就绪"

if (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') {
    Ok "WebView2 运行时已安装"
} else {
    Warn "未检测到 WebView2 运行时；Win11 自带，Win10 需要装 Evergreen Runtime"
}

$hasNvidia = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
if ($Backend -eq 'auto') { $Backend = if ($hasNvidia) { 'cuda' } else { 'vulkan' } }
Ok "计算后端：$Backend$(if ($hasNvidia) { '（检测到 NVIDIA 显卡）' } else { '' })"
if ($Backend -eq 'cuda' -and -not $hasNvidia) { Warn "选了 CUDA 但没找到 nvidia-smi，可能跑不起来；可改用 -Backend vulkan" }

# ------------------------------------------------------------ 2. llama.cpp
Step 2 "准备 llama.cpp 二进制"

$binDir = Join-Path $Root "bin\$Backend"
$serverExe = Join-Path $binDir 'llama-server.exe'
if (Test-Path $serverExe) {
    Ok "已存在：$serverExe"
} elseif ($SkipDownload) {
    Warn "指定了 -SkipDownload，跳过下载（此时缺 llama-server.exe）"
} else {
    # 注意：/releases/latest 有时指向没有二进制的版本（如 v1.0.0），
    # 所以按时间倒序列出，选第一个真正带 Windows 包的版本。
    $api = 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30'
    Say "    查询可用版本…"
    $pat = if ($Backend -eq 'cuda') { '-bin-win-cuda-\d+\.\d+-x64\.zip$' } else { '-bin-win-vulkan-x64\.zip$' }
    $rel = $null; $pkg = $null
    if (-not $DryRun) {
        foreach ($r in (Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'llama-local-chat-setup' } -TimeoutSec 60)) {
            $cand = $r.assets | Where-Object { $_.name -match $pat } | Select-Object -First 1
            if ($cand) { $rel = $r; $pkg = $cand; break }
        }
        if (-not $pkg) { Die "近 30 个版本里都没有 Windows $Backend 包，试试 -Backend vulkan" }
    }
    if ($rel) {
        $ver = $rel.tag_name
        Say "    使用的版本：$ver（$($pkg.name)）"
        $cudart = $null
        if ($Backend -eq 'cuda') {
            $cudart = $rel.assets | Where-Object { $_.name -match '^cudart-llama-bin-win-cuda' -and $_.name -match 'x64\.zip$' } |
                Select-Object -First 1
        }
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        $tmp = Join-Path $env:TEMP $pkg.name
        Invoke-WithMirror -Url $pkg.browser_download_url -OutFile $tmp -Label $pkg.name | Out-Null
        if (-not $DryRun) {
            Say "    解压…"
            Expand-Archive -Path $tmp -DestinationPath $binDir -Force
            Remove-Item $tmp -Force
        }
        if ($cudart) {
            $tmp2 = Join-Path $env:TEMP $cudart.name
            Invoke-WithMirror -Url $cudart.browser_download_url -OutFile $tmp2 -Label $cudart.name | Out-Null
            if (-not $DryRun) {
                Expand-Archive -Path $tmp2 -DestinationPath $binDir -Force
                Remove-Item $tmp2 -Force
            }
        }
        Ok "解压到 bin\$Backend"
    } else {
        Say "    （dry-run：跳过实际下载）"
    }
}

# ------------------------------------------------------------ 3. WebView2 库
Step 3 "准备 WebView2 托管库"

$wvDir = Join-Path $Root 'chat-app\lib'
$needWv = -not (Test-Path (Join-Path $wvDir 'Microsoft.Web.WebView2.Core.dll')) -or
          -not (Test-Path (Join-Path $wvDir 'WebView2Loader.dll'))
if (-not $needWv) {
    Ok "已存在：chat-app\lib"
} elseif ($SkipDownload) {
    Warn "缺 WebView2 托管库但指定了 -SkipDownload，已跳过（编译会失败）"
} else {
    $nuget = 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json'
    Say "    查询 NuGet 版本…"
    $ver = if ($DryRun) { '1.0.0' } else {
        $idx = Invoke-RestMethod -Uri $nuget -TimeoutSec 60
        ($idx.versions | Where-Object { $_ -match '^\d+\.\d+\.\d+(\.\d+)?$' } | Select-Object -Last 1)
    }
    Say "    版本：$ver"
    $nupkg = Join-Path $env:TEMP "webview2.$ver.zip"
    $url = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$ver"
    Invoke-WithMirror -Url $url -OutFile $nupkg -Label "Microsoft.Web.WebView2 $ver" | Out-Null
    if (-not $DryRun) {
        $ex = Join-Path $env:TEMP "webview2.$ver"
        Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $nupkg -DestinationPath $ex -Force
        New-Item -ItemType Directory -Force -Path $wvDir | Out-Null
        # 包结构随版本变（net45 / net462 / lib_manual），按名字找更稳
        $coreDll = Get-ChildItem $ex -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' |
                   Where-Object { $_.FullName -match '\\lib\\(net4|netstandard)' } | Select-Object -First 1
        $formDll = Get-ChildItem $ex -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' |
                   Where-Object { $_.FullName -match '\\lib\\(net4|netstandard)' } | Select-Object -First 1
        $loader = Get-ChildItem $ex -Recurse -Filter 'WebView2Loader.dll' |
                  Where-Object { $_.FullName -match 'win-x64|native\\x64' } | Select-Object -First 1
        if (-not $coreDll -or -not $formDll) { Die "NuGet 包里没找到 WebView2 托管 DLL（版本布局变了？）" }
        Copy-Item $coreDll.FullName $wvDir -Force
        Copy-Item $formDll.FullName $wvDir -Force
        if ($loader) { Copy-Item $loader.FullName $wvDir -Force } else { Warn "没找到 WebView2Loader.dll" }
        Remove-Item $nupkg, $ex -Recurse -Force -ErrorAction SilentlyContinue
    }
    Ok "已就位：chat-app\lib"
}

# ------------------------------------------------------------ 4. 编译外壳
Step 4 "编译对话程序"

$exe = Join-Path $Root 'chat-app\llama-chat.exe'
if ($SkipBuild -or $DryRun -or (Test-Path $exe)) {
    if (Test-Path $exe) { Ok "已存在：chat-app\llama-chat.exe" } else { Say "    （跳过编译）" }
} else {
    if (Get-Process llama-chat -ErrorAction SilentlyContinue) { Die "llama-chat.exe 正在运行，请先退出" }
    & (Join-Path $Root 'chat-app\build.ps1')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { Die "编译失败" }
    Ok "已编译：$exe"
}

# ------------------------------------------------------------ 5. 配置
Step 5 "生成配置文件"

$conf = Join-Path $Root 'scripts\llama.conf.ini'
$example = Join-Path $Root 'scripts\llama.conf.example.ini'
if (Test-Path $conf) {
    Ok "已存在，保留不动：scripts\llama.conf.ini"
} else {
    if (-not (Test-Path $example)) { Die "缺少 scripts\llama.conf.example.ini" }

    # 按显存给一组默认值
    if ($VramGb -le 6) { $ngl = 24; $ctx = 16384; $kv = 'q4_0' }
    elseif ($VramGb -le 8) { $ngl = 35; $ctx = 32768; $kv = 'q4_0' }
    elseif ($VramGb -le 12) { $ngl = 99; $ctx = 65536; $kv = 'q8_0' }
    else { $ngl = 999; $ctx = 131072; $kv = 'q8_0' }

    $modelRel = 'models\model-base.gguf'
    if ($Model) {
        if (-not (Test-Path $Model)) { Warn "模型文件不存在：$Model（先写进配置，稍后自己放）" }
        $modelRel = $Model
    }

    $ws = Join-Path $Root 'workspace'
    $lines = (Get-Content $example -Encoding UTF8)
    $section = ''
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]') { $section = $matches[1].ToLower() }
        $repl = switch -Regex ($line) {
            '^\s*model\s*='      { if ($section -eq 'model') { "model      = $modelRel" } else { $line } }
            '^\s*n_gpu_layers\s*=' { if ($section -eq 'gpu') { "n_gpu_layers = $ngl" } else { $line } }
            '^\s*ctx_size\s*='     { if ($section -eq 'gpu') { "ctx_size     = $ctx" } else { $line } }
            '^\s*cache_type_k\s*=' { if ($section -eq 'gpu') { "cache_type_k = $kv" } else { $line } }
            '^\s*cache_type_v\s*=' { if ($section -eq 'gpu') { "cache_type_v = $kv" } else { $line } }
            '^\s*workspace\s*='    { if ($section -eq 'tools') { "workspace  = $ws" } else { $line } }
            default                { $line }
        }
        $out.Add($repl)
    }
    $text = ($out -join "`r`n") + "`r`n"
    if ($DryRun) {
        Say ("    （dry-run：将写入 ngl={0}, ctx={1}, KV={2}, model={3}）" -f $ngl, $ctx, $kv, $modelRel)
    } else {
        [System.IO.File]::WriteAllText($conf, $text, (New-Object System.Text.UTF8Encoding($false)))
        New-Item -ItemType Directory -Force -Path $ws | Out-Null
        Ok "已生成 scripts\llama.conf.ini（ngl=$ngl, ctx=$ctx, KV=$kv）"
    }
}

# ------------------------------------------------------------ 6. 自检
Step 6 "自检"

$fail = 0
if (Test-Path $serverExe) {
    if (-not $DryRun) {
        # llama-server 把版本打到 stderr，走 cmd 避免 PowerShell 把它当错误
        $v = (cmd /c "`"$serverExe`" --version 2>&1" | Select-Object -First 1)
        Ok "llama-server：$v"
    } else { Ok "llama-server.exe 已就位" }
} else { Warn "缺 llama-server.exe"; $fail++ }

if (Test-Path $exe) { Ok "llama-chat.exe 就绪" } else { Warn "缺 llama-chat.exe"; $fail++ }
if (Test-Path $conf) { Ok "配置文件就绪" } else { Warn "缺配置文件"; $fail++ }

$gguf = Get-ChildItem (Join-Path $Root 'models') -Filter *.gguf -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gguf) { Ok ("模型：" + $gguf.Name + "（" + [math]::Round($gguf.Length/1GB,1) + " GB）") }
else { Warn "models\ 里还没有 .gguf，放一个进去再启动" }

Write-Host ""
if ($fail -eq 0) {
    Say "安装完成。" 'Green'
    Say ""
    Say "  启动服务：powershell -ExecutionPolicy Bypass -File scripts\start-llama.ps1"
    Say "  打开界面：.\chat-app\llama-chat.exe"
    Say "  后台保活：powershell -ExecutionPolicy Bypass -File scripts\register-keepalive.ps1"
} else {
    Say "还有 $fail 项没完成，按上面提示处理后重跑 setup.ps1。" 'Yellow'
}

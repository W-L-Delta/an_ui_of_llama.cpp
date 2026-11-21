#requires -version 5.1
<#
    start-llama.ps1 —— llama.cpp 服务启动 / 模型切换 / 保活
    ------------------------------------------------------------------
    唯一配置源: scripts\llama.conf.ini

    用法:
      start-llama.ps1                 重启为 [models] active 指定的模型
      start-llama.ps1 -Base           切到 base 槽位          (默认)
      start-llama.ps1 -Qwen36         切到 qwen36 槽位        (MoE)
      start-llama.ps1 -DeepSeek       切到 DeepSeek-R1-0528-8B (推理, 8B 稠密)
      start-llama.ps1 -Stop           停止服务
      start-llama.ps1 -Status         查看状态
      start-llama.ps1 -Foreground     前台运行(调试用, Ctrl+C 退出)
      start-llama.ps1 -EnsureRunning  保活: 只在没跑时拉起(计划任务 llama-keepalive 每 3 分钟调用)

    退出码: 0 成功 / 1 失败
#>
[CmdletBinding()]
param(
    [switch]$Base,
    [switch]$Qwen36,
    [switch]$DeepSeek,
    [switch]$Stop,
    [switch]$Status,
    [switch]$Foreground,
    [switch]$EnsureRunning
)

$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$ScriptDir    = $PSScriptRoot
$Root         = Split-Path -Parent $ScriptDir
$ConfPath     = Join-Path $ScriptDir 'llama.conf.ini'
$Logs         = Join-Path $Root 'logs'
$PidFile      = Join-Path $Logs 'llama-server.pid'
$Exe          = Join-Path $Root 'bin\cuda\llama-server.exe'
$OutLog       = Join-Path $Logs 'llama-server.log'
$ErrLog       = Join-Path $Logs 'llama-server.err.log'
$GuardLog     = Join-Path $Logs 'guard.log'
$LockFile     = Join-Path $Logs '.start.lock'
$ReadyTimeout = 240

# --------------------------------------------------------------------------
#  小工具
# --------------------------------------------------------------------------
function Say([string]$Message) {
    Write-Host $Message
}

function Write-Guard([string]$Message) {
    try {
        if (-not (Test-Path $Logs)) { New-Item -ItemType Directory -Force -Path $Logs | Out-Null }
        $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $GuardLog -Value $line -Encoding UTF8
    } catch { }
}

function Read-Ini([string]$Path) {
    $conf = @{}
    $section = 'global'
    $conf[$section] = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $text = $line.Trim()
        if (-not $text) { continue }
        if ($text[0] -eq '#' -or $text[0] -eq ';') { continue }
        if ($text -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim().ToLowerInvariant()
            if (-not $conf.ContainsKey($section)) { $conf[$section] = @{} }
            continue
        }
        $idx = $text.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $text.Substring(0, $idx).Trim().ToLowerInvariant()
        $value = $text.Substring($idx + 1)
        $hash = $value.IndexOf('#')
        if ($hash -ge 0) { $value = $value.Substring(0, $hash) }
        $semi = $value.IndexOf(';')
        if ($semi -ge 0) { $value = $value.Substring(0, $semi) }
        if (-not $conf.ContainsKey($section)) { $conf[$section] = @{} }
        $conf[$section][$key] = $value.Trim()
    }
    return $conf
}

function Get-Val($Ini, [string]$Section, [string]$Key, [string]$Default = '') {
    if ($Ini.ContainsKey($Section) -and $Ini[$Section].ContainsKey($Key)) {
        $v = $Ini[$Section][$Key]
        if ($v -ne '') { return $v }
    }
    return $Default
}

function To-Int([string]$Value, [int]$Default) {
    $parsed = 0
    if ([int]::TryParse($Value, [ref]$parsed)) { return $parsed }
    return $Default
}

function Resolve-Rel([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $Root $Path)
}

function Test-Health([int]$Port) {
    try {
        $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:$Port/health") -UseBasicParsing -TimeoutSec 2
        return ($resp.StatusCode -eq 200 -and $resp.Content -match '"status"\s*:\s*"ok"')
    } catch {
        return $false
    }
}

function Stop-Server {
    $stopped = 0
    if (Test-Path $PidFile) {
        $raw = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue)
        $raw = if ($raw) { $raw.Trim() } else { '' }
        if ($raw -match '^\d+$') {
            $proc = Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue
            if ($proc) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                $stopped++
            }
        }
    }
    # 兜底: 任何从本目录启动的 llama-server
    foreach ($proc in @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)) {
        try {
            if ($proc.Path -and $proc.Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                $stopped++
            }
        } catch { }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    if ($stopped -gt 0) { Say "已停止 llama-server (进程数: $stopped)" }
    return $stopped
}

function Set-ActiveModel([string]$Role) {
    $raw = [System.IO.File]::ReadAllText($ConfPath)
    $bom = $raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF
    if ($bom) { $raw = $raw.Substring(1) }
    $new = [regex]::new('(?m)^(\s*active\s*=\s*)\S+').Replace($raw, ('${1}' + $Role), 1)
    if ($new -ne $raw) {
        if ($bom) { $new = [char]0xFEFF + $new }
        [System.IO.File]::WriteAllText($ConfPath, $new, (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Quote-Arg([string]$Value) {
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Show-Tail([string]$Path, [int]$Lines = 12) {
    if (Test-Path $Path) {
        $tail = Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue
        if ($tail) { $tail | ForEach-Object { Say "  | $_" } }
    }
}

$ROLE_SWITCH = @{
    'base'   = '-Base'
    'qwen36' = '-Qwen36'
    'deepseek' = '-DeepSeek'
}
$ROLE_MODEL_KEY = @{
    'base'   = 'model'
    'qwen36' = 'qwen36'
    'deepseek' = 'deepseek'
}
$ROLE_ALIAS_KEY = @{
    'base'   = 'alias'
    'qwen36' = 'alias_qwen36'
    'deepseek' = 'alias_deepseek'
}

# --------------------------------------------------------------------------
#  主流程
# --------------------------------------------------------------------------
try {
    if (-not (Test-Path $Logs)) { New-Item -ItemType Directory -Force -Path $Logs | Out-Null }

    if (-not (Test-Path $ConfPath)) { throw "找不到配置文件: $ConfPath" }
    $conf = Read-Ini $ConfPath

    $host_      = Get-Val $conf 'server' 'host' '127.0.0.1'
    $port       = To-Int (Get-Val $conf 'server' 'port' '8080') 8080
    $threads    = To-Int (Get-Val $conf 'server' 'threads' '8') 8
    $parallel   = To-Int (Get-Val $conf 'server' 'parallel' '1') 1

    $active = (Get-Val $conf 'models' 'active' 'base').ToLowerInvariant()

    # ---- 停止 ----
    if ($Stop) {
        Stop-Server | Out-Null
        Write-Guard 'stop requested (-Stop)'
        exit 0
    }

    # ---- 状态 ----
    if ($Status) {
        $alive = Test-Health $port
        $pidText = ''
        if (Test-Path $PidFile) { $pidText = (Get-Content -LiteralPath $PidFile -Raw).Trim() }
        Say ("root      : " + $Root)
        Say ("config    : " + $ConfPath)
        Say ("active    : " + $active)
        Say ("health    : " + $(if ($alive) { 'ok' } else { 'down' }))
        Say ("endpoint  : " + "http://$host_`:$port")
        Say ("pid       : " + $(if ($pidText) { $pidText } else { '-' }))
        exit 0
    }

    # ---- 选模型 ----
    $role = $null
    if ($Base) { $role = 'base' }
    elseif ($Qwen36) { $role = 'qwen36' }
    elseif ($DeepSeek) { $role = 'deepseek' }

    $switchRole = $role
    if ($role) {
        Say ("切换模型: " + $role)
    } else {
        $role = $active
        if (-not $ROLE_MODEL_KEY.ContainsKey($role)) {
            $role = 'base'
            Say "配置里的 [models] active 无效, 回退到 base"
        }
    }

    # ---- 保活: 已在跑就直接返回 ----
    if ($EnsureRunning) {
        if (Test-Health $port) {
            Write-Guard ("ensure-running: healthy on port " + $port + ", skip")
            exit 0
        }
        Write-Guard ("ensure-running: down, starting role=" + $role)
    }

    # ---- 互斥: 面板/保活任务/手动切换不要同时启动 ----
    $mutex = New-Object System.Threading.Mutex($false, 'Local\llamaCppStart')
    $locked = $mutex.WaitOne(0)
    if (-not $locked) {
        if ($EnsureRunning) {
            Write-Guard 'ensure-running: another start in progress, skip'
            exit 0
        }
        $locked = $mutex.WaitOne(30000)
        if (-not $locked) { throw '另一个启动/停止操作正在进行中, 请稍后重试' }
    }

    $exePath = $Exe
    if (-not (Test-Path $exePath)) {
        throw "找不到 llama-server.exe: $exePath"
    }

    $section  = if ($role -eq 'base') { 'gpu' } else { $role }
    $modelRel = Get-Val $conf 'model' $ROLE_MODEL_KEY[$role] ''
    if (-not $modelRel) { throw ("配置缺少 [model] " + $ROLE_MODEL_KEY[$role]) }
    $modelPath = Resolve-Rel $modelRel

    $alias = Get-Val $conf 'server' $ROLE_ALIAS_KEY[$role] ''
    if (-not $alias) { $alias = 'llama' }

    $ngl     = To-Int (Get-Val $conf $section 'n_gpu_layers' (Get-Val $conf 'gpu' 'n_gpu_layers' '99')) 99
    $ctx     = To-Int (Get-Val $conf $section 'ctx_size' (Get-Val $conf 'gpu' 'ctx_size' '8192')) 8192
    $ctk     = (Get-Val $conf $section 'cache_type_k' (Get-Val $conf 'gpu' 'cache_type_k' 'q8_0')).ToLowerInvariant()
    $ctv     = (Get-Val $conf $section 'cache_type_v' (Get-Val $conf 'gpu' 'cache_type_v' 'q8_0')).ToLowerInvariant()
    $fa      = (Get-Val $conf 'gpu' 'flash_attn' 'on').ToLowerInvariant()
    $reason  = Get-Val $conf $section 'reasoning_format' ''
    $vision  = (Get-Val $conf 'vision' 'enabled' 'false').ToLowerInvariant() -eq 'true'
    $mmprojRel = Get-Val $conf $section 'mmproj' (Get-Val $conf 'model' 'mmproj' '')
    $mmproj  = Resolve-Rel $mmprojRel
    $router  = (Get-Val $conf 'router' 'enabled' 'false').ToLowerInvariant() -eq 'true'
    $preset  = Resolve-Rel (Get-Val $conf 'router' 'preset' 'scripts\models.ini')
    $modelsMax = To-Int (Get-Val $conf 'router' 'models_max' '1') 1
    $extra   = Get-Val $conf 'extra' 'args' ''
    $extraRole = Get-Val $conf $section 'extra_args' ''

    if (-not (Test-Path $modelPath)) {
        throw ("模型文件不存在: $modelPath" + [Environment]::NewLine + "请先把 gguf 放进 models\ 目录。")
    }

    # 只在模型文件确实存在时才改写 [models] active：否则一次失败的切换
    # 会把配置指向不存在的模型，保活随后也跟着起不来。
    if ($switchRole) {
        Set-ActiveModel $role
        Write-Guard ("switch to " + $role)
    }

    # KV cache 量化必须配合 flash-attn
    if ($fa -eq 'off' -and ($ctk -ne 'f16' -or $ctv -ne 'f16')) {
        Say ("提示: KV cache 为 $ctk/$ctv, 必须开启 flash-attn, 已自动改为 on")
        $fa = 'on'
    }

    $isQwen = ($modelRel -match 'qwen') -and ($modelRel -notmatch 'deepseek')
    if ($vision -and $isQwen -and (Test-Path $mmproj)) {
        $vision = $true
    } else {
        $vision = $false
    }

    $argList = New-Object 'System.Collections.Generic.List[string]'
    if ($router) {
        $argList.Add('--models-preset'); $argList.Add($preset)
        $argList.Add('--models-max');    $argList.Add("$modelsMax")
        $argList.Add('--host');          $argList.Add($host_)
        $argList.Add('--port');          $argList.Add("$port")
        $argList.Add('--ctx-size');      $argList.Add("$ctx")
        $argList.Add('--n-gpu-layers');  $argList.Add("$ngl")
        $argList.Add('--threads');       $argList.Add("$threads")
    } else {
        $argList.Add('--model');         $argList.Add($modelPath)
        $argList.Add('--alias');         $argList.Add($alias)
        $argList.Add('--host');          $argList.Add($host_)
        $argList.Add('--port');          $argList.Add("$port")
        $argList.Add('--ctx-size');      $argList.Add("$ctx")
        $argList.Add('--n-gpu-layers');  $argList.Add("$ngl")
        $argList.Add('--threads');       $argList.Add("$threads")
        $argList.Add('--parallel');      $argList.Add("$parallel")
        if ($fa -in @('on', 'off', 'auto')) { $argList.Add('-fa'); $argList.Add($fa) }
        $argList.Add('--cache-type-k');  $argList.Add($ctk)
        $argList.Add('--cache-type-v');  $argList.Add($ctv)
        if ($reason) { $argList.Add('--reasoning-format'); $argList.Add($reason) }
        if ($vision) { $argList.Add('--mmproj'); $argList.Add($mmproj) }
    }
    # ---- 采样参数：[sampling] 段，值为空则跳过（保持 llama.cpp 默认）----
    $samplingFlags = @(
        @{ key = 'temp';              flag = '--temp' },
        @{ key = 'top_p';             flag = '--top-p' },
        @{ key = 'top_k';             flag = '--top-k' },
        @{ key = 'min_p';             flag = '--min-p' },
        @{ key = 'presence_penalty';  flag = '--presence-penalty' },
        @{ key = 'frequency_penalty'; flag = '--frequency-penalty' },
        @{ key = 'repeat_penalty';    flag = '--repeat-penalty' },
        @{ key = 'repeat_last_n';     flag = '--repeat-last-n' },
        @{ key = 'dry_multiplier';    flag = '--dry-multiplier' }
    )
    foreach ($sf in $samplingFlags) {
        # 先看当前模型自己的段，没有再用全局 [sampling] 兜底
        $val = Get-Val $conf $section $sf.key (Get-Val $conf 'sampling' $sf.key '')
        if ($val -ne '') {
            $argList.Add($sf.flag)
            $argList.Add($val)
        }
    }

    foreach ($blob in @($extra, $extraRole)) {
        if (-not $blob) { continue }
        foreach ($token in ($blob -split '\s+')) {
            if ($token) { $argList.Add($token) }
        }
    }

    # ---- 停旧的 ----
    Stop-Server | Out-Null
    $waitUntil = (Get-Date).AddSeconds(15)
    while ((Test-Health $port) -and (Get-Date) -lt $waitUntil) { Start-Sleep -Milliseconds 300 }

    Say ("启动 llama-server  role=" + $role + "  model=" + (Split-Path -Leaf $modelPath))
    Say ("  ctx=" + $ctx + " ngl=" + $ngl + " kv=" + $ctk + "/" + $ctv + " fa=" + $fa + " threads=" + $threads + " parallel=" + $parallel)
    Write-Guard ("start role=" + $role + " ctx=" + $ctx + " ngl=" + $ngl + " kv=" + $ctk + "/" + $ctv)

    if ($Foreground) {
        Set-Content -LiteralPath $PidFile -Value $PID -Encoding ASCII
        try {
            & $exePath @($argList.ToArray())
            $code = $LASTEXITCODE
        } finally {
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        }
        exit $code
    }

    $argString = (($argList | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $proc = Start-Process -FilePath $exePath -ArgumentList $argString `
        -WorkingDirectory $Root -PassThru -NoNewWindow `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog

    Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ASCII
    Say ("  pid=" + $proc.Id + "  等待就绪(最多 " + $ReadyTimeout + "s)…")

    $started = Get-Date
    $deadline = $started.AddSeconds($ReadyTimeout)
    $nextTick = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1000
        if (Test-Health $port) {
            $secs = [int]((Get-Date) - $started).TotalSeconds
            Say ("就绪: model=" + $alias + "  (" + $secs + "s, pid " + $proc.Id + ")")
            Write-Guard ("ready in " + $secs + "s pid=" + $proc.Id)
            Write-Host ''
            $code = 0
            break
        }
        if ($proc.HasExited) {
            Say ("启动失败: llama-server 退出, code=" + $proc.ExitCode)
            Say '--- llama-server.err.log 末尾 ---'
            Show-Tail $ErrLog 15
            Write-Guard ("failed: exit " + $proc.ExitCode)
            exit 1
        }
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        if ($elapsed -ge $nextTick) {
            Say ("  等待中… " + $elapsed + "s")
            $nextTick = $elapsed + 15
        }
    }

    if ($null -eq $code) {
        Say ("超时: " + $ReadyTimeout + "s 内没有就绪")
        Show-Tail $ErrLog 15
        Write-Guard 'failed: timeout'
        exit 1
    }
    exit $code
} catch {
    Say ("错误: " + $_.Exception.Message)
    Write-Guard ("error: " + $_.Exception.Message)
    exit 1
}

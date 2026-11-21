# register-keepalive.ps1 —— 注册 / 更新 / 删除保活任务 llama-keepalive
#
# 任务动作必须是 bin\windowless-runner.exe（GUI 子系统），不能直接写
# powershell.exe 或 .cmd：任务计划会给控制台子系统程序先建一个控制台窗口，
# -WindowStyle Hidden / start /min 都只是事后隐藏，每 3 分钟闪一次黑框。
#
# 用法:
#   .\register-keepalive.ps1              # 注册（幂等，已存在则覆盖）
#   .\register-keepalive.ps1 -Interval 1  # 改检查间隔（分钟）
#   .\register-keepalive.ps1 -Remove      # 删除任务

[CmdletBinding()]
param(
    [switch]$Remove,
    [int]$Interval = 3
)

$ErrorActionPreference = 'Stop'

$TaskName = 'llama-keepalive'
$Root     = Split-Path -Parent $PSScriptRoot
$Runner   = Join-Path $Root 'bin\windowless-runner.exe'
$Script   = Join-Path $Root 'scripts\start-llama.ps1'

if ($Remove) {
    schtasks.exe /Delete /TN $TaskName /F | Out-Null
    Write-Host "已删除任务 $TaskName"
    exit 0
}

if (-not (Test-Path $Runner)) { throw "缺少 $Runner，先按 README 编译 windowless-runner.cs" }
if (-not (Test-Path $Script)) { throw "缺少 $Script" }

# 路径没有空格，不必给 schtasks 的 /TR 再加内层引号
$action = "$Runner powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $Script -EnsureRunning"

schtasks.exe /Create /TN $TaskName /F /SC MINUTE /MO $Interval /RL LIMITED /TR $action | Out-Null
if ($LASTEXITCODE -ne 0) { throw "schtasks /Create 失败，退出码 $LASTEXITCODE" }

# 电池策略保持 Windows 默认：DisallowStartIfOnBatteries = True、
# StopIfGoingOnBatteries = True。这是机主明确要求的行为（不插电就不保活），
# 不要"顺手优化"成 False。

$info = Get-ScheduledTask -TaskName $TaskName
$act = (Get-ScheduledTask -TaskName $TaskName).Actions[0]
Write-Host "任务   : $TaskName"
Write-Host "状态   : $($info.State)"
Write-Host "间隔   : 每 $Interval 分钟"
Write-Host "动作   : $($act.Execute)"
Write-Host "参数   : $($act.Arguments)"
Write-Host "电池   : DisallowStart=$($info.Settings.DisallowStartIfOnBatteries) StopOnBattery=$($info.Settings.StopIfGoingOnBatteries)"

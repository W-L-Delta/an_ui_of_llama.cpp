# 编译对话程序外壳（llama-chat.exe）
#
# 用系统自带的 .NET Framework 编译器，不需要安装 .NET SDK。
# 前置：把 WebView2 的托管 DLL 放到 chat-app\lib\（见 lib\README.md）

$ErrorActionPreference = "Stop"

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "找不到 csc.exe，需要 .NET Framework 4.x（Windows 自带）" }

$lib    = Join-Path $PSScriptRoot "lib"
$coreDll = Join-Path $lib "Microsoft.Web.WebView2.Core.dll"
$formDll = Join-Path $lib "Microsoft.Web.WebView2.WinForms.dll"
foreach ($d in @($coreDll, $formDll)) {
    if (-not (Test-Path $d)) { throw ("缺少依赖: {0}`n请看 chat-app\lib\README.md" -f $d) }
}

$exe  = Join-Path $PSScriptRoot "llama-chat.exe"
$ico  = Join-Path $PSScriptRoot "assets\app.ico"
$man  = Join-Path $PSScriptRoot "app.manifest"
$src  = Join-Path $PSScriptRoot "src\Program.cs"

if (Get-Process llama-chat -ErrorAction SilentlyContinue) {
    throw "llama-chat.exe 正在运行，请先退出再编译"
}

$cscArgs = @(
    "/nologo"
    "/target:winexe"
    "/platform:x64"
    "/optimize+"
    "/out:$exe"
    "/win32icon:$ico"
    "/win32manifest:$man"
    "/r:System.Windows.Forms.dll"
    "/r:System.Drawing.dll"
    "/r:$coreDll"
    "/r:$formDll"
    $src
)

Write-Host "编译中..." -ForegroundColor Cyan
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "编译失败（exit $LASTEXITCODE）" }

# WebView2 的 DLL 必须和 exe 放在一起
Copy-Item (Join-Path $lib "*.dll") $PSScriptRoot -Force
Write-Host "完成：$exe" -ForegroundColor Green

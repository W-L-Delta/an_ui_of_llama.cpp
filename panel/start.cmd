@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem 面板自己判断: 已在运行就只开浏览器, 没运行就拉起服务再开。
rem pythonw 无控制台, 失败时 app.py 会弹窗并写 panel.log。

where pythonw >nul 2>nul
if not errorlevel 1 (
  start "" pythonw "%~dp0app.py" --open --port 8090
  exit /b 0
)

where python >nul 2>nul
if errorlevel 1 (
  echo [错误] 未找到 python，请先安装 Python 3.10+ 并加入 PATH。
  pause
  exit /b 1
)

start "" python "%~dp0app.py" --open --port 8090
exit /b 0

@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
where py >nul 2>&1
if %errorlevel%==0 (
  py -3 -u "%SCRIPT_DIR%pingglass_native_host.py" %*
  exit /b %errorlevel%
)
python -u "%SCRIPT_DIR%pingglass_native_host.py" %*

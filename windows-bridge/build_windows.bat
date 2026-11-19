@echo off
setlocal
cd /d "%~dp0"
REM Build this EXE on Windows 10/11. Python 3.11+ is required only on the build PC.
py -m pip install --upgrade pyinstaller
if errorlevel 1 exit /b 1
py -m PyInstaller --clean --onefile --name TonyTranBridge bridge.py
if errorlevel 1 exit /b 1
copy /Y start_bridge.bat dist\start_bridge.bat >nul
(
  echo TONY TRAN EA CONTROL - WINDOWS BRIDGE
  echo Run start_bridge.bat from this folder. Keep the access token private.
  echo Use LAN/Tailscale only. Never configure public router port forwarding.
) > dist\README_BRIDGE.txt
echo Build complete: %CD%\dist\TonyTranBridge.exe
echo Run dist\start_bridge.bat to start the Bridge.
pause

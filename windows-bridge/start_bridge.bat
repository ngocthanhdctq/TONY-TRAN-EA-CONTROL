@echo off
setlocal
set /p TOKEN=Enter private access token (minimum 32 random characters):
if "%TOKEN:~31,1%"=="" echo Token too short. & pause & exit /b 1
TonyTranBridge.exe --host 0.0.0.0 --port 8765 --token "%TOKEN%"

@echo off
REM Open the ypt-desktop runtime log in Notepad.
REM
REM Release Flutter apps have no console, so AppLog writes to a file.
REM Run this after using ypt-desktop.exe to see what the tray did.

set LOGDIR=%LOCALAPPDATA%\ypt_client
set LOGFILE=%LOGDIR%\ypt.log

if not exist "%LOGFILE%" (
    echo No log yet: %LOGFILE%
    echo.
    echo The app creates it on first run. Start ypt-desktop.exe, then
    echo come back.
    echo.
    pause
    exit /b 1
)

echo Opening %LOGFILE%
start "" notepad "%LOGFILE%"

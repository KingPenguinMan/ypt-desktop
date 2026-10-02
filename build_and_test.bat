@echo off
REM ============================================================
REM  ypt_client - build and test script
REM
REM  Usage:
REM    1) Run build_and_test.bat  (double-click works)
REM    2) Close any running ypt_client.exe first
REM
REM  Requires Flutter 3.47+ (expected at D:\flutter)
REM
REM  NOTE: messages are kept ASCII-only on purpose. Batch files
REM        are read as GBK/CP936 on Chinese Windows; non-ASCII
REM        text in labels garbles and can break parsing.
REM ============================================================

setlocal enabledelayedexpansion
cd /d "%~dp0"

set FLUTTER=D:\flutter\bin\flutter.bat
set DARTEXE=D:\flutter\bin\cache\dart-sdk\bin\dart.exe

echo.
echo ============================================================
echo   ypt_client  build and test
echo ============================================================
echo.

REM ---------- 0. environment ----------
echo [0/7] Checking Flutter SDK...
if not exist "%FLUTTER%" (
    echo   [ERROR] %FLUTTER% not found.
    echo   Install Flutter 3.47+ and edit FLUTTER in this script.
    pause
    exit /b 1
)
REM NOTE: every invocation of flutter.bat must be prefixed with `call`.
REM flutter.bat is itself a batch file; without `call` the control flow
REM does NOT return here — the outer script silently stops after step 0.
call "%FLUTTER%" --version
echo.

REM ---------- 1. deps ----------
echo [1/7] Fetching dependencies...
call "%FLUTTER%" pub get
if errorlevel 1 (
    echo   [ERROR] pub get failed.
    pause
    exit /b 1
)
echo.

REM ---------- 1b. native toolchain check ----------
echo [1b/7] Checking native toolchain for cnativeapi...
call "%FLUTTER%" doctor -v 2>&1 | findstr /i "Visual Studio" > "%TEMP%\ypt_vs.txt"
type "%TEMP%\ypt_vs.txt"
findstr /i "Visual Studio" "%TEMP%\ypt_vs.txt" >nul
if errorlevel 1 (
    echo   [WARN] Visual Studio not detected by flutter doctor.
    echo   tray_manager pulls in nativeapi -^> cnativeapi, which ships C++
    echo   sources and may compile them at build time. Without the C++
    echo   toolchain the build is likely to fail.
    echo   Do NOT install anything yet. Continue and see whether
    echo   step 4 actually fails, then install if needed.
    echo.
)
echo.

REM ---------- 2. analyze ----------
echo [2/7] Static analysis (flutter analyze)...
call "%FLUTTER%" analyze
if errorlevel 1 (
    echo.
    echo   [WARN] analyze reported problems. Save the output above.
    echo   Most likely cause: tray_manager / window_manager API mismatch.
    echo.
    pause
    exit /b 1
)
echo   analyze passed.
echo.

REM ---------- 3. logic tests ----------
echo [3/7] Logic self-tests (76 assertions)...
copy /y tool\selftest.dart "%TEMP%\ypt_st.dart" >nul
copy /y tool\calendartest.dart "%TEMP%\ypt_ct.dart" >nul
"%DARTEXE%" run "%TEMP%\ypt_st.dart"
if errorlevel 1 (
    echo   [ERROR] selftest failed.
    pause
    exit /b 1
)
"%DARTEXE%" run "%TEMP%\ypt_ct.dart"
if errorlevel 1 (
    echo   [ERROR] calendartest failed.
    pause
    exit /b 1
)
echo.

REM ---------- 4. build ----------
echo [4/7] Building Windows release...
echo   (first build may take several minutes: cnativeapi compiles C++)
call "%FLUTTER%" build windows --release
if errorlevel 1 (
    echo.
    echo   [ERROR] build failed.
    echo   If the error mentions cnativeapi / C++ / cl.exe / CMake,
    echo   then the Visual Studio C++ toolchain is required:
    echo     Visual Studio Installer -^> Modify -^> "Desktop development
    echo     with C++" workload.
    echo   Otherwise save the full output above.
    echo.
    pause
    exit /b 1
)
echo.

REM ---------- 5. artifact ----------
echo [5/7] Artifact:
if exist "build\windows\x64\runner\Release\ypt_client.exe" (
    for %%F in ("build\windows\x64\runner\Release\*") do @echo     %%~nxF
) else (
    echo   [WARN] expected exe not found, check the build folder.
)
echo.

REM ---------- 6. package ----------
echo [6/7] Packaging zip...
if exist "..\ypt_client-windows-x64.zip" del "..\ypt_client-windows-x64.zip"
powershell -NoProfile -Command ^
  "Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath '..\ypt_client-windows-x64.zip' -Force"
if exist "..\ypt_client-windows-x64.zip" (
    for %%F in ("..\ypt_client-windows-x64.zip") do @echo     %%~zF bytes  %%~nF
) else (
    echo   [WARN] packaging failed.
)
echo.

echo ============================================================
echo   DONE
echo ============================================================
echo.
echo Acceptance checklist:
echo   1) run ypt_client.exe, sign in with email
echo   2) start a timer, note the time, then END THE PROCESS
echo      from Task Manager (do not close the window)
echo   3) reopen: it must restore "currently studying" and allow stop
echo   4) click window close button: must hide to tray, not exit
echo   5) stop a timer, wait over 1 min, start again:
echo      the "what were you doing" dialog should appear
echo   6) open the History tab: calendar heatmap + pie chart
echo.
echo Linux/macOS notes:
echo   Linux needs: sudo apt-get install libgtk-3-dev libx11-dev libxi-dev
echo   macOS  needs 10.15+; social login is still unavailable there.
echo   On Linux the tray icon click is not reported by the OS -
echo   use the "Show window" menu item instead.
echo.
pause

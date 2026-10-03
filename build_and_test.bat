@echo off
REM ------------------------------------------------------------
REM  THIS FILE MUST USE CRLF LINE ENDINGS.
REM  With LF, cmd.exe mis-parses every line and eats the first few
REM  characters, producing errors like:
REM      'M' is not recognized      (should be REM)
REM      'etlocal' is not recognized (should be setlocal)
REM  .gitattributes enforces this; keep the file checked out as-is.
REM  Keep this file pure ASCII too: the console may be GBK (CP936).
REM ------------------------------------------------------------

REM ============================================================
REM  ypt-desktop - build and test script
REM
REM  Usage:
REM    1) Run build_and_test.bat  (double-click works)
REM    2) Close any running ypt-desktop.exe first
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
echo   ypt-desktop  build and test
echo ============================================================
echo.

REM ---------- 0. environment ----------
echo [0/8] Checking Flutter SDK...
if not exist "%FLUTTER%" (
    echo   [ERROR] %FLUTTER% not found.
    echo   Install Flutter 3.47+ and edit FLUTTER in this script.
    pause
    exit /b 1
)
REM NOTE: every invocation of flutter.bat must be prefixed with `call`.
REM flutter.bat is itself a batch file; without `call` the control flow
REM does NOT return here -- the outer script silently stops after step 0.
call "%FLUTTER%" --version
echo.

REM ---------- 0b. running instance ----------
REM A running ypt-desktop.exe keeps files in the build output folder
REM open. The zip step then fails with a sharing violation, which
REM surfaces as a confusing PowerShell error instead of the real
REM cause. Catch it here.
echo [0b/8] Checking for a running instance...
tasklist /FI "IMAGENAME eq ypt-desktop.exe" /NH > "%TEMP%\ypt_ps.txt" 2>nul
findstr /I "ypt-desktop.exe" "%TEMP%\ypt_ps.txt" >nul
if not errorlevel 1 (
    echo   [ERROR] ypt-desktop.exe is still running.
    echo   Close it first: Quit from the tray menu, or Task Manager.
    echo   Why: the running app holds files in the build output folder
    echo   open, so packaging would fail with a sharing violation.
    echo.
    del "%TEMP%\ypt_ps.txt" 2>nul
    pause
    exit /b 1
)
del "%TEMP%\ypt_ps.txt" 2>nul
echo   No running instance.
echo.

REM ---------- 1. deps ----------
echo [1/8] Fetching dependencies...
call "%FLUTTER%" pub get
if errorlevel 1 (
    echo   [ERROR] pub get failed.
    pause
    exit /b 1
)
echo.

REM ---------- 1b. native toolchain check ----------
echo [1b/8] Checking native toolchain for cnativeapi...
call "%FLUTTER%" doctor -v 2>&1 | findstr /i "Visual Studio" > "%TEMP%\ypt_vs.txt"
type "%TEMP%\ypt_vs.txt"
findstr /i "Visual Studio" "%TEMP%\ypt_vs.txt" >nul
if errorlevel 1 (
    echo   [WARN] Visual Studio not detected by flutter doctor.
    echo   nativeapi depends on cnativeapi, which ships C++ sources and
    echo   compiles them at build time. Without the C++ toolchain the
    echo   build is likely to fail.
    echo   Do NOT install anything yet: continue, and only install the
    echo   workload if step 4 actually fails.
    echo.
)
echo.

REM ---------- 2. analyze ----------
REM --no-fatal-infos / --no-fatal-warnings: only errors should stop the
REM build. Without them `flutter analyze` exits non-zero for any lint
REM (including info-level style suggestions), which is noise.
echo [2/8] Static analysis (flutter analyze, errors only)...
call "%FLUTTER%" analyze --no-fatal-infos --no-fatal-warnings
if errorlevel 1 (
    echo.
    echo   [ERROR] analyze found compile errors. Fix the output above.
    echo   See docs\DEPENDENCY_API_NOTES.md for the tray_manager and
    echo   window_manager API reference if the error is in those files.
    echo.
    pause
    exit /b 1
)
echo   analyze passed, no errors.
echo.

REM ---------- 3. static check + logic tests ----------
REM All three run in place from the project root.
REM staticcheck MUST run here: it reads lib/ relatively, so copying it to
REM %TEMP% would break it.
echo [3/8] Static check + logic self-tests...

echo   [3a] static check: duplicate members, unused imports
"%DARTEXE%" run tool\staticcheck.dart
if errorlevel 1 (
    echo   [ERROR] static check failed. See the report above.
    pause
    exit /b 1
)

REM Do not hardcode the assertion count: it goes stale as cases are
REM added (it was 76, now 82).
echo   [3b] logic self-tests
"%DARTEXE%" run tool\selftest.dart
if errorlevel 1 (
    echo   [ERROR] selftest failed.
    pause
    exit /b 1
)
"%DARTEXE%" run tool\calendartest.dart
if errorlevel 1 (
    echo   [ERROR] calendartest failed.
    pause
    exit /b 1
)
echo.

REM ---------- 3c. local credentials ----------
REM OAuth credentials are injected at build time and never stored in this
REM repository (see lib/social_credentials.dart). Fill them in
REM social_credentials.local.bat -- which is gitignored -- to enable
REM social login. The build works without it; social login simply
REM reports that it is not configured.
echo [3c/8] Local credentials...
set "KAKAO_CLIENT_ID="
set "NAVER_CLIENT_ID="
set "NAVER_CLIENT_SECRET="
set "CRED_DEFINES="
if exist "social_credentials.local.bat" call "social_credentials.local.bat"
if not "%KAKAO_CLIENT_ID%"=="" set "CRED_DEFINES=%CRED_DEFINES% --dart-define=KAKAO_CLIENT_ID=%KAKAO_CLIENT_ID%"
if not "%NAVER_CLIENT_ID%"=="" set "CRED_DEFINES=%CRED_DEFINES% --dart-define=NAVER_CLIENT_ID=%NAVER_CLIENT_ID%"
if not "%NAVER_CLIENT_SECRET%"=="" set "CRED_DEFINES=%CRED_DEFINES% --dart-define=NAVER_CLIENT_SECRET=%NAVER_CLIENT_SECRET%"
if "%CRED_DEFINES%"=="" (
    echo   No local credentials. Social login will report unconfigured.
    echo   To enable it: copy social_credentials.local.bat.example and fill it in.
) else (
    echo   Credentials loaded; passing them as --dart-define.
)
echo.

REM ---------- 4. build ----------
echo [4/8] Building Windows release...
echo   (first build may take several minutes: cnativeapi compiles C++)
call "%FLUTTER%" build windows --release%CRED_DEFINES%
if errorlevel 1 (
    echo.
    echo   [ERROR] build failed. Match the message against this list:
    echo.
    echo   * error C2220 / warning C4819 : SOURCE ENCODING, not a missing
    echo     toolchain. The runner sources are UTF-8 with non-ASCII comments;
    echo     MSVC reads them as the system code page 936/GBK on Chinese
    echo     Windows, and /WX turns the warning into an error.
    echo     Already fixed in windows/runner/CMakeLists.txt via /utf-8.
    echo     If it reappears, a newly added source file has non-ASCII bytes.
    echo.
    echo   * cnativeapi / cl.exe / CMake not found : the C++ toolchain.
    echo     Open Visual Studio Installer, Modify, enable the workload
    echo     "Desktop development with C++".
    echo.
    echo   * anything else : save the full output above.
    echo.
    pause
    exit /b 1
)
echo.

REM ---------- 5. artifact ----------
echo [5/8] Artifact:
if exist "build\windows\x64\runner\Release\ypt-desktop.exe" (
    for %%F in ("build\windows\x64\runner\Release\*") do @echo     %%~nxF
) else (
    echo   [WARN] expected exe not found, check the build folder.
)
echo.

REM ---------- 6. package ----------
echo [6/8] Packaging zip...
if exist "..\ypt-desktop-windows-x64.zip" del "..\ypt-desktop-windows-x64.zip"
powershell -NoProfile -Command ^
  "Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath '..\ypt-desktop-windows-x64.zip' -Force"
if exist "..\ypt-desktop-windows-x64.zip" (
    for %%F in ("..\ypt-desktop-windows-x64.zip") do @echo     %%~zF bytes  %%~nF
) else (
    echo   [WARN] packaging failed.
)
echo.

REM ---------- 7. prepare runtime log ----------
REM Release Flutter apps have no console, so the app writes its own log.
REM Create the folder now and clear any stale file, so that after the first
REM run the log contains only that run.
echo [7/8] Preparing runtime log location...
set LOGDIR=%LOCALAPPDATA%\ypt_client
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
if exist "%LOGDIR%\ypt.log" del "%LOGDIR%\ypt.log"
if exist "%LOGDIR%\ypt.log" (
    echo   [WARN] could not clear the old log.
) else (
    echo   Old log cleared.
)
echo   Log file: %LOGDIR%\ypt.log
echo.

echo ============================================================
echo   DONE
echo ============================================================
echo.
echo Acceptance checklist:
echo   1) run ypt-desktop.exe, sign in with email
echo   2) start a timer, note the time, then END THE PROCESS
echo      from Task Manager (do not close the window)
echo   3) reopen: it must restore "currently studying" and allow stop
echo   4) click window close button: must hide to tray, not exit
echo   5) stop a timer, wait over 1 min, start again:
echo      the "what were you doing" dialog should appear
echo   6) open the History tab: calendar heatmap + pie chart
echo.
echo Runtime log (release builds have no console output):
echo   %%LOCALAPPDATA%%\ypt_client\ypt.log
echo   The tray logs every init step and the result of setVisible.
echo   If the tray icon does not appear, this file says why.
echo.
echo Linux/macOS notes:
echo   Linux needs: sudo apt-get install libgtk-3-dev libx11-dev libxi-dev
echo   macOS  needs 10.15+; social login is still unavailable there.
echo   On Linux the tray icon click is not reported by the OS -
echo   use the "Show window" menu item instead.
echo.
pause

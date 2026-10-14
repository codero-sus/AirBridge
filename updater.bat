@echo off
setlocal EnableExtensions
title AirBridge updater and Windows builds

set "BRANCH=arena/028ea2fd-airbridge"
for %%I in ("%~dp0.") do set "REPO_ROOT=%%~fI"
set "APP_DIR=%REPO_ROOT%\airbridge_mobile"
set "APK_FAILED=0"
set "WINDOWS_FAILED=0"

echo.
echo === AirBridge updater ===
echo Repository: %REPO_ROOT%
echo Branch:     %BRANCH%
echo.

if not exist "%APP_DIR%\pubspec.yaml" goto :not_project
where git >nul 2>&1
if errorlevel 1 goto :git_missing
git -C "%REPO_ROOT%" rev-parse --show-toplevel >nul 2>&1
if errorlevel 1 goto :not_git_clone
where flutter >nul 2>&1
if errorlevel 1 goto :flutter_missing

echo [1/6] Fetching latest branch...
git -C "%REPO_ROOT%" fetch origin "%BRANCH%"
if errorlevel 1 goto :update_failed

git -C "%REPO_ROOT%" show-ref --verify --quiet "refs/heads/%BRANCH%"
if errorlevel 1 (
    echo Creating local tracking branch...
    git -C "%REPO_ROOT%" switch --track --create "%BRANCH%" "origin/%BRANCH%"
) else (
    echo Switching to %BRANCH%...
    git -C "%REPO_ROOT%" switch "%BRANCH%"
)
if errorlevel 1 goto :update_failed

git -C "%REPO_ROOT%" pull --ff-only origin "%BRANCH%"
if errorlevel 1 goto :update_failed

echo [2/6] Checking Android SDK configuration...
rem Prefer the existing environment; then try the SDK path reported by the user and Android Studio's default.
if not defined ANDROID_HOME if exist "P:\Programs\Android\Sdk\platform-tools\adb.exe" set "ANDROID_HOME=P:\Programs\Android\Sdk"
if not defined ANDROID_HOME if exist "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"

if not defined ANDROID_HOME goto :android_sdk_missing
if not exist "%ANDROID_HOME%\platform-tools\adb.exe" goto :android_sdk_incomplete
call flutter config --android-sdk "%ANDROID_HOME%"
if errorlevel 1 goto :android_sdk_setup_failed

echo [3/6] Generating any missing native platform projects and applying Airbridge settings...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APP_DIR%\tool\bootstrap_platforms.ps1"
if errorlevel 1 goto :bootstrap_failed

cd /d "%APP_DIR%"
if errorlevel 1 goto :not_project

echo [4/6] Cleaning Flutter build outputs...
call flutter clean
if errorlevel 1 goto :clean_failed
call flutter pub get
if errorlevel 1 goto :pub_get_failed

echo [5/6] Accepting/checking Android SDK licenses...
call flutter doctor --android-licenses
if errorlevel 1 (
    echo Android APK build will be skipped because SDK licenses or Command-line Tools need attention.
    set "APK_FAILED=1"
    goto :build_windows
)

echo Building Android release APK...
call flutter build apk --release
if errorlevel 1 set "APK_FAILED=1"
if "%APK_FAILED%"=="0" echo APK: %APP_DIR%\build\app\outputs\flutter-apk\app-release.apk

echo.
:build_windows
echo [6/6] Building Windows release desktop bundle...
call flutter build windows --release
if errorlevel 1 set "WINDOWS_FAILED=1"
if "%WINDOWS_FAILED%"=="0" echo Windows bundle: %APP_DIR%\build\windows\x64\runner\Release\

echo.
if "%APK_FAILED%"=="1" echo Android APK was not built. Install/configure the Android SDK and accept its licenses, then run updater.bat again.
if "%WINDOWS_FAILED%"=="1" echo Windows build failed. Install Visual Studio 2022 with the Desktop development with C++ workload, then run updater.bat again.
if "%APK_FAILED%"=="1" goto :build_failed
if "%WINDOWS_FAILED%"=="1" goto :build_failed

echo Both Windows-host packages were built successfully.
echo Linux builds require Linux; macOS and iOS builds require macOS with Xcode.
pause
exit /b 0

:not_project
echo ERROR: airbridge_mobile\pubspec.yaml was not found beside updater.bat.
goto :failed

:git_missing
echo ERROR: Git is not installed or is not on PATH.
goto :failed

:not_git_clone
echo ERROR: This folder is not a Git clone. The updater needs Git metadata to fetch the branch.
echo From the parent folder, run:
echo   git clone --branch %BRANCH% https://github.com/codero-sus/AirBridge.git AirBridge
echo Then run updater.bat from the cloned repository root.
goto :failed

:flutter_missing
echo ERROR: Flutter is not installed or is not on PATH.
goto :failed

:update_failed
echo ERROR: Could not switch to or fast-forward from origin/%BRANCH%.
echo Check your network connection and resolve/stash local Git changes; this script never force-resets your files.
goto :failed

:android_sdk_missing
echo WARNING: ANDROID_HOME is not set and no SDK was found at the common Windows locations.
echo Android APK build will be skipped. Windows desktop build will still be attempted.
echo Install Android SDK Command-line Tools, Platform-Tools, Build-Tools, and an SDK Platform in Android Studio.
set "APK_FAILED=1"
goto :continue_without_android

:android_sdk_incomplete
echo WARNING: ANDROID_HOME points to "%ANDROID_HOME%", but platform-tools\adb.exe is missing.
echo Install Android SDK Platform-Tools in Android Studio. Android APK build will be skipped.
set "APK_FAILED=1"
goto :continue_without_android

:android_sdk_setup_failed
echo WARNING: Flutter could not configure the Android SDK at "%ANDROID_HOME%". Android APK build will be skipped.
set "APK_FAILED=1"
goto :continue_without_android

:continue_without_android
echo [3/6] Generating any missing native platform projects and applying Airbridge settings...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APP_DIR%\tool\bootstrap_platforms.ps1"
if errorlevel 1 goto :bootstrap_failed
cd /d "%APP_DIR%"
if errorlevel 1 goto :not_project
echo [4/6] Cleaning Flutter build outputs...
call flutter clean
if errorlevel 1 goto :clean_failed
call flutter pub get
if errorlevel 1 goto :pub_get_failed
goto :build_windows

:bootstrap_failed
echo ERROR: Platform bootstrap failed. Check that Python 3 and Flutter are installed.
goto :failed

:clean_failed
echo ERROR: flutter clean failed.
goto :failed

:pub_get_failed
echo ERROR: flutter pub get failed.
goto :failed

:build_failed
echo One or more builds failed; see the messages above.
pause
exit /b 1

:failed
echo.
pause
exit /b 1

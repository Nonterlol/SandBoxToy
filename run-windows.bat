@echo off
rem ==========================================================================
rem  Granule launcher for Windows (64-bit)
rem    run-windows.bat          -> run the game (downloads LOVE once if needed)
rem    run-windows.bat build    -> make a standalone dist\Granule\Granule.exe
rem ==========================================================================
setlocal EnableExtensions
cd /d "%~dp0"

set "LOVE_VER=11.5"
set "LOVE_DIR=%~dp0runtime\love-%LOVE_VER%-win64"
set "LOVE_URL=https://github.com/love2d/love/releases/download/%LOVE_VER%/love-%LOVE_VER%-win64.zip"
set "LOVE="

rem 1) portable copy downloaded by this script earlier
if exist "%LOVE_DIR%\love.exe" set "LOVE=%LOVE_DIR%\love.exe"
rem 2) normal LOVE installs
if not defined LOVE if exist "%ProgramFiles%\LOVE\love.exe" set "LOVE=%ProgramFiles%\LOVE\love.exe"
if not defined LOVE if exist "%ProgramFiles(x86)%\LOVE\love.exe" set "LOVE=%ProgramFiles(x86)%\LOVE\love.exe"
rem 3) love.exe on PATH
if not defined LOVE for /f "delims=" %%L in ('where love.exe 2^>nul') do if not defined LOVE set "LOVE=%%L"

rem 4) download a portable copy (about 10 MB, one time only)
if not defined LOVE (
  echo LOVE %LOVE_VER% runtime not found - downloading a portable copy...
  if not exist "%~dp0runtime" mkdir "%~dp0runtime"
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';" ^
    "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;" ^
    "Invoke-WebRequest -Uri '%LOVE_URL%' -OutFile '%~dp0runtime\love.zip';" ^
    "Expand-Archive -Force '%~dp0runtime\love.zip' '%~dp0runtime';" ^
    "Remove-Item '%~dp0runtime\love.zip'"
  if exist "%LOVE_DIR%\love.exe" (
    set "LOVE=%LOVE_DIR%\love.exe"
  ) else (
    echo.
    echo Download failed. Install LOVE 11.x from https://love2d.org and run this again.
    pause
    exit /b 1
  )
)

if /i "%~1"=="build" goto :build

echo Starting Granule with "%LOVE%"
start "" "%LOVE%" "%~dp0game"
exit /b 0

:build
rem Fuses love.exe + game into one exe and copies the DLLs next to it.
for %%D in ("%LOVE%") do set "LOVE_HOME=%%~dpD"
set "OUT=%~dp0dist\Granule"
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Compress-Archive -Force -Path '%~dp0game\*' -DestinationPath '%~dp0dist\granule.zip'"
if not exist "%~dp0dist\granule.zip" ( echo Packing failed. & pause & exit /b 1 )
move /y "%~dp0dist\granule.zip" "%~dp0dist\granule.love" >nul
copy /b "%LOVE_HOME%love.exe"+"%~dp0dist\granule.love" "%OUT%\Granule.exe" >nul
copy /y "%LOVE_HOME%*.dll" "%OUT%\" >nul
if exist "%LOVE_HOME%license.txt" copy /y "%LOVE_HOME%license.txt" "%OUT%\LOVE-license.txt" >nul
echo.
echo Built: %OUT%\Granule.exe   (zip the whole Granule folder to share it)
pause
exit /b 0

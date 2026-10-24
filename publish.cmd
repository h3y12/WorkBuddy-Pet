@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "wb_mode=%~1"
if "%wb_mode%"=="" set "wb_mode=framework"
set "wb_contained=false"
if /I "%wb_mode%"=="self-contained" set "wb_contained=true"
if /I not "%wb_mode%"=="framework" if /I not "%wb_mode%"=="self-contained" (
    echo Usage: publish.cmd [framework^|self-contained]
    exit /b 2
)
set "wb_dotnet=dotnet"
if defined DOTNET_ROOT if exist "%DOTNET_ROOT%\dotnet.exe" set "wb_dotnet=%DOTNET_ROOT%\dotnet.exe"
where %wb_dotnet% >nul 2>nul
if errorlevel 1 (
    echo Please install the .NET 10 SDK to build WbPet, or set DOTNET_ROOT.
    exit /b 1
)
"%wb_dotnet%" publish -c Release -r win-x64 ^
  --self-contained %wb_contained% -p:PublishSingleFile=true -p:DebugType=none ^
  -p:IncludeNativeLibrariesForSelfExtract=true ^
  -o "dist\%wb_mode%" -v minimal

if errorlevel 1 (
    echo.
    echo Publish failed. Close the existing WbPet process and check the build output.
    exit /b 1
)

echo.
echo Published: %~dp0dist\%wb_mode%\WbPet.exe
echo Please distribute the entire folder, including collector.py.
echo Python 3.10+ is required, or bundle the official embeddable Python in python\.
echo framework mode also requires .NET 10 Desktop Runtime x64.
dir /b "dist\%wb_mode%"

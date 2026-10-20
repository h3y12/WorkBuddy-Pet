@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

"C:\Program Files\dotnet\dotnet.exe" publish -c Release -r win-x64 ^
  --self-contained false -p:PublishSingleFile=true -p:DebugType=none ^
  -o dist -v minimal

if errorlevel 1 (
    echo.
    echo 发布失败。若提示文件被占用，先关掉正在运行的 WbPet.exe 再试。
    exit /b 1
)

echo.
echo 已生成: %~dp0dist\WbPet.exe
dir /b dist\WbPet.exe

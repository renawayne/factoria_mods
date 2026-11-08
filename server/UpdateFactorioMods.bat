@echo off
chcp 65001 >nul
setlocal
title Factorio - Update Death_train mods

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo PowerShell не найден.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UpdateFactorioMods.ps1"
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" (
    echo Готово. Моды проверены и обновлены.
) else (
    echo Обновление завершилось с ошибкой. Старые моды не должны быть затронуты.
)
pause
exit /b %RESULT%

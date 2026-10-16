@echo off
setlocal
set "SRC=%~dp0"
set "DEST=%USERPROFILE%\.claude\stfu-clawd-market"

where claude >nul 2>nul
if errorlevel 1 (
  echo [X] The "claude" command was not found. Install Claude Code first and make sure typing claude in PowerShell works.
  pause
  exit /b 1
)

if /i not "%SRC%"=="%DEST%\" (
  echo Copying the plugin to %DEST% ...
  if exist "%DEST%" rmdir /s /q "%DEST%"
  mkdir "%DEST%" >nul 2>nul
  xcopy "%SRC%*" "%DEST%\" /e /i /y /q >nul
)

echo Registering the plugin marketplace and installing ...
call claude plugin marketplace remove stfu-clawd-market >nul 2>nul
call claude plugin marketplace add "%DEST%"
if errorlevel 1 goto fail
call claude plugin install stfu-clawd@stfu-clawd-market
if errorlevel 1 goto fail

echo.
echo [OK] Installed! Restart Claude Code to activate it.
echo      Pause / resume: /stfu-clawd:stfu pause ^| resume ^| status
pause
exit /b 0

:fail
echo.
echo [X] Installation failed. Please share the error above. You can also run these manually:
echo     claude plugin marketplace add "%DEST%"
echo     claude plugin install stfu-clawd@stfu-clawd-market
pause
exit /b 1

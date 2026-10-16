@echo off
setlocal
set "DEST=%USERPROFILE%\.claude\stfu-clawd-market"

where claude >nul 2>nul
if errorlevel 1 (
  echo [X] The "claude" command was not found.
  pause
  exit /b 1
)

call claude plugin uninstall stfu-clawd@stfu-clawd-market
call claude plugin marketplace remove stfu-clawd-market
if exist "%DEST%" start "" /min cmd /c "timeout /t 2 >nul & rmdir /s /q ""%DEST%"""

echo.
echo [OK] STFU!Clawd has been uninstalled.
pause
exit /b 0

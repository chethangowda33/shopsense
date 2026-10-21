@echo off
rem Double-click to copy the saved Excel Ledger + Customers into MySQL.
py -3.12 "%~dp0python\refresh_mysql.py" %*
echo.
pause

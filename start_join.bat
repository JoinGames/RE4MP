@echo off
title RE4 LAN relay
set "DATA=X:\SteamLibrary\steamapps\common\RESIDENT EVIL 4  BIOHAZARD RE4\reframework\data"
set "PY=python"
where py >nul 2>nul && set "PY=py -3"
if not exist "%~dp0re4lan_relay.py" (
  echo re4lan_relay.py must be in the same folder as this .bat file
  pause
  exit /b 1
)
set /p HOSTIP=Enter HOST IP address (for example 192.168.1.23): 
%PY% "%~dp0re4lan_relay.py" join %HOSTIP% --data "%DATA%"
pause

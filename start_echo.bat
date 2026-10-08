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
%PY% "%~dp0re4lan_relay.py" echo --data "%DATA%"
pause

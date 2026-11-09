@echo off
title DeskMic Receiver Launcher
cd /d "%~dp0"
if exist "DeskMic_Receiver.exe" (
    start "" "DeskMic_Receiver.exe"
) else (
    python receiver.py
)
exit

@echo off
REM PRS1 Core Guard (Windows)
REM verify:
REM   tools\prs1_core_guard.bat
REM update:
REM   tools\prs1_core_guard.bat --update

dart run tool/prs1_core_guard.dart %*

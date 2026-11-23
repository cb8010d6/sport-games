@echo off
cd /d "%~dp0"
rem Creates hub\.venv on first run and reinstalls when requirements-runtime.txt changes (hashes enforced).
set "PY=python"
if exist .venv\Scripts\python.exe set "PY=.venv\Scripts\python.exe"
"%PY%" -m regina_hub.setup_env || exit /b 1
.venv\Scripts\python -m regina_hub %*

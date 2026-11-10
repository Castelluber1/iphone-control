@echo off
rem Duplo clique: liga o espelho (uxplay-windows) com as opcoes recomendadas e abre o controle do iPhone.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0iniciar.ps1" %*
if errorlevel 1 pause

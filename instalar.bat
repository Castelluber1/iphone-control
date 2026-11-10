@echo off
rem Duplo clique uma vez: gera o painel bin\iPhoneControl.exe e cria os atalhos "iPhone Control".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar.ps1" %*
pause

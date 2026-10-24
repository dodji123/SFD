@echo off
rem Démarre la plateforme SFD en développement :
rem   - l'API (FastAPI) sur le port 8100, dans sa propre fenêtre ;
rem   - l'application web (Vite) sur le port 5173, accessible sur le réseau local.
rem Pour le téléphone : http://<adresse IP de ce PC>:5173

set SFD_DIR=%~dp0

if not exist "%SFD_DIR%api\.env" (
  echo Fichier api\.env introuvable. Voir la configuration de developpement.
  pause
  exit /b 1
)

start "SFD API 8100" cmd /k "cd /d %SFD_DIR%api && python -m uvicorn app.main:app --port 8100"
start "SFD Web 5173" cmd /k "cd /d %SFD_DIR%web && npm run dev -- --host 0.0.0.0 --port 5173"

echo.
echo Serveurs lances dans deux fenetres.
echo   Sur ce PC      : http://localhost:5173
echo   Sur le reseau  : http://^<adresse IP du Wi-Fi^>:5173  (voir les lignes "Network" ci-dessus, dans la fenetre Web)
echo.
pause

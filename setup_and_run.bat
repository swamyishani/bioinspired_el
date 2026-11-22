@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM  Bio-inspired Swarm Simulator - Setup and Run (Windows)
REM ============================================================
REM  Put this file next to your unzipped EL_bioInspired folder
REM  (or edit PROJECT_ROOT below), then double-click it, or run
REM  it from a terminal:  setup_and_run.bat
REM ============================================================

REM ---- EDIT THESE IF NEEDED -----------------------------------
set "PROJECT_ROOT=%~dp0EL_bioInspired"
set "DB_HOST=127.0.0.1"
set "DB_PORT=3306"
set "DB_USER=root"
set "DB_PASSWORD=change-me"
set "DB_NAME=swarm_db"
REM ---------------------------------------------------------------

set "BACKEND=%PROJECT_ROOT%\swarm_backend"
set "FRONTEND=%PROJECT_ROOT%\swarm_frontend"

if not exist "%BACKEND%" (
    echo [ERROR] Could not find "%BACKEND%"
    echo Edit PROJECT_ROOT at the top of this script to point at the
    echo unzipped EL_bioInspired folder, then run this again.
    pause
    exit /b 1
)

echo.
echo === [1/6] Checking prerequisites ===
where python >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Python not found on PATH. Install Python 3.13+ first.
    pause
    exit /b 1
)
where npm >nul 2>nul
if errorlevel 1 (
    echo [ERROR] npm not found on PATH. Install Node.js first.
    pause
    exit /b 1
)
set "HAVE_MYSQL=1"
where mysql >nul 2>nul
if errorlevel 1 (
    echo [WARN] mysql client not found on PATH - DB schema step will be skipped.
    set "HAVE_MYSQL=0"
)

echo.
echo === [2/6] Setting up backend virtual environment ===
cd /d "%BACKEND%"
if not exist ".venv" (
    python -m venv .venv
)
call .venv\Scripts\activate.bat
python -m pip install --upgrade pip >nul
pip install -r requirements.txt
if errorlevel 1 (
    echo [ERROR] pip install failed. See output above.
    pause
    exit /b 1
)

echo.
echo === [3/6] Database schema ===
if "%HAVE_MYSQL%"=="0" (
    echo Skipping - mysql client not found. The app still runs without
    echo persistence; set DB_HOST etc. above and apply database\01_schema.sql
    echo and 02_views.sql manually once MySQL is available.
) else (
    echo database\01_schema.sql DROPS and recreates tables - only apply
    echo this once, on a fresh database.
    set /p CONFIRM="Apply schema to database '%DB_NAME%' now? [y/N]: "
    if /i "!CONFIRM!"=="y" (
        mysql -h %DB_HOST% -P %DB_PORT% -u %DB_USER% -p%DB_PASSWORD% < database\01_schema.sql
        mysql -h %DB_HOST% -P %DB_PORT% -u %DB_USER% -p%DB_PASSWORD% < database\02_views.sql
        if errorlevel 1 (
            echo [WARN] Schema apply failed - check your MySQL credentials above.
        ) else (
            echo Schema applied.
        )
    ) else (
        echo Skipped.
    )
)

echo.
echo === [4/6] Running backend test suite ===
python -m pytest -q
if errorlevel 1 (
    echo [WARN] Some tests failed - review the output above before
    echo trusting any results from this run.
    pause
)

echo.
echo === [5/6] Starting backend server (new window) ===
start "Swarm Backend" cmd /k "cd /d "%BACKEND%" && call .venv\Scripts\activate.bat && set DB_HOST=%DB_HOST%&& set DB_PORT=%DB_PORT%&& set DB_USER=%DB_USER%&& set DB_PASSWORD=%DB_PASSWORD%&& set DB_NAME=%DB_NAME%&& uvicorn api.server:app --reload --port 8000"

timeout /t 5 /nobreak >nul

echo.
echo === [6/6] Starting frontend (new window) ===
cd /d "%FRONTEND%"
if not exist "node_modules" (
    call npm install
)
start "Swarm Frontend" cmd /k "cd /d "%FRONTEND%" && npm run dev"

timeout /t 5 /nobreak >nul
start "" "http://localhost:3000"

echo.
echo ================================================================
echo  Backend   : http://127.0.0.1:8000     (window: "Swarm Backend")
echo  Frontend  : http://localhost:3000     (window: "Swarm Frontend")
echo  Runs page : http://localhost:3000/runs
echo.
echo  To stop everything, just close those two new terminal windows.
echo ================================================================
pause

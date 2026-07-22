@echo off
REM ============================================================
REM  One-click: fetch iPhone8,1 / iOS 15.8.7 kernelcache, commit, push.
REM  Pushing triggers GitHub Actions to build an OFFLINE TrollStore IPA.
REM  Requires: Python 3 installed + internet to Apple CDN (NO VPN needed).
REM ============================================================
cd /d %~dp0

echo [1/3] Fetching kernelcache for iPhone8,1 / iOS 15.8.7 ...
python3 tools\fetch_kernelcache_user.py
if errorlevel 1 (
    echo.
    echo Fetch FAILED. Check your internet connection to Apple servers.
    echo You can also run it manually:
    echo   python3 tools\fetch_kernelcache_user.py --device iPhone8,1 --version 15.8.7 --build 19H384
    pause
    exit /b 1
)

echo [2/3] Committing changes ...
git add -A
git commit -m "add iPhone8,1 15.8.7 kernelcache for offline install" || echo Nothing new to commit.

echo [3/3] Pushing to GitHub, which triggers the Actions build ...
git push origin main

echo.
echo Done. Open GitHub - Actions tab, wait for the build, then download the IPA from Artifacts.
pause

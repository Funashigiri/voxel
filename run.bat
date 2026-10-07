@echo off
rem Build and run the game. Extra arguments are passed to voxel.exe.
cd /d "%~dp0"
call "%~dp0build.bat" || (pause & exit /b 1)
"%~dp0bin\voxel.exe" %*

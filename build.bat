@echo off
rem Build Voxel.  Usage:  build.bat         (release, bin\voxel.exe)
rem                       build.bat debug   (debug,   bin\voxel_debug.exe)
setlocal
cd /d "%~dp0"

set "ODIN=odin"
where odin >nul 2>nul || set "ODIN=%USERPROFILE%\tools\odin\odin.exe"

if not exist bin mkdir bin

if /i "%~1"=="debug" (
    "%ODIN%" build src -out:bin\voxel_debug.exe -debug -vet-unused -vet-shadowing
) else (
    "%ODIN%" build src -out:bin\voxel.exe -o:speed
)
exit /b %errorlevel%

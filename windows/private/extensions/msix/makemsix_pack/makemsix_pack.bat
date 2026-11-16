@echo off
rem Usage: makemsix_pack.bat <makemsix> <layout_dir> <package>
rem
rem Runs `makemsix pack`, failing first with a clear message if the layout has symlinked directories
rem (or junctions), makemsix fails on them with an obscure "read failed" error.
setlocal

set "MAKEMSIX=%~1"
set "LAYOUT=%~2"
set "PACKAGE=%~3"
set "MAKEMSIX=%MAKEMSIX:/=\%"
set "LAYOUT=%LAYOUT:/=\%"

set "FOUND="
for /f "delims=" %%i in ('dir /a:ld /s /b "%LAYOUT%" 2^>nul') do (
    if not defined FOUND echo msix_package: the layout %LAYOUT% must not contain symlinked directories, makemsix cannot pack them: 1>&2
    set "FOUND=1"
    echo   %%i 1>&2
)
if defined FOUND exit /b 1

"%MAKEMSIX%" pack -d "%LAYOUT%" -p "%PACKAGE%"
exit /b %ERRORLEVEL%

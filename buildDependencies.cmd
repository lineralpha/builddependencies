@echo off
if defined _echo echo on

setlocal ENABLEDELAYEDEXPANSION

REM display usage
if "%1" == "/?" goto :usage
if "%1" == "-?" goto :usage

REM parse arguments
REM ===========================================================
:begin_arg_loop
set arg=%1
if not defined arg goto :exit_arg_loop

if /i "%arg%" == "/debug" (
    set debug=1
    goto :next_arg
)
if /i "%arg%" == "/restore" (
    set restore=1
    goto :next_arg
)
if /i "%arg%" == "/dryrun" (
    set dryrun=1
    goto :next_arg
)
if /i "%arg%" == "/n" (
    set dryrun=1
    goto :next_arg
)
if /i "%arg%" == "/resume" (
    set resume=1
    goto :next_arg
)
if /i "%arg%" == "/basepath" (
    if "%2" == "" (
        goto :invalid_basepath
    )
    set basepath=%2 & shift /1
    goto :next_arg
)
set buildargs=%buildargs% %arg%

:next_arg
shift /1 & goto :begin_arg_loop
REM ===========================================================

:exit_arg_loop

REM build command has to run in razzle environment
if not defined _NTTREE (
    echo [31m[%~nx0] Build must start in a razzle window.[0m
    goto :done
)

REM default source root
if not defined basepath set basepath="%_NTTREE%\sources\dev"
if not exist %basepath% (
    goto :invalid_basepath
)

REM expect one project file in current folder
for /f %%i in ('dir /b .\*.csproj') do set ProjFile=%%i
if not defined ProjFile (
    echo [33m[%~nx0] No project file found in %cd%.[0m
    goto :done
)

set switches=
if "%restore%" == "1" (
    set switches=%switch% -restore
)
if "%dryrun%" == "1" (
    set switches=%switches% -dryrun
)
if "%resume%" == "1" (
    set switches=%switches% -resume
)
if "%debug%" == "1" (
    set switches=%switches% -debug
)

REM launch the powershell script for building project
echo [%~nx0] Building %projFile%
echo [%~nx0] powershell.exe -ExecutionPolicy bypass -File "%~dpn0.ps1" "%projFile%" %basepath% %switches% -buildArgs "%buildargs%"
powershell.exe -ExecutionPolicy bypass -File "%~dpn0.ps1" "%projFile%" %basepath% %switches% -buildArgs "%buildargs%"

REM return from the batch script
:done
endlocal
exit /b

REM if the basepath is invalid
:invalid_basepath
echo [31m[%~nx0] Base path of sources must be specified after /basepath argument.[0m
goto :usage

REM help message
:usage
echo.
echo Syntax:
echo     %~nx0 [/dryrun ^| /n] [/resume] [/restore] [/debug] [/basepath ^<source-root-path^>] [^<build-command-args^>]
echo.
echo Description:
echo     Builds a project and all projects in its dependency tree through references.
echo.
echo Switches:
echo     /n or /dryrun
echo                Dry-run the build to analyze and display dependency tree.
echo.
echo     /resume    Resume build run from the point where prior run stopped.
echo.
echo     /restore   Run nuget package restore before building the projects.
echo.
echo     /debug     Output debug information from the script.
echo.
echo     /basepath ^<source-root-path^>
echo                Path to the base folder in the source repository where search starts.
echo                Defaults to "%%_NTTREE%%\sources\dev" if not specified.
echo.
echo     ^<build-command-args^>
echo                Additional arguments passed to build command as-is.
goto :done

@echo off
if defined _echo echo on

setlocal ENABLEDELAYEDEXPANSION

:: display usage
if "%1" == "/?" goto :usage
if "%1" == "-?" goto :usage

:: parse arguments
:: =============================================================================
:begin_arg_loop
set arg=%1
if not defined arg goto :exit_arg_loop

if /i [%arg%] == [-projectfile] (
    set _project_file=1
    goto :next_arg
)
if /i [%arg%] == [/projectfile] (
    set _project_file=1
    goto :next_arg
)
if /i [%arg%] == [-basepath] (
    set _base_path=1
    goto :next_arg
)
if /i [%arg%] == [/basepath] (
    set _base_path=1
    goto :next_arg
)
if /i [%arg%] == [-debug] (
    set _debug=1
    goto :next_arg
)
if /i [%arg%] == [/debug] (
    set _debug=1
    goto :next_arg
)

:next_arg
shift /1 & goto :begin_arg_loop
:: =============================================================================

:exit_arg_loop
if "%_debug%" == "1" echo on

:: build command has to run in razzle environment
if not defined _NTTREE (
    echo [31m[%~nx0] Build must start in a razzle window.[0m
    goto :done
)

:: the script requirements
where nuget.exe >nul 2>&1
if not "%errorlevel%" == "0" (
    if not defined NUGET_TOOL (
        echo [31m[%~nx0] nuget.exe was not found. Please set %%NUGET_TOOL%% and try again.[0m
        goto :done
    )
)
if defined NUGET_TOOL (
    echo [%~nx0] NUGET_TOOL=%NUGET_TOOL%
) else (
    for /f "tokens=* delims=" %%a in ('where nuget.exe') do set _nuget=%%a
    echo [%~nx0] nuget tool: !_nuget!
)

where getdeps.exe >nul 2>&1
if "%errorlevel%" == "0" (
    for /f "tokens=* delims=" %%a in ('where getdeps.exe') do set ALTER_NUGET_TOOL=%%a
)
echo [%~nx0] ALTER_NUGET_TOOL=%ALTER_NUGET_TOOL%

:: capture all arguments "as-is"
set args=%*

:: default base path if not specified
if not "%_base_path%" == "1" (
    set args=-BasePath "%_NTTREE%\sources\dev","%_NTTREE%\sources\PartnerRelease" %args%
)

:: expect only one project file in current folder if not specified
set _count=0
if not "%_project_file%" == "1" (
    for /f "tokens=* delims=" %%a in ('dir /b .\*.csproj') do set ProjectFile=%%a & set /a _count+=1
    if not defined ProjectFile (
        echo [33m[%~nx0] No project file found in %cd%.[0m
        goto :done
    )
    if not "!_count!" == "1" (
        echo [33m[%~nx0] Mutiple project files ^(count: !_count!^) found in %cd%.[0m
        echo [33m[%~nx0] Please specify a project file in the command line.[0m
        goto :done
    )
    set args=-ProjectFile "!ProjectFile!" %args%
)
echo [%~nx0] Project File: %ProjectFile%

:: make args friendly to powershell script and build command
:: (prefer -arg instead of /arg, single quotes instead of double quotes)
set args=%args:/=-%
set args=%args:"='%

:: launch the powershell script
echo [%~nx0] powershell.exe -ExecutionPolicy bypass -Command "& '%~dp0BuildDependencies.ps1' %args%"
powershell.exe -ExecutionPolicy bypass -Command "& '%~dp0BuildDependencies.ps1' %args%"

:: return from the batch script
:done
@echo off
endlocal
exit /b

:: help message
:usage
@echo off
echo.
echo Syntax:
echo    %~nx0 [/ProjectFile ^<project-file^>] [/BasePath ^<path1^>[,^<path2^>[,...]]] [Options]
echo.
echo Description:
echo    Builds a project and all projects in its dependency tree through assembly references.
echo.
echo Arguments:
echo    /ProjectFile ^<project-file^>
echo                The project file to build.
echo                Defaults to the csproj in current directory if not specified.
echo.
echo    /BasePath ^<path1^>[,^<path2^>[,...]]
echo                The paths to the root folders where dependency projects are searched.
echo                Multiple paths are delimited by comma (,). Each path must be separately
echo                double quoted if it contains blank spaces.
echo                Defaults to the root path of the source repository if not specified.
echo.
echo Options
echo    /Debug      Outputs debug information from the script.
echo.
echo    /DryRun     Dry-run the script to analyze and display dependency tree without
echo                actually building the dependency projects.
echo.
echo    /Keyword ^<keyword^>
echo                If specified, only the references whose path match this keyword
echo                are added to the dependency tree.
echo.
echo    /Resume     Resume build run from the point where prior run stopped.
echo.
echo    /Restore    Run nuget restore before building the projects.
echo.
echo    /BuildArgs ^<build-command-args^>
echo                Arguments passed to the build command "as-is".
goto :done
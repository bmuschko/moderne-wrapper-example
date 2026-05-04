@echo off
setlocal EnableDelayedExpansion

rem Custom Moderne CLI wrapper script (Windows)
rem Handles initialization (mod config commands).
rem Delegates actual CLI execution to modw.cmd.

set "SCRIPT_DIR=%~dp0"
set "MODW=%SCRIPT_DIR%modw.cmd"
set "MODERNE_TENANT=https://moderne.mycompany.com"
set "ARTIFACTORY_MAVEN_URL=https://artifactory.mycompany.com/maven"

rem ---------------------------------------------------------------------------
rem Route to init or run
rem ---------------------------------------------------------------------------
if "%~1"=="init" goto :init
if "%~1"=="" goto :usage
goto :run

:usage
echo Usage: %~nx0 init        — configure the CLI environment >&2
echo        %~nx0 ^<command^>   — run a mod CLI command >&2
exit /b 1

rem ---------------------------------------------------------------------------
rem Initialization
rem ---------------------------------------------------------------------------
:init
echo Configuring Moderne CLI environment... >&2

echo Setting Moderne tenant to %MODERNE_TENANT%... >&2
call "%MODW%" config moderne edit "%MODERNE_TENANT%" --api="%MODERNE_TENANT%" || goto :init_fail
echo Syncing license from Moderne platform... >&2
call "%MODW%" config license moderne sync || goto :init_fail
echo Configuring recipe artifacts from %ARTIFACTORY_MAVEN_URL%... >&2
call "%MODW%" config recipes artifacts artifactory edit "%ARTIFACTORY_MAVEN_URL%" || goto :init_fail
echo Disallowing Maven Central for artifact resolution... >&2
call "%MODW%" config features no-maven-central || goto :init_fail
echo CLI environment configured successfully. >&2
exit /b 0

:init_fail
echo Error: Initialization failed. >&2
exit /b 1

rem ---------------------------------------------------------------------------
rem Run CLI command
rem ---------------------------------------------------------------------------
:run
call "%MODW%" %*
exit /b %ERRORLEVEL%

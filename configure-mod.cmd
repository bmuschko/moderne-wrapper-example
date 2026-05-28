@echo off
setlocal EnableDelayedExpansion

rem Configures the Moderne CLI environment.
rem Expects "mod" to already be on the PATH (installed via modw.cmd).

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
call mod config moderne edit "%MODERNE_TENANT%" --api="%MODERNE_TENANT%" || goto :init_fail
echo Disallowing Maven Central for artifact resolution... >&2
call mod config features no-maven-central || goto :init_fail
echo Configuring recipe artifacts from %ARTIFACTORY_MAVEN_URL%... >&2
call mod config recipes artifacts artifactory add "%ARTIFACTORY_MAVEN_URL%" || goto :init_fail
echo CLI environment configured successfully. >&2
exit /b 0

:init_fail
echo Error: Initialization failed. >&2
exit /b 1

rem ---------------------------------------------------------------------------
rem Run CLI command
rem ---------------------------------------------------------------------------
:run
call mod %*
exit /b %ERRORLEVEL%

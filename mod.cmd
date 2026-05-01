@echo off
setlocal EnableDelayedExpansion

rem Custom Moderne CLI wrapper script (Windows)
rem Handles initialization (mod config commands) and telemetry publishing.
rem Delegates actual CLI execution to modw.cmd.

set "SCRIPT_DIR=%~dp0"
set "MODW=%SCRIPT_DIR%modw.cmd"

if defined MODERNE_CLI_HOME (
    set "TELEMETRY_DIR=%MODERNE_CLI_HOME%\trace"
) else (
    set "TELEMETRY_DIR=%USERPROFILE%\.moderne\cli\trace"
)

rem ---------------------------------------------------------------------------
rem Route to init or run
rem ---------------------------------------------------------------------------
if "%~1"=="init" goto :init
if "%~1"=="" goto :usage
goto :run

:usage
echo Usage: %~nx0 init        — configure the CLI environment >&2
echo        %~nx0 ^<command^>   — run a mod CLI command with telemetry >&2
exit /b 1

rem ---------------------------------------------------------------------------
rem Initialization
rem ---------------------------------------------------------------------------
:init
echo Configuring Moderne CLI environment... >&2

call "%MODW%" config license moderne sync || goto :init_fail
call "%MODW%" config recipes moderne sync || goto :init_fail
call "%MODW%" config features no-maven-central || goto :init_fail
call "%MODW%" config http trust-store edit file --path "%SCRIPT_DIR%certs\corporate-ca.pem" || goto :init_fail

echo CLI environment configured successfully. >&2
exit /b 0

:init_fail
echo Error: Initialization failed. >&2
exit /b 1

rem ---------------------------------------------------------------------------
rem Run CLI command and publish telemetry
rem ---------------------------------------------------------------------------
:run
set "COMMAND_NAME=%~1"

call "%MODW%" %*
set "CLI_EXIT_CODE=%ERRORLEVEL%"

rem Publish telemetry if BI_ENDPOINT is set
if not defined BI_ENDPOINT goto :done

set "SEARCH_DIR=%TELEMETRY_DIR%\%COMMAND_NAME%"
if not exist "%SEARCH_DIR%" goto :done

echo Publishing telemetry data to %BI_ENDPOINT%... >&2

for /r "%SEARCH_DIR%" %%f in (*.csv) do (
    set "CSV_FILE=%%f"
    set "PARENT_DIR=%%~dpf"

    set "CURL_CMD=curl -X POST -H "Content-Type: text/csv" --data-binary @"%%f""

    if defined BI_AUTH_USER if defined BI_AUTH_PASS (
        set "CURL_CMD=!CURL_CMD! --user "!BI_AUTH_USER!:!BI_AUTH_PASS!""
    )

    set "CURL_CMD=!CURL_CMD! "%BI_ENDPOINT%" --silent --fail --show-error"

    !CURL_CMD! >nul 2>&1 && (
        echo [OK] Published: %%f >&2
        rmdir /s /q "!PARENT_DIR!" 2>nul
    ) || (
        echo [WARN] Failed to publish: %%f >&2
    )
)

:done
exit /b %CLI_EXIT_CODE%

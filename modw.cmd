@echo off
setlocal EnableDelayedExpansion

rem Moderne CLI Wrapper for Windows
rem Downloads and caches the Moderne CLI distribution, then executes it.

set "SCRIPT_DIR=%~dp0"
set "PROPERTIES_FILE=%SCRIPT_DIR%moderne\wrapper\moderne-wrapper.properties"

if defined MODERNE_CLI_HOME (
    set "CLI_HOME=%MODERNE_CLI_HOME%"
) else (
    set "CLI_HOME=%USERPROFILE%\.moderne\cli"
)
set "DIST_DIR=%CLI_HOME%\dist"

rem ---------------------------------------------------------------------------
rem Read properties
rem ---------------------------------------------------------------------------
set "VERSION=RELEASE"
set "BASE_URL=https://repo1.maven.org/maven2/io/moderne"

if not exist "%PROPERTIES_FILE%" (
    echo Error: Cannot find %PROPERTIES_FILE% >&2
    exit /b 1
)

for /f "usebackq tokens=1,* delims==" %%a in ("%PROPERTIES_FILE%") do (
    if "%%a"=="version" set "VERSION=%%b"
    if "%%a"=="distributionUrl" set "BASE_URL=%%b"
)

rem Environment variable overrides
if defined MODERNE_WRAPPER_VERSION set "VERSION=%MODERNE_WRAPPER_VERSION%"
if defined MODERNE_WRAPPER_DISTRIBUTION_URL set "BASE_URL=%MODERNE_WRAPPER_DISTRIBUTION_URL%"

rem ---------------------------------------------------------------------------
rem Resolve RELEASE version via maven-metadata.xml
rem ---------------------------------------------------------------------------
if "%VERSION%"=="RELEASE" (
    set "METADATA_URL=%BASE_URL%/moderne-cli-windows/maven-metadata.xml"
    set "METADATA_FILE=%DIST_DIR%\maven-metadata.xml"
    if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"

    curl --silent --fail --show-error --output "%METADATA_FILE%" "!METADATA_URL!" || (
        echo Error: Failed to fetch version metadata from !METADATA_URL! >&2
        exit /b 1
    )

    for /f "tokens=2 delims=<>" %%v in ('findstr /r "<release>" "%METADATA_FILE%"') do (
        set "VERSION=%%v"
    )
    del "%METADATA_FILE%" 2>nul

    if "!VERSION!"=="RELEASE" (
        echo Error: Could not resolve RELEASE version from metadata >&2
        exit /b 1
    )
)

rem ---------------------------------------------------------------------------
rem Download distribution if not cached
rem ---------------------------------------------------------------------------
set "ARTIFACT=moderne-cli-windows"
set "FILENAME=%ARTIFACT%-%VERSION%.zip"
set "CACHED=%DIST_DIR%\%FILENAME%"
set "EXTRACT_DIR=%DIST_DIR%\%ARTIFACT%-%VERSION%"

if not exist "%EXTRACT_DIR%\bin\mod.exe" (
    set "DOWNLOAD_URL=%BASE_URL%/%ARTIFACT%/%VERSION%/%FILENAME%"

    if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"

    echo Downloading Moderne CLI %VERSION% for Windows... >&2
    echo   !DOWNLOAD_URL! >&2

    curl --silent --fail --show-error --location --output "%CACHED%" "!DOWNLOAD_URL!" || (
        del "%CACHED%" 2>nul
        echo Error: Failed to download CLI from !DOWNLOAD_URL! >&2
        exit /b 1
    )

    rem Verify SHA-256 checksum
    set "SHA256_URL=!DOWNLOAD_URL!.sha256"
    set "SHA256_FILE=%DIST_DIR%\%FILENAME%.sha256"
    curl --silent --fail --output "!SHA256_FILE!" "!SHA256_URL!" 2>nul
    if exist "!SHA256_FILE!" (
        for /f "tokens=1" %%s in ('type "!SHA256_FILE!"') do set "EXPECTED_SHA=%%s"
        for /f "skip=1 tokens=*" %%h in ('certutil -hashfile "%CACHED%" SHA256') do (
            if not defined ACTUAL_SHA set "ACTUAL_SHA=%%h"
        )
        if /i not "!ACTUAL_SHA!"=="!EXPECTED_SHA!" (
            del "%CACHED%" 2>nul
            del "!SHA256_FILE!" 2>nul
            echo Error: SHA-256 checksum mismatch >&2
            echo   Expected: !EXPECTED_SHA! >&2
            echo   Actual:   !ACTUAL_SHA! >&2
            exit /b 1
        )
        echo   Checksum verified. >&2
        del "!SHA256_FILE!" 2>nul
    )

    rem Extract ZIP
    echo   Extracting... >&2
    if not exist "%EXTRACT_DIR%" mkdir "%EXTRACT_DIR%"
    powershell -NoProfile -Command "Expand-Archive -Path '%CACHED%' -DestinationPath '%EXTRACT_DIR%' -Force" || (
        echo Error: Failed to extract %CACHED% >&2
        exit /b 1
    )
    del "%CACHED%" 2>nul
)

rem ---------------------------------------------------------------------------
rem Find and execute the CLI
rem ---------------------------------------------------------------------------
if exist "%EXTRACT_DIR%\bin\mod.exe" (
    "%EXTRACT_DIR%\bin\mod.exe" %*
    exit /b %ERRORLEVEL%
)

rem Fallback: look for mod.exe directly in the extract dir
for /r "%EXTRACT_DIR%" %%f in (mod.exe) do (
    "%%f" %*
    exit /b %ERRORLEVEL%
)

echo Error: Could not find mod.exe in %EXTRACT_DIR% >&2
exit /b 1

@echo off
rem
rem Moderne CLI wrapper script for Windows.
rem Downloads a platform-specific distribution (JAR + JRE) from Maven Central,
rem creates a Project Leyden AOT cache on first run, then launches the CLI.
rem
rem Environment variables:
rem   MODERNE_JAVA_HOME  - Use this JDK instead of auto-detection
rem   MODERNE_JAR        - Use this JAR instead of auto-detection
rem   MODERNE_OPTS       - Additional JVM options (e.g. -Xmx2g)
rem   MODERNE_CLI_HOME   - Base CLI directory (default: %USERPROFILE%\.moderne\cli)
rem   MODERNE_WRAPPER_DISTRIBUTION_USERNAME - Basic auth username for distribution downloads
rem   MODERNE_WRAPPER_DISTRIBUTION_PASSWORD - Basic auth password for distribution downloads
rem   MODERNE_WRAPPER_DISTRIBUTION_TOKEN    - Bearer token for distribution downloads
rem   MODERNE_WRAPPER_DISTRIBUTION_URL      - Override distributionUrl without properties file
rem   MODERNE_WRAPPER_VERSION               - Override CLI version without properties file
rem

rem Switch console to UTF-8 so Unicode characters (icons, box-drawing) render correctly
chcp 65001 >nul 2>&1

setlocal enabledelayedexpansion

if not defined MODERNE_CLI_HOME set "MODERNE_CLI_HOME=%USERPROFILE%\.moderne\cli"
set "DIST_DIR=%MODERNE_CLI_HOME%\dist"
set "MIN_JAVA_VERSION=25"
set "SONATYPE_SNAPSHOTS=https://central.sonatype.com/repository/maven-snapshots"
set "MAVEN_CENTRAL=https://repo1.maven.org/maven2"

rem --- Locate properties file ---
set "PROPS_FILE="
if exist "moderne\wrapper\moderne-wrapper.properties" (
    set "PROPS_FILE=moderne\wrapper\moderne-wrapper.properties"
) else if exist "%DIST_DIR%\moderne-wrapper.properties" (
    set "PROPS_FILE=%DIST_DIR%\moderne-wrapper.properties"
)

rem --- Authentication ---
set "DIST_USERNAME="
set "DIST_PASSWORD="
set "DIST_TOKEN="
if defined MODERNE_WRAPPER_DISTRIBUTION_USERNAME set "DIST_USERNAME=%MODERNE_WRAPPER_DISTRIBUTION_USERNAME%"
if defined MODERNE_WRAPPER_DISTRIBUTION_PASSWORD set "DIST_PASSWORD=%MODERNE_WRAPPER_DISTRIBUTION_PASSWORD%"
if defined MODERNE_WRAPPER_DISTRIBUTION_TOKEN set "DIST_TOKEN=%MODERNE_WRAPPER_DISTRIBUTION_TOKEN%"
rem Fall back to properties file
if not defined DIST_USERNAME if not defined DIST_TOKEN if defined PROPS_FILE (
    for /f "tokens=1,* delims==" %%a in ('findstr /b "distributionUsername=" "%PROPS_FILE%" 2^>nul') do set "DIST_USERNAME=%%b"
    for /f "tokens=1,* delims==" %%a in ('findstr /b "distributionPassword=" "%PROPS_FILE%" 2^>nul') do set "DIST_PASSWORD=%%b"
    for /f "tokens=1,* delims==" %%a in ('findstr /b "distributionToken=" "%PROPS_FILE%" 2^>nul') do set "DIST_TOKEN=%%b"
)
rem Token takes precedence over username/password
if defined DIST_TOKEN (
    set "DIST_USERNAME="
    set "DIST_PASSWORD="
)
rem Build CURL_AUTH argument
set "CURL_AUTH="
if defined DIST_TOKEN (
    set "CURL_AUTH=-H "Authorization: Bearer !DIST_TOKEN!""
) else if defined DIST_USERNAME (
    set "CURL_AUTH=--user "!DIST_USERNAME!:!DIST_PASSWORD!""
)

call :ensure_distribution
if errorlevel 1 goto :eof_error

call :find_java
if errorlevel 1 goto :eof_error

call :find_jar
if errorlevel 1 goto :eof_error

rem --- Extract nested JARs from fat JAR ---
rem Compute the extraction directory in-process (avoids a cold JVM start on every run).
rem ModerneLauncher uses:  %MODERNE_CLI_HOME%\dist\classpath\<version>
rem
rem Resolve CLI_VERSION cheaply when we can. PowerShell is the source of truth for
rem dev/maven-local builds (where MOD_JAR may not match version.txt), but it costs
rem ~1s of startup. Order of preference:
rem   1. MOD_VERSION set by :ensure_distribution (distribution path only; never for
rem      MODERNE_JAR overrides or dev builds, and skipped when MOD_SOURCE=maven-local
rem      because MOD_VERSION reflects the distribution, not the local jar)
rem   2. version.txt when MOD_JAR is the installed distribution jar
rem   3. PowerShell manifest read (fallback for dev/maven-local)
set "CLI_VERSION="
if defined MOD_VERSION if not defined MOD_SOURCE set "CLI_VERSION=!MOD_VERSION!"
if not defined CLI_VERSION if not defined MOD_SOURCE if exist "%DIST_DIR%\version.txt" (
    if /i "!MOD_JAR!"=="%DIST_DIR%\lib\moderne-cli.jar" set /p CLI_VERSION=<"%DIST_DIR%\version.txt"
)
if not defined CLI_VERSION (
    for /f "delims=" %%v in ('powershell -NoProfile -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[IO.Compression.ZipFile]::OpenRead('%MOD_JAR%'); $e=$z.GetEntry('META-INF/MANIFEST.MF'); $r=[IO.StreamReader]::new($e.Open()); while(($l=$r.ReadLine()) -ne $null){if($l -match '^Implementation-Version:\s*(.+)'){$Matches[1].Trim();break}}; $r.Close(); $z.Dispose()" 2^>nul') do set "CLI_VERSION=%%v"
)
if not defined CLI_VERSION set "CLI_VERSION=unknown"
set "EXTRACTED_DIR=%DIST_DIR%\classpath\!CLI_VERSION!"

rem Only invoke the extraction JVM when the marker is missing or the JAR has changed.
rem .extraction-complete is written by ModerneLauncher and carries a Java-format
rem fingerprint that CMD can't reproduce (epoch-seconds mtime). We write a sidecar
rem in CMD's native format (%%~tF|%%~zF, matching the AOT-stamp pattern at lines
rem 241/274) and compare against that, avoiding a PowerShell launch on every run.
set "EXTRACTION_STAMP=!EXTRACTED_DIR!\.extraction-complete.cmd-stamp"
set "JAR_FINGER="
for %%F in ("!MOD_JAR!") do set "JAR_FINGER=%%~tF|%%~zF"
set "_NEED_EXTRACT=0"
if not exist "!EXTRACTED_DIR!\.extraction-complete" (
    set "_NEED_EXTRACT=1"
) else if not exist "!EXTRACTION_STAMP!" (
    set "_NEED_EXTRACT=1"
) else (
    set "OLD_EXTRACT_FINGER="
    set /p OLD_EXTRACT_FINGER=<"!EXTRACTION_STAMP!"
    if "!OLD_EXTRACT_FINGER!" neq "!JAR_FINGER!" set "_NEED_EXTRACT=1"
)
if "!_NEED_EXTRACT!"=="1" (
    "%JAVA_CMD%" -Xlog:all=off -cp "%MOD_JAR%" io.moderne.cli.launcher.ModerneLauncher --extract-only >nul 2>&1
    if exist "!EXTRACTED_DIR!\.extraction-complete" (
        for %%F in ("!MOD_JAR!") do >"!EXTRACTION_STAMP!" echo %%~tF^|%%~zF
    )
)

rem Build the classpath from extracted JARs. The extraction layout places JARs
rem under META-INF/lib/, META-INF/cli/, and other subdirectories.
rem AOT_CP excludes the extraction directory itself (a non-empty directory entry
rem causes AOT cache creation to fail); the full CLASSPATH adds it so that
rem getResourceAsStream("META-INF/modmaven/manifest.txt") works at runtime.
set "AOT_CP=!EXTRACTED_DIR!\META-INF\cli\*;!EXTRACTED_DIR!\META-INF\lib\*"
set "CLASSPATH=!AOT_CP!;!EXTRACTED_DIR!"

rem Detect invocation name (mod vs modw) for shell completion and help text
set "SCRIPT_NAME=%~n0"

rem --- Debug support ---
rem Detect --debug/--debug=PORT without iterating arguments.
rem CMD's `for %%a in (%*)` treats = as a token delimiter, which breaks
rem arguments like `-P key=value` and `--debug=PORT`. Instead, we detect
rem --debug via string matching on the raw argument string and pass %*
rem through to Java intact.
set "DEBUG_PORT="
set "_MOD_ARGS_=%*"
if not defined _MOD_ARGS_ goto :debug_done

rem Check for --debug=PORT (more specific, must check first)
echo.%* | findstr /c:"--debug=" >nul 2>&1
if not errorlevel 1 (
    set "_TAIL_=!_MOD_ARGS_:*--debug=!"
    rem _TAIL_ starts with "=PORT ..." because CMD substitution can't include = in search;
    rem strip the leading = to get "PORT ..."
    set "_TAIL_=!_TAIL_:~1!"
    for /f "tokens=1" %%p in ("!_TAIL_!") do set "DEBUG_PORT=%%p"
    rem Remove --debug=PORT from args (CMD substitution cannot handle = in search)
    for /f "usebackq delims=" %%r in (`powershell -NoProfile -Command ^
        "Write-Output (($env:_MOD_ARGS_ -replace '--debug=\d+\s*','').Trim())"`) do set "_MOD_ARGS_=%%r"
    goto :debug_done
)

rem Check for standalone --debug
set "_CHECK_= %* "
echo.!_CHECK_! | findstr /c:" --debug " >nul 2>&1
if not errorlevel 1 (
    set "DEBUG_PORT=5005"
    set "_MOD_ARGS_= !_MOD_ARGS_! "
    set "_MOD_ARGS_=!_MOD_ARGS_: --debug = !"
    for /f "tokens=*" %%a in ("!_MOD_ARGS_!") do set "_MOD_ARGS_=%%a"
)

:debug_done

rem --- GC selection ---
rem G1 unconditionally. Computed once and used both during AOT cache training
rem and at the final exec, so the cache's compressed-oops state matches what
rem the runtime JVM will use. Without this, a cache trained under one GC fails
rem to load when MODERNE_OPTS overrides to a different GC at runtime. A single
rem GC also keeps the cache stable across command types - the cache is keyed
rem on the training GC and would otherwise retrain on every toggle.
rem
rem If MODERNE_OPTS specifies a GC, defer to it: setting two GCs on one
rem command line is "last-wins with a warning" in HotSpot, and the warning
rem is noisy. Extract just the GC selectors from MODERNE_OPTS for training
rem (heap-size and pre-touch flags would slow training without affecting the
rem cache's GC compatibility).
set "TRAINING_GC_FLAGS="
set "JVM_ARGS_GC_FLAGS="
set "_HAS_GC_OVERRIDE=0"
if defined MODERNE_OPTS (
    echo.!MODERNE_OPTS! | findstr /c:"UseG1GC" /c:"UseZGC" /c:"UseSerialGC" /c:"UseParallelGC" /c:"UseShenandoahGC" /c:"UseEpsilonGC" >nul 2>&1
    if not errorlevel 1 set "_HAS_GC_OVERRIDE=1"
)
if "!_HAS_GC_OVERRIDE!"=="1" (
    for %%f in (!MODERNE_OPTS!) do (
        set "_T=%%f"
        set "_KEEP=0"
        if /i "!_T:~0,8!"=="-XX:+Use" if /i "!_T:~-2!"=="GC" set "_KEEP=1"
        if /i "!_T:~0,8!"=="-XX:-Use" if /i "!_T:~-2!"=="GC" set "_KEEP=1"
        if /i "!_T!"=="-XX:+ZGenerational" set "_KEEP=1"
        if /i "!_T!"=="-XX:-ZGenerational" set "_KEEP=1"
        if "!_KEEP!"=="1" (
            if defined TRAINING_GC_FLAGS (
                set "TRAINING_GC_FLAGS=!TRAINING_GC_FLAGS! !_T!"
            ) else (
                set "TRAINING_GC_FLAGS=!_T!"
            )
        )
    )
    rem Don't duplicate the GC selector in JVM_ARGS - MODERNE_OPTS will
    rem add it during the final exec.
    set "JVM_ARGS_GC_FLAGS="
) else (
    set "TRAINING_GC_FLAGS=-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ParallelRefProcEnabled"
    set "JVM_ARGS_GC_FLAGS=!TRAINING_GC_FLAGS!"
)

rem --- Project Leyden AOT cache ---
set "AOT_DIR=%DIST_DIR%\aot"
set "AOT_CACHE=%AOT_DIR%\mod.aot"
set "AOT_CONFIG=%AOT_DIR%\mod.aot.config"
set "AOT_STAMP=%AOT_DIR%\mod.aot.jar-stamp"
set "AOT_JAR_PATH_STAMP=%AOT_DIR%\mod.aot.jar-path"
set "AOT_JAR_FINGERPRINT=%AOT_DIR%\mod.aot.jar-fingerprint"
set "AOT_JAVA_STAMP=%AOT_DIR%\mod.aot.java-path"
set "AOT_GC_STAMP=%AOT_DIR%\mod.aot.gc-stamp"
set "VERSION_FILE=%DIST_DIR%\version.txt"

rem Invalidate AOT cache if the CLI version or jar path has changed
set "AOT_STALE="
if exist "%AOT_CACHE%" (
    if exist "!AOT_STAMP!" (
        if exist "%VERSION_FILE%" (
            set /p OLD_STAMP=<"!AOT_STAMP!"
            set /p CURRENT_VERSION=<"%VERSION_FILE%"
            if "!CURRENT_VERSION!" neq "!OLD_STAMP!" set "AOT_STALE=1"
        ) else (
            set "AOT_STALE=1"
        )
    ) else (
        set "AOT_STALE=1"
    )
    if exist "!AOT_JAR_PATH_STAMP!" (
        set /p OLD_JAR_PATH=<"!AOT_JAR_PATH_STAMP!"
        if "!OLD_JAR_PATH!" neq "!MOD_JAR!" set "AOT_STALE=1"
    ) else (
        set "AOT_STALE=1"
    )
    if exist "!AOT_JAVA_STAMP!" (
        set /p OLD_JAVA_PATH=<"!AOT_JAVA_STAMP!"
        if "!OLD_JAVA_PATH!" neq "!JAVA_CMD!" set "AOT_STALE=1"
    )
    for %%F in ("!MOD_JAR!") do set "JAR_FINGER=%%~tF|%%~zF"
    if exist "!AOT_JAR_FINGERPRINT!" (
        set /p OLD_FINGER=<"!AOT_JAR_FINGERPRINT!"
        if "!OLD_FINGER!" neq "!JAR_FINGER!" set "AOT_STALE=1"
    ) else (
        set "AOT_STALE=1"
    )
    rem GC mismatch: a cache trained under one GC can't be loaded under
    rem another (compressed-oops state differs). The most common case is a
    rem caller setting MODERNE_OPTS to a non-default GC after the cache has
    rem already been trained under the default.
    if exist "!AOT_GC_STAMP!" (
        set /p OLD_GC=<"!AOT_GC_STAMP!"
        if "!OLD_GC!" neq "!TRAINING_GC_FLAGS!" set "AOT_STALE=1"
    ) else (
        set "AOT_STALE=1"
    )
    if defined AOT_STALE del "%AOT_CACHE%" "%AOT_CONFIG%" 2>nul
)

rem Stamp resolved CLI version and jar path for AOT invalidation
rem Only write stamp files when something changed (AOT_STALE) or on first run (no AOT cache)
set "_WRITE_STAMPS="
if defined AOT_STALE set "_WRITE_STAMPS=1"
if not exist "%AOT_CACHE%" set "_WRITE_STAMPS=1"
if defined _WRITE_STAMPS (
    if defined MOD_VERSION (
        if not exist "%AOT_DIR%" mkdir "%AOT_DIR%"
        >"%AOT_STAMP%" echo !MOD_VERSION!
        >"%VERSION_FILE%" echo !MOD_VERSION!
    )
    if not exist "%AOT_DIR%" mkdir "%AOT_DIR%"
    >"%AOT_JAR_PATH_STAMP%" echo !MOD_JAR!
    for %%F in ("!MOD_JAR!") do >"%AOT_JAR_FINGERPRINT%" echo %%~tF^|%%~zF
    >"%AOT_JAVA_STAMP%" echo !JAVA_CMD!
    >"%AOT_GC_STAMP%" echo !TRAINING_GC_FLAGS!
)

rem Create AOT cache if it doesn't exist (two-phase Leyden training).
rem Phase 1 (record): runs --version to record class loading into a config file.
rem Phase 2 (create): assembles the AOT cache from the recording (no app execution).
rem AOT phases use AOT_CP (without the extraction directory) to avoid the
rem "directory is not empty" error during cache assembly. TRAINING_GC_FLAGS
rem is passed so the cache's compressed-oops state matches the runtime JVM.
if not exist "%AOT_CACHE%" (
    if not exist "%AOT_DIR%" mkdir "%AOT_DIR%"
    "%JAVA_CMD%" -Xlog:all=off --enable-native-access=ALL-UNNAMED --sun-misc-unsafe-memory-access=allow !TRAINING_GC_FLAGS! -Dmod.command.name=%SCRIPT_NAME% -XX:AOTMode=record -XX:AOTConfiguration="%AOT_CONFIG%" -cp "%MOD_JAR%;%AOT_CP%" io.moderne.cli.commands.Mod --version >nul 2>&1
    if exist "%AOT_CONFIG%" (
        "%JAVA_CMD%" -Xlog:all=off --enable-native-access=ALL-UNNAMED --sun-misc-unsafe-memory-access=allow !TRAINING_GC_FLAGS! -XX:AOTMode=create -XX:AOTConfiguration="%AOT_CONFIG%" -XX:AOTCache="%AOT_CACHE%" -cp "%MOD_JAR%;%AOT_CP%" >nul 2>&1
    )
)

rem Build JVM args.
set "JVM_ARGS=!JVM_ARGS_GC_FLAGS! --enable-native-access=ALL-UNNAMED --sun-misc-unsafe-memory-access=allow -Xlog:all=warning:stderr"
if not defined DEBUG_PORT (
    if exist "%AOT_CACHE%" (
        rem Verify the jar stamped in the cache still exists on disk
        if exist "!AOT_JAR_PATH_STAMP!" (
            set /p STAMPED_JAR=<"!AOT_JAR_PATH_STAMP!"
            if exist "!STAMPED_JAR!" (
                set "JVM_ARGS=!JVM_ARGS! -XX:AOTCache=%AOT_CACHE%"
            ) else (
                del "%AOT_CACHE%"
            )
        ) else (
            set "JVM_ARGS=!JVM_ARGS! -XX:AOTCache=%AOT_CACHE%"
        )
    )
)

if defined DEBUG_PORT (
    set "JVM_ARGS=!JVM_ARGS! -agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=localhost:!DEBUG_PORT!"
)

set "MOD_SOURCE_ARG="
if defined MOD_SOURCE set "MOD_SOURCE_ARG=-Dmod.source=!MOD_SOURCE!"

rem Translate persisted SSL/proxy config in moderne.yml into -D flags. The JVM needs
rem these in place at startup — agents like Pyroscope build their TrustManagers at
rem Agent_OnLoad premain time, before SslConfiguration in Java can call setProperty.
rem SSL_ARGS goes BEFORE MODERNE_OPTS so MODERNE_OPTS overrides config (env wins).
rem Helper uses SerialGC for fastest startup; no AOT cache (existing cache is for Mod).
rem
rem The resolver's output is deterministic from moderne.yml plus the CLI jar (the
rem jar so an upgrade that changes the resolver busts the cache). Cache the output
rem and skip the JVM spawn entirely on a cache hit. Cost is ~1.4s on cold misses.
set "JVM_ARGS_CACHE=%DIST_DIR%\jvm-args.cache"
set "JVM_ARGS_FINGERPRINT=%DIST_DIR%\jvm-args.fingerprint"
set "MODERNE_YML=%MODERNE_CLI_HOME%\moderne.yml"
set "YML_FINGER=<none>"
if exist "!MODERNE_YML!" (
    for %%F in ("!MODERNE_YML!") do set "YML_FINGER=%%~tF|%%~zF"
)
set "JVM_ARGS_FINGER_CURRENT=!YML_FINGER!@!JAR_FINGER!"
set "_JVM_ARGS_CACHE_VALID=0"
if exist "!JVM_ARGS_FINGERPRINT!" if exist "!JVM_ARGS_CACHE!" (
    set "OLD_JVM_ARGS_FINGER="
    set /p OLD_JVM_ARGS_FINGER=<"!JVM_ARGS_FINGERPRINT!"
    if "!OLD_JVM_ARGS_FINGER!"=="!JVM_ARGS_FINGER_CURRENT!" set "_JVM_ARGS_CACHE_VALID=1"
)
if "!_JVM_ARGS_CACHE_VALID!"=="0" (
    if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
    "%JAVA_CMD%" -Xlog:all=off --enable-native-access=ALL-UNNAMED --sun-misc-unsafe-memory-access=allow -XX:+UseSerialGC -cp "%MOD_JAR%;%CLASSPATH%" io.moderne.cli.config.JvmArgsResolver >"!JVM_ARGS_CACHE!" 2>nul
    if errorlevel 1 (
        del "!JVM_ARGS_CACHE!" "!JVM_ARGS_FINGERPRINT!" 2>nul
    ) else (
        >"!JVM_ARGS_FINGERPRINT!" echo !JVM_ARGS_FINGER_CURRENT!
    )
)
set "SSL_ARGS="
if exist "!JVM_ARGS_CACHE!" (
    for /f "usebackq delims=" %%a in ("!JVM_ARGS_CACHE!") do (
        if defined SSL_ARGS (set "SSL_ARGS=!SSL_ARGS! %%a") else (set "SSL_ARGS=%%a")
    )
)

"%JAVA_CMD%" %JVM_ARGS% %SSL_ARGS% %MODERNE_OPTS% -Dmod.command.name=%SCRIPT_NAME% -Dmod.jar="%MOD_JAR%" %MOD_SOURCE_ARG% -cp "%MOD_JAR%;%CLASSPATH%" io.moderne.cli.commands.Mod %_MOD_ARGS_%
exit /b %errorlevel%

rem === Subroutines ===

:acquire_install_lock
rem Serializes ensure_distribution and download_jdk across concurrent wrapper
rem invocations sharing %MODERNE_CLI_HOME%. Atomic via mkdir; stale holders are
rem detected via the lock directory's age (CMD has no portable PID liveness check).
set "_LOCK_DIR=%MODERNE_CLI_HOME%\.install-lock"
if not exist "%MODERNE_CLI_HOME%" mkdir "%MODERNE_CLI_HOME%"
set /a _WAITED=0
:acquire_retry
md "!_LOCK_DIR!" 2>nul
if not errorlevel 1 goto :lock_acquired
rem Lock exists. Check age (seconds since last write).
for /f %%a in ('powershell -NoProfile -Command "try { [int]((New-TimeSpan -Start ((Get-Item '!_LOCK_DIR!').LastWriteTime) -End (Get-Date)).TotalSeconds) } catch { -1 }"') do set "_LOCK_AGE=%%a"
if "!_LOCK_AGE!"=="-1" goto :continue_wait
if !_LOCK_AGE! geq 300 (
    rmdir /s /q "!_LOCK_DIR!" 2>nul
    goto :acquire_retry
)
:continue_wait
if !_WAITED! geq 300 (
    echo ERROR: Timed out waiting for install lock. >&2
    exit /b 1
)
set /a _WAITED+=1
timeout /t 1 /nobreak >nul
goto :acquire_retry
:lock_acquired
exit /b 0

:release_install_lock
rmdir /s /q "!_LOCK_DIR!" 2>nul
exit /b 0

:http_head_status
rem %~1 = URL
rem Sets HTTP_STATUS to the final HTTP status code (after redirects), or empty
rem on network failure. Used to classify a failed CLI distribution download as
rem a 403/404 (recoverable when an old jar exists) vs. other errors.
set "HTTP_STATUS="
set "_HHS_URL=%~1"
for /f %%c in ('curl -sLI !CURL_AUTH! -o NUL -w "%%{http_code}" "!_HHS_URL!" 2^>nul') do set "HTTP_STATUS=%%c"
exit /b 0

:classify_metadata_fetch_failure
rem %~1 = URL
rem If %~1 returned HTTP 403/404 AND a CLI jar with a recorded version is
rem already installed, sets MOD_VERSION to the installed version and returns 0.
rem Otherwise returns 1; the caller should emit its existing error and exit 1.
call :http_head_status "%~1"
if "!HTTP_STATUS!"=="403" goto :cmff_try_fallback
if "!HTTP_STATUS!"=="404" goto :cmff_try_fallback
exit /b 1
:cmff_try_fallback
if not exist "%DIST_DIR%\lib\moderne-cli.jar" exit /b 1
if not exist "%DIST_DIR%\version.txt" exit /b 1
set "_INSTALLED="
set /p _INSTALLED=<"%DIST_DIR%\version.txt"
if not defined _INSTALLED exit /b 1
set "MOD_VERSION=!_INSTALLED!"
echo WARN: Could not fetch %~1 ^(HTTP !HTTP_STATUS!^). >&2
echo       Continuing with previously installed version !MOD_VERSION!. >&2
exit /b 0

:classify_cli_download_failure
rem %~1 = URL, %~2 = HTTP status (may be empty on non-HTTP failure)
rem Returns 0 if caller should fall back to the previously installed CLI jar.
rem Returns 1 if caller should treat the failure as fatal.
if "%~2"=="403" goto :classify_recoverable
if "%~2"=="404" goto :classify_recoverable
if "%~2"=="" (
    echo ERROR: Failed to download Moderne CLI from %~1. >&2
) else (
    echo ERROR: Failed to download Moderne CLI from %~1 ^(HTTP %~2^). >&2
)
exit /b 1
:classify_recoverable
if exist "%DIST_DIR%\lib\moderne-cli.jar" (
    echo WARN: Failed to download Moderne CLI from %~1 ^(HTTP %~2^). >&2
    echo       Continuing with previously installed CLI jar at %DIST_DIR%\lib\moderne-cli.jar. >&2
    exit /b 0
)
echo ERROR: Failed to download Moderne CLI from %~1 ^(HTTP %~2^). >&2
echo        No previously installed CLI jar found. >&2
exit /b 1

:ensure_distribution
rem Skip if MODERNE_JAR is set (dev/override)
if defined MODERNE_JAR exit /b 0

rem Skip if local Gradle build output exists (dev workflow)
set "SCRIPT_DIR=%~dp0"
set "BUILD_LIBS=!SCRIPT_DIR!mod\build\libs"
if exist "!BUILD_LIBS!" (
    dir /b "!BUILD_LIBS!\mod-*-fat.jar" >nul 2>&1
    if not errorlevel 1 exit /b 0
)

rem Read version from properties
set "MOD_VERSION="
if defined PROPS_FILE (
    for /f "tokens=1,* delims==" %%a in ('findstr /b "version=" "%PROPS_FILE%" 2^>nul') do set "MOD_VERSION=%%b"
)
rem Environment variable overrides properties
if defined MODERNE_WRAPPER_VERSION set "MOD_VERSION=%MODERNE_WRAPPER_VERSION%"
if not defined MOD_VERSION set "MOD_VERSION=RELEASE"

rem Read custom distribution URL if set
set "CUSTOM_URL="
if defined PROPS_FILE (
    for /f "tokens=1,* delims==" %%a in ('findstr /b "distributionUrl=" "%PROPS_FILE%" 2^>nul') do set "CUSTOM_URL=%%b"
)
rem Environment variable overrides properties
if defined MODERNE_WRAPPER_DISTRIBUTION_URL set "CUSTOM_URL=%MODERNE_WRAPPER_DISTRIBUTION_URL%"

rem Read custom early access URL if set
set "EARLY_ACCESS_URL="
if defined PROPS_FILE (
    for /f "tokens=1,* delims==" %%a in ('findstr /b "distributionUrlEarlyAccess=" "%PROPS_FILE%" 2^>nul') do set "EARLY_ACCESS_URL=%%b"
)
if defined EARLY_ACCESS_URL (set "EARLY_ACCESS_REPO=!EARLY_ACCESS_URL!") else (set "EARLY_ACCESS_REPO=%SONATYPE_SNAPSHOTS%")
set "DOWNLOAD_REPO=%MAVEN_CENTRAL%"
set "DIST_ARTIFACT=moderne-cli-windows"

rem Resolve special version tokens
set "SNAPSHOT_VERSION="
set "VERSION_TOKEN=!MOD_VERSION!"
if "!MOD_VERSION!"=="LATEST" (
    call :resolve_latest
    if errorlevel 1 exit /b 1
) else if "!MOD_VERSION:~-9!"=="-SNAPSHOT" (
    call :resolve_snapshot
    if errorlevel 1 exit /b 1
) else if "!MOD_VERSION!"=="RELEASE" (
    call :resolve_release
    if errorlevel 1 exit /b 1
)

rem Fast-path: already installed (no lock needed for a read-only check)
set "VERSION_FILE=%DIST_DIR%\version.txt"
if exist "%VERSION_FILE%" (
    if exist "%DIST_DIR%\lib\moderne-cli.jar" (
        set /p INSTALLED_VERSION=<"%VERSION_FILE%"
        if "!INSTALLED_VERSION!"=="!MOD_VERSION!" exit /b 0
        rem For RELEASE, don't downgrade if the installed version is already newer
        rem (Maven Central CDN may serve stale metadata)
        if "!VERSION_TOKEN!"=="RELEASE" (
            for /f %%r in ('powershell -NoProfile -Command "if ([version]'!INSTALLED_VERSION!' -ge [version]'!MOD_VERSION!') {'yes'} else {'no'}"') do (
                if "%%r"=="yes" (
                    set "MOD_VERSION=!INSTALLED_VERSION!"
                    exit /b 0
                )
            )
        )
    )
)

rem Serialize installation across concurrent wrapper invocations
call :acquire_install_lock
if errorlevel 1 exit /b 1

rem Re-check inside the lock: another process may have installed while we waited
if exist "%VERSION_FILE%" (
    if exist "%DIST_DIR%\lib\moderne-cli.jar" (
        set /p INSTALLED_VERSION=<"%VERSION_FILE%"
        if "!INSTALLED_VERSION!"=="!MOD_VERSION!" (
            call :release_install_lock
            exit /b 0
        )
        if "!VERSION_TOKEN!"=="RELEASE" (
            for /f %%r in ('powershell -NoProfile -Command "if ([version]'!INSTALLED_VERSION!' -ge [version]'!MOD_VERSION!') {'yes'} else {'no'}"') do (
                if "%%r"=="yes" (
                    set "MOD_VERSION=!INSTALLED_VERSION!"
                    call :release_install_lock
                    exit /b 0
                )
            )
        )
    )
)

rem Construct download URL
if defined CUSTOM_URL (
    set "DOWNLOAD_URL=!CUSTOM_URL!"
    call set "DOWNLOAD_URL=%%DOWNLOAD_URL:${version}=!MOD_VERSION!%%"
    call set "DOWNLOAD_URL=%%DOWNLOAD_URL:${platform}=windows%%"
) else if defined SNAPSHOT_VERSION (
    set "DOWNLOAD_URL=!DOWNLOAD_REPO!/io/moderne/!DIST_ARTIFACT!/!SNAPSHOT_VERSION!/!DIST_ARTIFACT!-!MOD_VERSION!.zip"
) else (
    set "DOWNLOAD_URL=!DOWNLOAD_REPO!/io/moderne/!DIST_ARTIFACT!/!MOD_VERSION!/!DIST_ARTIFACT!-!MOD_VERSION!.zip"
)

echo Downloading Moderne CLI !MOD_VERSION! for Windows... >&2

rem Clean stale download dirs from crashed runs (we hold the lock, so any
rem existing download-* is truly orphaned).
for /d %%d in ("%MODERNE_CLI_HOME%\download-*") do rmdir /s /q "%%d" 2>nul

rem Unique per-invocation dir (belt-and-suspenders with the lock).
set "DOWNLOAD_TMP=%MODERNE_CLI_HOME%\download-!RANDOM!!RANDOM!"
mkdir "!DOWNLOAD_TMP!"
set "ARCHIVE=!DOWNLOAD_TMP!\moderne-cli.zip"

curl -fSL --progress-bar !CURL_AUTH! -o "!ARCHIVE!" "!DOWNLOAD_URL!"
if errorlevel 1 (
    rmdir /s /q "!DOWNLOAD_TMP!" 2>nul
    call :http_head_status "!DOWNLOAD_URL!"
    call :classify_cli_download_failure "!DOWNLOAD_URL!" "!HTTP_STATUS!"
    if errorlevel 1 (
        call :release_install_lock
        exit /b 1
    )
    rem Reset MOD_VERSION to the actually-installed version so the AOT-stamp
    rem section in the main flow doesn't rewrite version.txt with the failed
    rem target version.
    if exist "%VERSION_FILE%" set /p MOD_VERSION=<"%VERSION_FILE%"
    call :release_install_lock
    exit /b 0
)

rem Verify checksum if specified
if defined PROPS_FILE (
    set "EXPECTED_SHA="
    for /f "tokens=1,* delims==" %%a in ('findstr /b "distributionSha256Sum=" "%PROPS_FILE%" 2^>nul') do set "EXPECTED_SHA=%%b"
    if defined EXPECTED_SHA (
        for /f "delims=" %%h in ('powershell -NoProfile -Command "(Get-FileHash '!ARCHIVE!' -Algorithm SHA256).Hash.ToLower()"') do set "ACTUAL_SHA=%%h"
        if defined ACTUAL_SHA (
            if /i "!ACTUAL_SHA!" neq "!EXPECTED_SHA!" (
                echo ERROR: SHA-256 checksum mismatch for downloaded distribution. >&2
                echo   Expected: !EXPECTED_SHA! >&2
                echo   Actual:   !ACTUAL_SHA! >&2
                rmdir /s /q "!DOWNLOAD_TMP!" 2>nul
                call :release_install_lock
                exit /b 1
            )
        )
    )
)

rem Extract zip and install distribution assets directly (avoids install.cmd download cycle)
set "EXTRACT_TMP=!DOWNLOAD_TMP!\extracted"
powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; Expand-Archive -Path '!ARCHIVE!' -DestinationPath '!EXTRACT_TMP!' -Force"

rem Remove old dated snapshot jars (e.g. moderne-cli-4.0.0-20260227.123456-42.jar)
for %%f in ("%DIST_DIR%\lib\moderne-cli-*-*.*-*.jar") do del "%%f" 2>nul

rem Copy wrapper script (self-update)
if exist "!EXTRACT_TMP!\modw.cmd" copy /y "!EXTRACT_TMP!\modw.cmd" "%MODERNE_CLI_HOME%\bin\" >nul

rem Copy CLI jar
if not exist "%DIST_DIR%\lib" mkdir "%DIST_DIR%\lib"
if exist "!EXTRACT_TMP!\lib\moderne-cli.jar" copy /y "!EXTRACT_TMP!\lib\moderne-cli.jar" "%DIST_DIR%\lib\" >nul

rem Replace JRE
if exist "!EXTRACT_TMP!\jre" (
    xcopy /s /e /y /q "!EXTRACT_TMP!\jre" "%DIST_DIR%\jre\" >nul
)

rmdir /s /q "!DOWNLOAD_TMP!"

rem Stamp the installed version
>"%DIST_DIR%\version.txt" echo !MOD_VERSION!
echo Moderne CLI !MOD_VERSION! installed to %DIST_DIR% >&2

call :release_install_lock
exit /b 0

:resolve_latest
rem Resolves MOD_VERSION from "LATEST" to the newest version in the early access repo.
rem The early access repo may contain Maven snapshots or regular releases.
call :resolve_version_from_maven "!EARLY_ACCESS_REPO!" snapshot
if errorlevel 1 exit /b 1
set "DOWNLOAD_REPO=!EARLY_ACCESS_REPO!"
if "!MOD_VERSION:~-9!"=="-SNAPSHOT" (
    set "SNAPSHOT_VERSION=!MOD_VERSION!"
    if not defined CUSTOM_URL (
        call :resolve_snapshot_artifact_version "!EARLY_ACCESS_REPO!" "!SNAPSHOT_VERSION!"
        if errorlevel 1 exit /b 1
    )
)
exit /b 0

:resolve_snapshot
rem Resolves an explicit SNAPSHOT version (e.g. 3.58.0-SNAPSHOT) to its timestamped artifact.
rem Sets SNAPSHOT_VERSION to the base snapshot version.
set "SNAPSHOT_VERSION=!MOD_VERSION!"
set "DOWNLOAD_REPO=!EARLY_ACCESS_REPO!"
if not defined CUSTOM_URL (
    call :resolve_snapshot_artifact_version "!EARLY_ACCESS_REPO!" "!SNAPSHOT_VERSION!"
    if errorlevel 1 exit /b 1
)
exit /b 0

:resolve_release
rem Resolves MOD_VERSION from "RELEASE" to a concrete release version.
call :resolve_version_from_maven "!DOWNLOAD_REPO!" release
if errorlevel 1 exit /b 1
exit /b 0

:resolve_version_from_maven
rem %~1 = repository base URL, %~2 = "release" or "snapshot"
set "METADATA_URL=%~1/io/moderne/moderne-cli/maven-metadata.xml"
if "%~2"=="snapshot" (
    for /f "delims=" %%v in ('curl -fsSL !CURL_AUTH! "!METADATA_URL!" 2^>nul ^| powershell -NoProfile -Command "[xml]$m=[Console]::In.ReadToEnd(); if($m.metadata.versioning.latest){$m.metadata.versioning.latest}else{($m.metadata.versioning.versions.version|Where-Object{$_ -match 'SNAPSHOT'})[-1]}"') do set "MOD_VERSION=%%v"
) else (
    for /f "delims=" %%v in ('curl -fsSL !CURL_AUTH! "!METADATA_URL!" 2^>nul ^| powershell -NoProfile -Command "[xml]$m=[Console]::In.ReadToEnd(); $m.metadata.versioning.release"') do set "MOD_VERSION=%%v"
)
if not defined MOD_VERSION (
    call :classify_metadata_fetch_failure "!METADATA_URL!"
    if not errorlevel 1 exit /b 0
    echo ERROR: Could not determine Moderne CLI version from !METADATA_URL!. >&2
    exit /b 1
)
exit /b 0

:resolve_snapshot_artifact_version
rem %~1 = repository base URL, %~2 = SNAPSHOT version
set "METADATA_URL=%~1/io/moderne/%DIST_ARTIFACT%/%~2/maven-metadata.xml"
for /f "delims=" %%v in ('curl -fsSL !CURL_AUTH! "!METADATA_URL!" 2^>nul ^| powershell -NoProfile -Command "[xml]$m=[Console]::In.ReadToEnd(); $s=$m.metadata.versioning.snapshot; $base='%~2' -replace '-SNAPSHOT$',''; '{0}-{1}-{2}' -f $base,$s.timestamp,$s.buildNumber"') do set "MOD_VERSION=%%v"
if not defined MOD_VERSION (
    call :classify_metadata_fetch_failure "!METADATA_URL!"
    if not errorlevel 1 exit /b 0
    echo ERROR: Could not resolve snapshot artifact version from !METADATA_URL!. >&2
    exit /b 1
)
exit /b 0

:find_java
rem 1. MODERNE_JAVA_HOME
if defined MODERNE_JAVA_HOME (
    if exist "%MODERNE_JAVA_HOME%\bin\java.exe" (
        set "JAVA_CMD=%MODERNE_JAVA_HOME%\bin\java.exe"
        exit /b 0
    )
    echo ERROR: MODERNE_JAVA_HOME is set to '%MODERNE_JAVA_HOME%' but no java.exe found there. >&2
    exit /b 1
)

rem 2. JAVA_HOME
if defined JAVA_HOME (
    if exist "%JAVA_HOME%\bin\java.exe" (
        call :detect_java_version "%JAVA_HOME%\bin\java.exe"
        if !JAVA_MAJOR! geq %MIN_JAVA_VERSION% if !IS_GRAALVM! equ 0 (
            set "JAVA_CMD=%JAVA_HOME%\bin\java.exe"
            exit /b 0
        )
    )
)

rem 3. java on PATH
where java >nul 2>&1
if not errorlevel 1 (
    call :detect_java_version java
    if !JAVA_MAJOR! geq %MIN_JAVA_VERSION% if !IS_GRAALVM! equ 0 (
        set "JAVA_CMD=java"
        exit /b 0
    )
)

rem 4. Bundled JRE (from platform distribution — known-good, no scanning needed)
if exist "%DIST_DIR%\jre\bin\java.exe" (
    set "JAVA_CMD=%DIST_DIR%\jre\bin\java.exe"
    exit /b 0
)

rem 5. Well-known JDK locations
call :scan_jdk_dir "%USERPROFILE%\.jdks"
if not errorlevel 1 exit /b 0
call :scan_jdk_dir "%USERPROFILE%\.gradle\jdks"
if not errorlevel 1 exit /b 0
call :scan_jdk_dir "C:\Program Files\Java"
if not errorlevel 1 exit /b 0
call :scan_jdk_dir "C:\Program Files\Eclipse Adoptium"
if not errorlevel 1 exit /b 0
call :scan_jdk_dir "C:\Program Files\Zulu"
if not errorlevel 1 exit /b 0
call :scan_jdk_dir "C:\Program Files\Amazon Corretto"
if not errorlevel 1 exit /b 0
call :scan_jdk_dir "C:\Program Files\BellSoft"
if not errorlevel 1 exit /b 0
call :scan_jdk_dir "C:\Program Files\Microsoft"
if not errorlevel 1 exit /b 0

rem 6. Auto-download from Adoptium (or custom jdkUrl)
call :download_jdk
if not errorlevel 1 exit /b 0

echo ERROR: No Java %MIN_JAVA_VERSION%+ found. >&2
echo Set JAVA_HOME or MODERNE_JAVA_HOME, or install Java %MIN_JAVA_VERSION%+. >&2
exit /b 1

:scan_jdk_dir
if not exist "%~1" exit /b 1
for /d %%d in ("%~1\*") do (
    if exist "%%d\bin\java.exe" (
        call :detect_java_version "%%d\bin\java.exe"
        if !JAVA_MAJOR! geq %MIN_JAVA_VERSION% if !IS_GRAALVM! equ 0 (
            set "JAVA_CMD=%%d\bin\java.exe"
            goto :scan_jdk_found
        )
    )
)
exit /b 1

:scan_jdk_found
exit /b 0

:download_jdk
set "JDK_DIR=%MODERNE_CLI_HOME%\dist\jdk\%MIN_JAVA_VERSION%"
if exist "%JDK_DIR%\bin\java.exe" (
    set "JAVA_CMD=%JDK_DIR%\bin\java.exe"
    exit /b 0
)

set "JDK_URL=https://api.adoptium.net/v3/binary/latest/%MIN_JAVA_VERSION%/ga/windows/x64/jdk/hotspot/normal/eclipse"
if defined PROPS_FILE (
    for /f "tokens=1,* delims==" %%a in ('findstr /b "jdkUrl=" "%PROPS_FILE%" 2^>nul') do set "JDK_URL=%%b"
)
if "!JDK_URL!"=="skip" (
    exit /b 1
)

rem Serialize JDK install across concurrent wrapper invocations
call :acquire_install_lock
if errorlevel 1 exit /b 1

rem Re-check inside the lock: another process may have installed the JDK while we waited
if exist "%JDK_DIR%\bin\java.exe" (
    set "JAVA_CMD=%JDK_DIR%\bin\java.exe"
    call :release_install_lock
    exit /b 0
)

echo Downloading JDK %MIN_JAVA_VERSION%... >&2
if not exist "%MODERNE_CLI_HOME%\dist\jdk" mkdir "%MODERNE_CLI_HOME%\dist\jdk"

rem Clean stale JDK download/extract dirs from crashed runs
for /d %%d in ("%MODERNE_CLI_HOME%\dist\jdk\download-*") do rmdir /s /q "%%d" 2>nul
for /d %%d in ("%MODERNE_CLI_HOME%\dist\jdk\extract-*") do rmdir /s /q "%%d" 2>nul

rem Unique per-invocation dir (belt-and-suspenders with the lock)
set "JDK_TMP=%MODERNE_CLI_HOME%\dist\jdk\download-!RANDOM!!RANDOM!"
mkdir "!JDK_TMP!"
set "ARCHIVE=!JDK_TMP!\jdk-download.zip"

curl -fSL --progress-bar !CURL_AUTH! -o "!ARCHIVE!" "!JDK_URL!"
if errorlevel 1 (
    echo ERROR: Failed to download JDK. >&2
    rmdir /s /q "!JDK_TMP!" 2>nul
    call :release_install_lock
    exit /b 1
)

set "EXTRACT_DIR=!JDK_TMP!\extracted"
powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; Expand-Archive -Path '!ARCHIVE!' -DestinationPath '!EXTRACT_DIR!' -Force"

rem Find the extracted JDK directory
for /d %%d in ("!EXTRACT_DIR!\*") do set "EXTRACTED=%%d"
if exist "%JDK_DIR%" rmdir /s /q "%JDK_DIR%"
move "!EXTRACTED!" "%JDK_DIR%" >nul

rmdir /s /q "!JDK_TMP!" 2>nul

set "JAVA_CMD=%JDK_DIR%\bin\java.exe"
echo JDK %MIN_JAVA_VERSION% installed to %JDK_DIR% >&2
call :release_install_lock
exit /b 0

:find_jar
rem 1. MODERNE_JAR
if defined MODERNE_JAR (
    if exist "%MODERNE_JAR%" (
        set "MOD_JAR=%MODERNE_JAR%"
        exit /b 0
    )
    echo ERROR: MODERNE_JAR is set to '%MODERNE_JAR%' but the file does not exist. >&2
    exit /b 1
)

rem 2. Local Gradle build output (development)
set "SCRIPT_DIR=%~dp0"
set "BUILD_LIBS=!SCRIPT_DIR!mod\build\libs"
if exist "!BUILD_LIBS!" (
    for /f "delims=" %%f in ('dir /b /o-d "!BUILD_LIBS!\mod-*-fat.jar" 2^>nul') do (
        set "MOD_JAR=!BUILD_LIBS!\%%f"
        goto :find_jar_found
    )
)

rem 3. Maven Local (~/.m2) — prefer over distribution if newer
set "M2_BASE=%USERPROFILE%\.m2\repository\io\moderne\moderne-cli"
set "M2_META=!M2_BASE!\maven-metadata-local.xml"
if exist "!M2_META!" (
    for /f "delims=" %%v in ('powershell -NoProfile -Command "[xml]$m = Get-Content '!M2_META!'; $m.metadata.versioning.latest"') do set "M2_VERSION=%%v"
    if defined M2_VERSION (
        set "M2_JAR=!M2_BASE!\!M2_VERSION!\moderne-cli-!M2_VERSION!.jar"
        if exist "!M2_JAR!" (
            set "DIST_JAR=%DIST_DIR%\lib\moderne-cli.jar"
            set "_USE_M2=0"
            if not exist "!DIST_JAR!" set "_USE_M2=1"
            if "!_USE_M2!"=="0" (
                for /f "delims=" %%r in ('powershell -NoProfile -Command "if ((Get-Item '!M2_JAR!').LastWriteTime -gt (Get-Item '!DIST_JAR!').LastWriteTime) { 'yes' } else { 'no' }"') do (
                    if "%%r"=="yes" set "_USE_M2=1"
                )
            )
            if "!_USE_M2!"=="1" (
                set "MOD_JAR=!M2_JAR!"
                set "MOD_SOURCE=maven-local"
                exit /b 0
            )
        )
    )
)

rem 4. Installed distribution
if exist "%DIST_DIR%\lib\moderne-cli.jar" (
    set "MOD_JAR=%DIST_DIR%\lib\moderne-cli.jar"
    exit /b 0
)

echo ERROR: Cannot find Moderne CLI JAR. >&2
echo Set MODERNE_JAR or run modw to download the distribution. >&2
exit /b 1

:find_jar_found
exit /b 0

:detect_java_version
rem Writes java -version output to a temp file to avoid stderr leaking to the console.
set "JAVA_MAJOR=0"
set "IS_GRAALVM=0"
set "_JVER_TMP=%TEMP%\_mod_jver.tmp"
"%~1" -version 2>"!_JVER_TMP!" 1>&2
for /f "tokens=3" %%v in ('findstr /i "version" "!_JVER_TMP!"') do set "JAVA_VER=%%~v"
findstr /i "GraalVM" "!_JVER_TMP!" >nul 2>&1
if not errorlevel 1 set "IS_GRAALVM=1"
del "!_JVER_TMP!" 2>nul
for /f "delims=." %%m in ("!JAVA_VER!") do set "JAVA_MAJOR=%%m"
exit /b 0

:eof_error
exit /b 1

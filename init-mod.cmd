@echo off
rem
rem Initializes the Moderne CLI wrapper.
rem Sets up the "mod" command to delegate to the project-local modw wrapper,
rem then runs configure-mod.cmd to configure the CLI environment.
rem
setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "!SCRIPT_DIR:~-1!"=="\" set "SCRIPT_DIR=!SCRIPT_DIR:~0,-1!"

if not defined MODERNE_CLI_HOME set "MODERNE_CLI_HOME=%USERPROFILE%\.moderne\cli"
set "BIN_DIR=!MODERNE_CLI_HOME!\bin"
if not exist "!BIN_DIR!" mkdir "!BIN_DIR!"

rem Create a mod.cmd delegate that forwards to the project-local modw.cmd
> "!BIN_DIR!\mod.cmd" (
    echo @echo off
    echo "!SCRIPT_DIR!\modw.cmd" %%*
)
echo Created delegate: !BIN_DIR!\mod.cmd -^> !SCRIPT_DIR!\modw.cmd

rem Ensure the bin directory is on PATH
echo !PATH! | findstr /I /C:"!BIN_DIR!" >nul 2>&1
if errorlevel 1 (
    set "PATH=!BIN_DIR!;!PATH!"
    echo Added !BIN_DIR! to PATH for this session.
    echo To make this permanent, add !BIN_DIR! to your system PATH.
)

rem Configure the CLI environment
call "!SCRIPT_DIR!\configure-mod.cmd" init

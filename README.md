# Moderne CLI Wrapper Example

This repository demonstrates how to set up the [Moderne CLI wrapper](https://docs.moderne.io/user-documentation/moderne-cli/how-to-guides/cli-wrapper/) for a company. The wrapper bootstraps the Moderne CLI by downloading it from Maven Central, caching it locally, and making the `mod` command available on the PATH -- similar to how the Gradle wrapper works for Gradle.

Developers and CI pipelines can run `modw` (or `modw.cmd` on Windows) without needing to install the Moderne CLI manually. The configuration scripts then set up the CLI environment with company-specific settings (Moderne tenant, Artifactory, etc.).

## Quick Start

### Linux / macOS

```bash
# Install the CLI
./modw

# Add mod to PATH for the current session
export PATH="$HOME/.moderne/cli/bin:$PATH"

# Configure the CLI environment
./configure-mod.sh init
```

### Windows

```cmd
rem Install the CLI
call modw.cmd

rem Add mod to PATH for the current session
set PATH=%USERPROFILE%\.moderne\cli\bin;%PATH%

rem Configure the CLI environment
call configure-mod.cmd init
```

## Repository Structure

### Wrapper Scripts

| File | Description |
|------|-------------|
| `modw` | Bootstrap wrapper for Linux and macOS. Downloads the CLI distribution (a self-extracting `.sh` archive) from Maven Central, verifies its SHA-256 checksum, caches it at `~/.moderne/cli/dist/`, and executes it. Detects the platform automatically (`linux` or `osx`). |
| `modw.cmd` | Bootstrap wrapper for Windows. Downloads the CLI distribution (a `.zip` archive) from Maven Central, verifies its SHA-256 checksum, extracts it with PowerShell, runs the bundled `install.cmd` to set up the CLI, and creates a `mod.cmd` shim so that the `mod` command is available on the PATH. |

### Configuration Scripts

| File | Description |
|------|-------------|
| `configure-mod.sh` | Configuration script for Linux and macOS. Run with `init` to configure the CLI environment. Expects `mod` to already be on the PATH (installed via `modw`). Can also be used to run arbitrary `mod` commands by passing them as arguments. |
| `configure-mod.cmd` | Configuration script for Windows. Same functionality as `configure-mod.sh` but in Windows batch syntax. Must be invoked with `call` from other batch files. |

The `init` subcommand runs the following configuration steps:

1. Set the Moderne tenant URL (`mod config moderne edit`)
2. Configure recipe artifacts from Artifactory (`mod config recipes artifacts artifactory edit`)
3. Disallow Maven Central for artifact resolution (`mod config features no-maven-central`)

The commands above are examples. Modify them based on your company's needs -- add, remove, or change commands as required. Edit the `MODERNE_TENANT` and `ARTIFACTORY_MAVEN_URL` variables at the top of each script to match your environment.


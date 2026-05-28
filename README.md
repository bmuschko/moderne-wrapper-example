# Moderne CLI Wrapper Example

This repository demonstrates how to set up the [Moderne CLI wrapper](https://docs.moderne.io/user-documentation/moderne-cli/how-to-guides/cli-wrapper/) for a company. The wrapper bootstraps the Moderne CLI by downloading it from Maven Central, caching it locally, and making the `mod` command available on the PATH -- similar to how the Gradle wrapper works for Gradle.

Developers and CI pipelines can run `./init-mod` (or `call init-mod.cmd` on Windows) to set up the `mod` command and configure the CLI environment in one step. No manual CLI installation is required.

## Quick Start

Run `init-mod` to create the `mod` command, download the CLI, and configure the environment in one step.

### Linux / macOS

```bash
./init-mod
```

### Windows

```cmd
call init-mod.cmd
```

After running, follow the on-screen instructions to add `mod` to your PATH for the current shell session. To make it permanent, add the printed `export PATH` (or `set PATH`) line to your shell profile.

## Repository Structure

### Wrapper Scripts

The `modw` and `modw.cmd` scripts are copied from [Maven Central](https://repo1.maven.org/maven2/io/moderne/moderne-cli/4.2.9/) (`moderne-cli-4.2.9-modw.sh` and `moderne-cli-4.2.9-modw.cmd`). They should not be modified directly — update them by downloading newer versions from Maven Central when available.

| File | Description |
|------|-------------|
| `modw` | Bootstrap wrapper for Linux and macOS. Downloads the CLI distribution (a self-extracting `.sh` archive) from Maven Central, verifies its SHA-256 checksum, caches it at `~/.moderne/cli/dist/`, and executes it. Detects the platform automatically (`linux` or `osx`). |
| `modw.cmd` | Bootstrap wrapper for Windows. Downloads the CLI distribution (a `.zip` archive) from Maven Central, verifies its SHA-256 checksum, and extracts it with PowerShell. |

### Initialization Scripts

| File | Description |
|------|-------------|
| `init-mod` | Initialization script for Linux and macOS. Creates a `mod` symlink in `~/.moderne/cli/bin/` that delegates to the project-local `modw`, adds the bin directory to PATH, and calls `configure-mod.sh init`. |
| `init-mod.cmd` | Initialization script for Windows. Creates a `mod.cmd` delegate in `%USERPROFILE%\.moderne\cli\bin\` that forwards to the project-local `modw.cmd`, adds the bin directory to PATH, and calls `configure-mod.cmd init`. |

### Configuration Scripts

| File | Description |
|------|-------------|
| `configure-mod.sh` | Configuration script for Linux and macOS. Run with `init` to configure the CLI environment. Expects `mod` to already be on the PATH. Can also be used to run arbitrary `mod` commands by passing them as arguments. |
| `configure-mod.cmd` | Configuration script for Windows. Same functionality as `configure-mod.sh` but in Windows batch syntax. Must be invoked with `call` from other batch files. |

The `init` subcommand runs the following configuration steps:

1. Set the Moderne tenant URL (`mod config moderne edit`)
2. Disallow Maven Central for artifact resolution (`mod config features no-maven-central`)
3. Configure recipe artifacts from Artifactory (`mod config recipes artifacts artifactory edit`)

The commands above are examples. Modify them based on your company's needs -- add, remove, or change commands as required. Edit the `MODERNE_TENANT` and `ARTIFACTORY_MAVEN_URL` variables at the top of each script to match your environment.


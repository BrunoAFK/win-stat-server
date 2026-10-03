# KUM-FPS Bootstrap

Put these two files in the root of `BrunoAFK/win-stat-server`:

- `INSTALL-KUM-FPS.ps1`
- `INSTALL-KUM-FPS.bat`

For the end user, the intended entry point is:

```bat
INSTALL-KUM-FPS.bat
```

The installer checks/reuses what is already present and fills in the missing parts.

## Installed / configured

- HWiNFO64
  - existing installation is reused when found
  - otherwise an isolated portable copy is installed
  - Shared Memory enabled
  - Sensors-only enabled
  - polling set to 1000 ms
- `win-stat-server` v8.0.0 from its immutable release tag
- Tunnelmole Windows binary
- CapFrameX latest stable portable release
- .NET 10 Windows Desktop Runtime when CapFrameX needs it
- Microsoft Visual C++ x64 runtime when needed
- Parsec when missing

## Installed location

```text
%LOCALAPPDATA%\KUM-FPS
```

Desktop launchers are created:

```text
KUM-FPS.bat
KUM-FPS REMOTE.bat
```

`KUM-FPS.bat` starts HWiNFO, CapFrameX and the local dashboard.

`KUM-FPS REMOTE.bat` does the same and then starts Tunnelmole. The Tunnelmole URL is public while the tunnel is running.

## Optional flags

```powershell
.\INSTALL-KUM-FPS.ps1 -SkipParsec
.\INSTALL-KUM-FPS.ps1 -SkipCapFrameX
.\INSTALL-KUM-FPS.ps1 -Port 8081
.\INSTALL-KUM-FPS.ps1 -ForceRefreshTools
```

## Why HWiNFO uses 1000 ms polling for now

The current Performance Lab canonical-sample deduplication uses HWiNFO `PollTimeUnix`, which has second-level granularity. A 500 ms source interval can therefore cause two real updates to share the same token. Until the server deduplication is changed to a sub-second-safe mechanism, the bootstrap intentionally uses 1000 ms.

## Things that cannot be fully automated

- The first Parsec account login still requires the user.
- Tunnelmole remote mode is deliberately not started by the installer because it creates a publicly reachable URL. The user explicitly starts `KUM-FPS REMOTE.bat`.
- HWiNFO Free Shared Memory can deactivate after 12 hours of continuous runtime; restarting HWiNFO re-enables a new session.


## v1.1 — installer window and persistent logs

The installer no longer disappears when setup finishes.

- The elevated PowerShell window remains visible.
- Every installation run writes a timestamped transcript to:

```text
%LOCALAPPDATA%\KUM-FPS\logs\install-YYYYMMDD-HHMMSS.log
```

- The final screen clearly shows either:

```text
KUM-FPS SETUP: SUCCESS
```

or:

```text
KUM-FPS SETUP: FAILED
```

- The window closes only after the user presses Enter.
- For unattended/CI use, `-NoPause` disables the final prompt.


## v1.2 — launcher creation fix

Fixed a PowerShell case-insensitive variable collision between:

```powershell
$RemoteBat
$remoteBat
```

These names refer to the same variable in PowerShell. The remote launcher content now uses:

```powershell
$remoteBatContent
```

This fixes:

```text
Exception calling "WriteAllText": Illegal characters in path.
```


## v1.3 — no automatic win-stat-server startup

The installer now performs setup only. After installation it does **not** automatically start `win-stat-server`, the local dashboard, or Tunnelmole. The generated `KUM-FPS.bat` and `KUM-FPS REMOTE.bat` launchers remain available for manual use later.

## v1.4 — reproducible server install

The bootstrap downloads Win Stat Server from the immutable `v8.0.0` tag instead of the moving `main` branch. The legacy `-NoStart` parameter remains accepted for compatibility, although setup no longer starts the stack regardless of that flag.

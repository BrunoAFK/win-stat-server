#requires -Version 5.1
<#
KUM-FPS one-click bootstrap installer v1.4
=====================================

What it does:
- Self-elevates when administrator rights are needed.
- Creates an isolated KUM-FPS workspace under %LOCALAPPDATA%\KUM-FPS.
- Reuses an existing HWiNFO64 installation when it can locate one.
- Otherwise downloads the latest HWiNFO portable build.
- Configures only the HWiNFO settings KUM-FPS requires:
    SensorsSM=1
    SensorsOnly=1
    ShowWelcomeAndProgress=0
    OpenSystemSummary=0
    OpenSensors=1
    SensorInterval=1000
- Downloads the latest win-stat-server dashboard from GitHub.
- Installs/downloads Tunnelmole without requiring Node.js.
- Installs Parsec silently when missing.
- Installs the .NET 10 Desktop Runtime when required by CapFrameX.
- Installs the Microsoft Visual C++ x64 runtime when required by portable CapFrameX.
- Downloads the latest stable CapFrameX portable release from GitHub.
- Creates START-KUM-FPS.bat and START-KUM-FPS-REMOTE.bat.
- Does NOT start win-stat-server or the local KUM-FPS stack when setup completes.

The remote/public Tunnelmole URL is NOT started automatically by the installer.
Use START-KUM-FPS-REMOTE.bat explicitly when you want a public URL.

Safe to run more than once. Existing components are reused where possible.
#>

[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$SkipParsec,
    [switch]$SkipCapFrameX,
    [switch]$NoStart,
    [switch]$ForceRefreshTools,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AppName = 'KUM-FPS'
$RepoOwner = 'BrunoAFK'
$RepoName = 'win-stat-server'
$RepoBranch = 'v8.0.0'

$Root = Join-Path $env:LOCALAPPDATA 'KUM-FPS'
$ToolsDir = Join-Path $Root 'tools'
$RuntimeDir = Join-Path $Root 'runtime'
$WinStatDir = Join-Path $Root 'win-stat-server'
$HwInfoManagedDir = Join-Path $ToolsDir 'HWiNFO'
$CapFrameXDir = Join-Path $ToolsDir 'CapFrameX'
$DownloadDir = Join-Path $Root 'downloads'
$ConfigPath = Join-Path $Root 'kum-fps-config.json'
$StartPs1 = Join-Path $Root 'START-KUM-FPS.ps1'
$StartBat = Join-Path $Root 'START-KUM-FPS.bat'
$RemoteBat = Join-Path $Root 'START-KUM-FPS-REMOTE.bat'
$DesktopShortcutBat = Join-Path ([Environment]::GetFolderPath('Desktop')) 'KUM-FPS.bat'
$DesktopRemoteBat = Join-Path ([Environment]::GetFolderPath('Desktop')) 'KUM-FPS REMOTE.bat'

$LogDir = Join-Path $Root 'logs'
$InstallLog = $null
$TranscriptStarted = $false

function Start-InstallLog {
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        $script:InstallLog = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -Path $script:InstallLog -Force | Out-Null
        $script:TranscriptStarted = $true
        Write-Host "Install log: $script:InstallLog" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "[WARN] Could not start transcript log: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Stop-InstallLog {
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
        $script:TranscriptStarted = $false
    }
}

function Wait-BeforeExit {
    param(
        [string]$Status = 'DONE',
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host ("  KUM-FPS SETUP: {0}" -f $Status) -ForegroundColor $Color
    Write-Host ('=' * 72) -ForegroundColor DarkGray

    if ($script:InstallLog) {
        Write-Host "Log saved to: $script:InstallLog" -ForegroundColor Gray
    }

    if (-not $NoPause) {
        Write-Host ''
        Write-Host 'This window will stay open so you can review the output.' -ForegroundColor White
        Write-Host 'Press ENTER to close it.' -ForegroundColor White
        try { [void](Read-Host) } catch {
            try { cmd /c pause | Out-Null } catch {}
        }
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host ('  ' + $Message) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Write-OK {
    param([string]$Message)
    Write-Host ('[OK]   ' + $Message) -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host ('[INFO] ' + $Message) -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Message)
    Write-Host ('[WARN] ' + $Message) -ForegroundColor Yellow
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    if (Test-IsAdministrator) { return }

    Write-Host 'Administrator rights are required for Parsec/runtime setup.' -ForegroundColor Yellow
    Write-Host 'Windows will ask for UAC approval once.' -ForegroundColor Yellow

    $argsList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Port', $Port
    )
    if ($SkipParsec) { $argsList += '-SkipParsec' }
    if ($SkipCapFrameX) { $argsList += '-SkipCapFrameX' }
    if ($NoStart) { $argsList += '-NoStart' }
    if ($ForceRefreshTools) { $argsList += '-ForceRefreshTools' }
    if ($NoPause) { $argsList += '-NoPause' }

    # -NoExit is intentional: when UAC launches a second PowerShell window,
    # we keep that elevated window visible so the user can review the result.
    $elevatedArgs = @('-NoExit') + $argsList
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($elevatedArgs -join ' ')
    exit
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [int]$Retries = 3
    )

    Ensure-Directory (Split-Path -Parent $OutFile)

    $lastError = $null
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Write-Info "Downloading: $Url"
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile -Headers @{
                'User-Agent' = 'KUM-FPS-Bootstrap/1.0'
            }
            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) {
                return
            }
            throw "Downloaded file is empty."
        }
        catch {
            $lastError = $_
            if ($i -lt $Retries) {
                Write-Warn "Download attempt $i failed. Retrying..."
                Start-Sleep -Seconds (2 * $i)
            }
        }
    }
    throw $lastError
}

function Invoke-JsonRequest {
    param([Parameter(Mandatory=$true)][string]$Url)

    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers @{
        'User-Agent' = 'KUM-FPS-Bootstrap/1.0'
        'Accept' = 'application/vnd.github+json'
    }
    return ($response.Content | ConvertFrom-Json)
}

function Expand-ZipClean {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    if (Test-Path $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    Ensure-Directory $Destination
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function Find-ExecutableRecursive {
    param(
        [string]$RootPath,
        [string]$FileName
    )
    if (-not (Test-Path $RootPath)) { return $null }
    $item = Get-ChildItem -LiteralPath $RootPath -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($item) { return $item.FullName }
    return $null
}

function Get-UninstallEntries {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in $paths) {
        Get-ItemProperty $p -ErrorAction SilentlyContinue
    }
}

function Find-HWiNFO {
    $proc = Get-Process -Name 'HWiNFO64' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        try {
            if ($proc.Path -and (Test-Path $proc.Path)) { return $proc.Path }
        } catch {}
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'HWiNFO64\HWiNFO64.exe'),
        (Join-Path $env:ProgramFiles 'HWiNFO\HWiNFO64.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'HWiNFO64\HWiNFO64.exe'),
        (Join-Path $HwInfoManagedDir 'HWiNFO64.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -gt 0) { return $candidates[0] }

    $entry = Get-UninstallEntries |
        Where-Object { $_.DisplayName -like 'HWiNFO*' } |
        Select-Object -First 1

    if ($entry) {
        if ($entry.InstallLocation) {
            $exe = Join-Path $entry.InstallLocation 'HWiNFO64.exe'
            if (Test-Path $exe) { return $exe }
        }
        if ($entry.DisplayIcon) {
            $iconPath = ($entry.DisplayIcon -replace ',\d+$','').Trim('"')
            if (Test-Path $iconPath) { return $iconPath }
        }
    }

    return $null
}

function Set-IniSetting {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Section,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Value
    )

    $lines = @()
    if (Test-Path $Path) {
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    }

    $sectionHeader = "[$Section]"
    $sectionStart = -1
    $sectionEnd = $lines.Count

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ieq $sectionHeader) {
            $sectionStart = $i
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j].Trim() -match '^\[.+\]$') {
                    $sectionEnd = $j
                    break
                }
            }
            break
        }
    }

    if ($sectionStart -lt 0) {
        if ($lines.Count -gt 0 -and $lines[-1] -ne '') { $lines += '' }
        $lines += $sectionHeader
        $lines += "$Key=$Value"
    }
    else {
        $keyIndex = -1
        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
                $keyIndex = $i
                break
            }
        }

        if ($keyIndex -ge 0) {
            $lines[$keyIndex] = "$Key=$Value"
        }
        else {
            $before = @()
            $after = @()
            if ($sectionEnd -gt 0) { $before = @($lines[0..($sectionEnd - 1)]) }
            if ($sectionEnd -lt $lines.Count) { $after = @($lines[$sectionEnd..($lines.Count - 1)]) }
            $lines = @($before + "$Key=$Value" + $after)
        }
    }

    [IO.File]::WriteAllLines($Path, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
}

function Configure-HWiNFO {
    param([Parameter(Mandatory=$true)][string]$ExePath)

    $dir = Split-Path -Parent $ExePath
    $ini = Join-Path $dir 'HWiNFO64.INI'

    if (Test-Path $ini) {
        $backup = "$ini.kum-fps-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $ini -Destination $backup -Force
        Write-Info "Backed up existing HWiNFO INI to: $backup"
    }

    # KUM-FPS currently uses PollTimeUnix as the canonical source-update token.
    # 1000 ms avoids losing every second HWiNFO update until sub-second source
    # deduplication is implemented in win-stat-server.
    $settings = [ordered]@{
        'SensorsSM' = '1'
        'SensorsOnly' = '1'
        'ShowWelcomeAndProgress' = '0'
        'OpenSystemSummary' = '0'
        'OpenSensors' = '1'
        'SensorInterval' = '1000'
        'MinimalizeMainWnd' = '1'
        'MinimalizeSensors' = '1'
    }

    foreach ($kv in $settings.GetEnumerator()) {
        Set-IniSetting -Path $ini -Section 'Settings' -Key $kv.Key -Value $kv.Value
    }

    Write-OK "HWiNFO configured for Sensors-only + Shared Memory + 1000 ms polling."
    return $ini
}

function Install-HWiNFO {
    Write-Step 'HWiNFO'

    $existing = Find-HWiNFO
    if ($existing -and -not $ForceRefreshTools) {
        Write-OK "Existing HWiNFO64 found: $existing"
        $ini = Configure-HWiNFO -ExePath $existing
        return @{ Exe = $existing; Ini = $ini; Managed = $false }
    }

    Write-Info 'No reusable HWiNFO64 found. Installing isolated portable copy.'

    # Discover current stable version from the official HWiNFO version-history page.
    $version = $null
    try {
        $html = (Invoke-WebRequest -UseBasicParsing -Uri 'https://www.hwinfo.com/version-history/' -Headers @{
            'User-Agent' = 'Mozilla/5.0 KUM-FPS-Bootstrap'
        }).Content
        $m = [regex]::Match($html, 'Latest\s+v(\d+\.\d+)', 'IgnoreCase')
        if ($m.Success) { $version = $m.Groups[1].Value }
    } catch {}

    if (-not $version) {
        # Known-good fallback as of 2026-10-03.
        $version = '8.54'
        Write-Warn "Could not discover HWiNFO version automatically; falling back to $version."
    }

    $digits = $version.Replace('.', '')
    $zip = Join-Path $DownloadDir "hwi_$digits.zip"
    $official = "https://www.hwinfo.com/files/hwi_$digits.zip"
    $sourceForge = 'https://sourceforge.net/projects/hwinfo/files/Windows_Portable/latest/download'

    $downloaded = $false
    try {
        Invoke-Download -Url $official -OutFile $zip
        $downloaded = $true
    } catch {
        Write-Warn 'Official direct HWiNFO download failed; trying SourceForge latest portable.'
    }

    if (-not $downloaded) {
        Invoke-Download -Url $sourceForge -OutFile $zip
    }

    Expand-ZipClean -ZipPath $zip -Destination $HwInfoManagedDir
    $exe = Find-ExecutableRecursive -RootPath $HwInfoManagedDir -FileName 'HWiNFO64.exe'
    if (-not $exe) { throw 'HWiNFO64.exe was not found after extracting the portable package.' }

    $ini = Configure-HWiNFO -ExePath $exe
    Write-OK "HWiNFO portable ready: $exe"
    return @{ Exe = $exe; Ini = $ini; Managed = $true }
}

function Install-WinStatServer {
    Write-Step 'win-stat-server'

    Ensure-Directory $WinStatDir

    $files = @(
        'hwinfo-performance-lab.ps1',
        'START-PERFORMANCE-LAB.bat',
        'README.md',
        'CHANGELOG.md'
    )

    foreach ($name in $files) {
        $url = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoBranch/$name"
        $out = Join-Path $WinStatDir $name
        Invoke-Download -Url $url -OutFile $out
    }

    $server = Join-Path $WinStatDir 'hwinfo-performance-lab.ps1'
    if (-not (Test-Path $server)) { throw 'win-stat-server download failed.' }

    Write-OK "win-stat-server ready: $server"
    return $server
}

function Install-Tunnelmole {
    Write-Step 'Tunnelmole'

    $tmole = Join-Path $ToolsDir 'tmole.exe'
    if ((Test-Path $tmole) -and -not $ForceRefreshTools) {
        Write-OK "Tunnelmole already present: $tmole"
        return $tmole
    }

    Invoke-Download -Url 'https://tunnelmole.com/downloads/tmole.exe' -OutFile $tmole
    if (-not (Test-Path $tmole)) { throw 'Tunnelmole download failed.' }

    Write-OK "Tunnelmole ready: $tmole"
    return $tmole
}

function Test-DotNet10Desktop {
    try {
        $lines = & dotnet --list-runtimes 2>$null
        if ($LASTEXITCODE -eq 0 -and ($lines -match '^Microsoft\.WindowsDesktop\.App 10\.')) {
            return $true
        }
    } catch {}

    $reg = 'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App'
    if (Test-Path $reg) {
        $props = Get-ItemProperty $reg -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -match '^10\.') { return $true }
            }
        }
    }

    return $false
}

function Install-DotNet10Desktop {
    if (Test-DotNet10Desktop) {
        Write-OK '.NET 10 Windows Desktop Runtime already installed.'
        return
    }

    Write-Info '.NET 10 Windows Desktop Runtime is missing.'

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Info 'Installing .NET 10 Desktop Runtime through winget...'
        try {
            $p = Start-Process -FilePath $winget.Source -ArgumentList @(
                'install',
                '--id', 'Microsoft.DotNet.DesktopRuntime.10',
                '--exact',
                '--silent',
                '--accept-package-agreements',
                '--accept-source-agreements',
                '--disable-interactivity'
            ) -PassThru -Wait
            if ($p.ExitCode -eq 0 -and (Test-DotNet10Desktop)) {
                Write-OK '.NET 10 Desktop Runtime installed.'
                return
            }
        } catch {
            Write-Warn 'winget .NET install failed; using Microsoft dotnet-install fallback.'
        }
    }

    # Fallback: user-local .NET installation. Persist DOTNET_ROOT and PATH so
    # CapFrameX can resolve the runtime on later launches too.
    $dotnetInstall = Join-Path $DownloadDir 'dotnet-install.ps1'
    Invoke-Download -Url 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetInstall

    $dotnetDir = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
    Ensure-Directory $dotnetDir

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dotnetInstall `
        -Runtime windowsdesktop -Channel '10.0' -Architecture 'x64' -InstallDir $dotnetDir -NoPath

    if ($LASTEXITCODE -ne 0) {
        throw '.NET 10 Desktop Runtime fallback installation failed.'
    }

    [Environment]::SetEnvironmentVariable('DOTNET_ROOT', $dotnetDir, 'User')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$dotnetDir*") {
        $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $dotnetDir } else { "$dotnetDir;$userPath" }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
    $env:DOTNET_ROOT = $dotnetDir
    if ($env:Path -notlike "*$dotnetDir*") { $env:Path = "$dotnetDir;$env:Path" }

    Write-OK ".NET 10 Desktop Runtime installed to $dotnetDir"
}

function Test-VCRuntimeX64 {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $v = Get-ItemProperty $p -ErrorAction SilentlyContinue
            if ($v -and $v.Installed -eq 1) { return $true }
        }
    }
    return $false
}

function Install-VCRuntimeX64 {
    if (Test-VCRuntimeX64) {
        Write-OK 'Microsoft Visual C++ x64 runtime already installed.'
        return
    }

    Write-Info 'Installing Microsoft Visual C++ x64 runtime...'
    $vc = Join-Path $DownloadDir 'vc_redist.x64.exe'
    Invoke-Download -Url 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $vc

    $p = Start-Process -FilePath $vc -ArgumentList @('/install','/quiet','/norestart') -PassThru -Wait
    if ($p.ExitCode -notin @(0, 1638, 3010)) {
        throw "Visual C++ runtime installer returned exit code $($p.ExitCode)."
    }
    Write-OK 'Microsoft Visual C++ x64 runtime installed.'
}

function Find-CapFrameX {
    $proc = Get-Process -Name 'CapFrameX' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        try {
            if ($proc.Path -and (Test-Path $proc.Path)) { return $proc.Path }
        } catch {}
    }

    $candidates = @(
        (Join-Path $CapFrameXDir 'CapFrameX.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'CapFrameX\CapFrameX.exe'),
        (Join-Path $env:ProgramFiles 'CapFrameX\CapFrameX.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\CapFrameX\CapFrameX.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -gt 0) { return $candidates[0] }

    $entry = Get-UninstallEntries |
        Where-Object { $_.DisplayName -like 'CapFrameX*' } |
        Select-Object -First 1
    if ($entry -and $entry.InstallLocation) {
        $exe = Join-Path $entry.InstallLocation 'CapFrameX.exe'
        if (Test-Path $exe) { return $exe }
    }

    return $null
}

function Install-CapFrameX {
    Write-Step 'CapFrameX'

    $existing = Find-CapFrameX
    if ($existing -and -not $ForceRefreshTools) {
        Write-OK "Existing CapFrameX found: $existing"
        return $existing
    }

    Install-DotNet10Desktop
    Install-VCRuntimeX64

    Write-Info 'Discovering latest stable CapFrameX release...'
    $release = Invoke-JsonRequest -Url 'https://api.github.com/repos/CXWorld/CapFrameX/releases/latest'

    $asset = $release.assets |
        Where-Object { $_.name -match '^release_.+_portable\.zip$' } |
        Select-Object -First 1

    if (-not $asset) {
        throw 'Latest CapFrameX release has no portable ZIP asset.'
    }

    Write-Info "Latest CapFrameX: $($release.tag_name) / $($asset.name)"
    $zip = Join-Path $DownloadDir $asset.name
    Invoke-Download -Url $asset.browser_download_url -OutFile $zip
    Expand-ZipClean -ZipPath $zip -Destination $CapFrameXDir

    $exe = Find-ExecutableRecursive -RootPath $CapFrameXDir -FileName 'CapFrameX.exe'
    if (-not $exe) { throw 'CapFrameX.exe was not found after extracting the portable package.' }

    Write-OK "CapFrameX portable ready: $exe"
    return $exe
}

function Find-Parsec {
    $proc = Get-Process -Name 'parsecd' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        try {
            if ($proc.Path -and (Test-Path $proc.Path)) { return $proc.Path }
        } catch {}
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Parsec\parsecd.exe'),
        (Join-Path $env:LOCALAPPDATA 'Parsec\parsecd.exe'),
        (Join-Path $env:APPDATA 'Parsec\parsecd.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -gt 0) { return $candidates[0] }

    $entry = Get-UninstallEntries |
        Where-Object { $_.DisplayName -like 'Parsec*' } |
        Select-Object -First 1

    if ($entry -and $entry.InstallLocation) {
        $exe = Join-Path $entry.InstallLocation 'parsecd.exe'
        if (Test-Path $exe) { return $exe }
    }

    return $null
}

function Install-Parsec {
    Write-Step 'Parsec'

    $existing = Find-Parsec
    if ($existing) {
        Write-OK "Parsec already installed: $existing"
        return $existing
    }

    $installer = Join-Path $DownloadDir 'parsec-windows.exe'
    Invoke-Download -Url 'https://builds.parsec.app/package/parsec-windows.exe' -OutFile $installer

    Write-Info 'Installing Parsec silently as a per-computer installation...'
    $p = Start-Process -FilePath $installer -ArgumentList @(
        '/silent',
        '/percomputer',
        '/novdd'
    ) -PassThru -Wait

    if ($p.ExitCode -eq 350) {
        Write-Warn 'Parsec reports that a Windows reboot is pending. Setup can continue, but reboot before relying on Parsec drivers.'
    }
    elseif ($p.ExitCode -ne 0) {
        throw "Parsec installer returned exit code $($p.ExitCode)."
    }

    Start-Sleep -Seconds 2
    $exe = Find-Parsec
    if ($exe) {
        Write-OK "Parsec installed: $exe"
        return $exe
    }

    Write-Warn 'Parsec installer finished, but parsecd.exe was not located yet. It may become available after a reboot.'
    return $null
}

function Write-Config {
    param(
        [string]$HwInfoExe,
        [string]$HwInfoIni,
        [string]$ServerScript,
        [string]$TunnelmoleExe,
        [string]$CapFrameXExe,
        [string]$ParsecExe
    )

    $obj = [ordered]@{
        schema = 'kum-fps-bootstrap-config'
        schema_version = 1
        generated_at = (Get-Date).ToString('o')
        root = $Root
        port = $Port
        hwinfo_exe = $HwInfoExe
        hwinfo_ini = $HwInfoIni
        server_script = $ServerScript
        tunnelmole_exe = $TunnelmoleExe
        capframex_exe = $CapFrameXExe
        parsec_exe = $ParsecExe
        hwinfo_poll_ms = 1000
        github_repo = "https://github.com/$RepoOwner/$RepoName"
    }

    $obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-OK "Config written: $ConfigPath"
}

function Write-Launchers {
    $launcher = @'
param(
    [switch]$Remote,
    [switch]$NoBrowser,
    [switch]$NoCapFrameX
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'kum-fps-config.json'

if (-not (Test-Path $ConfigPath)) {
    Write-Host "KUM-FPS config is missing: $ConfigPath" -ForegroundColor Red
    exit 1
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$port = [int]$cfg.port

function Wait-Http {
    param([string]$Url, [int]$Seconds = 20)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Write-Host ''
Write-Host 'KUM-FPS' -ForegroundColor Cyan
Write-Host '=======' -ForegroundColor DarkGray

# HWiNFO
if ($cfg.hwinfo_exe -and (Test-Path $cfg.hwinfo_exe)) {
    $running = Get-Process -Name 'HWiNFO64' -ErrorAction SilentlyContinue
    if (-not $running) {
        Write-Host '[START] HWiNFO64'
        Start-Process -FilePath $cfg.hwinfo_exe | Out-Null
        Start-Sleep -Seconds 2
    } else {
        Write-Host '[OK]    HWiNFO64 already running' -ForegroundColor Green
    }
} else {
    Write-Host '[WARN]  HWiNFO64 executable not found.' -ForegroundColor Yellow
}

# CapFrameX
if (-not $NoCapFrameX -and $cfg.capframex_exe -and (Test-Path $cfg.capframex_exe)) {
    $running = Get-Process -Name 'CapFrameX' -ErrorAction SilentlyContinue
    if (-not $running) {
        Write-Host '[START] CapFrameX'
        Start-Process -FilePath $cfg.capframex_exe | Out-Null
    } else {
        Write-Host '[OK]    CapFrameX already running' -ForegroundColor Green
    }
}

# win-stat-server
$health = "http://127.0.0.1:$port/health"
$alreadyUp = Wait-Http -Url $health -Seconds 1

if (-not $alreadyUp) {
    if (-not (Test-Path $cfg.server_script)) {
        Write-Host "[ERROR] win-stat-server script not found: $($cfg.server_script)" -ForegroundColor Red
        exit 1
    }

    Write-Host "[START] Performance Lab on port $port"
    $serverArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$($cfg.server_script)`" -Port $port"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $serverArgs -WindowStyle Minimized | Out-Null

    if (-not (Wait-Http -Url $health -Seconds 20)) {
        Write-Host '[ERROR] Performance Lab did not become healthy.' -ForegroundColor Red
        Write-Host 'Check whether HWiNFO Shared Memory is active and whether the port is already in use.'
        exit 1
    }
} else {
    Write-Host '[OK]    Performance Lab already running' -ForegroundColor Green
}

# Verify sensor API, but do not fail startup solely because HWiNFO needs a little longer.
try {
    $sensor = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/sensors" -TimeoutSec 3
    if ($sensor.Ok) {
        Write-Host "[OK]    HWiNFO API: $($sensor.Readings.Count) readings" -ForegroundColor Green
    } else {
        Write-Host "[WARN]  HWiNFO API is reachable but reports: $($sensor.Error)" -ForegroundColor Yellow
    }
} catch {
    Write-Host '[WARN]  Sensor API not ready yet.' -ForegroundColor Yellow
}

if (-not $NoBrowser) {
    Start-Process "http://localhost:$port/"
}

if ($Remote) {
    if (-not $cfg.tunnelmole_exe -or -not (Test-Path $cfg.tunnelmole_exe)) {
        Write-Host '[ERROR] Tunnelmole executable not found.' -ForegroundColor Red
        exit 1
    }

    Write-Host ''
    Write-Host 'PUBLIC REMOTE MODE' -ForegroundColor Yellow
    Write-Host 'The Tunnelmole URL is publicly reachable while this window is open.' -ForegroundColor Yellow
    Write-Host 'Close the Tunnelmole window when remote diagnostics are finished.' -ForegroundColor Yellow
    Write-Host ''

    Start-Process -FilePath $cfg.tunnelmole_exe -ArgumentList @($port)
}
'@

    [IO.File]::WriteAllText($StartPs1, $launcher, (New-Object Text.UTF8Encoding($false)))

    $bat = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\KUM-FPS\START-KUM-FPS.ps1"
if errorlevel 1 (
  echo.
  echo KUM-FPS failed to start.
  pause
)
"@
    [IO.File]::WriteAllText($StartBat, $bat.TrimStart(), (New-Object Text.ASCIIEncoding))

    $remoteBatContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\KUM-FPS\START-KUM-FPS.ps1" -Remote
if errorlevel 1 pause
"@
    [IO.File]::WriteAllText($RemoteBat, $remoteBatContent.TrimStart(), (New-Object Text.ASCIIEncoding))

    # Desktop convenience launchers. They are tiny wrappers, not copies of the installation.
    Copy-Item -LiteralPath $StartBat -Destination $DesktopShortcutBat -Force
    Copy-Item -LiteralPath $RemoteBat -Destination $DesktopRemoteBat -Force

    Write-OK 'Launchers created.'
    Write-Info "Local:  $StartBat"
    Write-Info "Remote: $RemoteBat"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'KUM-FPS bootstrap is for Windows only.'
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'KUM-FPS currently requires 64-bit Windows.'
}

Restart-Elevated

Start-InstallLog

$SetupSucceeded = $false
try {
Write-Host ''
Write-Host 'KUM-FPS ONE-CLICK SETUP' -ForegroundColor Cyan
Write-Host '=======================' -ForegroundColor DarkGray
Write-Host "Install root: $Root"
Write-Host "Dashboard port: $Port"
Write-Host ''

foreach ($dir in @($Root, $ToolsDir, $RuntimeDir, $WinStatDir, $HwInfoManagedDir, $CapFrameXDir, $DownloadDir)) {
    Ensure-Directory $dir
}

$hw = Install-HWiNFO
$server = Install-WinStatServer
$tmole = Install-Tunnelmole

$capframex = $null
if (-not $SkipCapFrameX) {
    try {
        $capframex = Install-CapFrameX
    }
    catch {
        Write-Warn "CapFrameX setup failed: $($_.Exception.Message)"
        Write-Warn 'The rest of KUM-FPS will still be installed.'
    }
}
else {
    Write-Info 'CapFrameX installation skipped by parameter.'
}

$parsec = $null
if (-not $SkipParsec) {
    try {
        $parsec = Install-Parsec
    }
    catch {
        Write-Warn "Parsec setup failed: $($_.Exception.Message)"
        Write-Warn 'The rest of KUM-FPS will still be installed.'
    }
}
else {
    Write-Info 'Parsec installation skipped by parameter.'
}

Write-Step 'Writing KUM-FPS configuration'
Write-Config `
    -HwInfoExe $hw.Exe `
    -HwInfoIni $hw.Ini `
    -ServerScript $server `
    -TunnelmoleExe $tmole `
    -CapFrameXExe $capframex `
    -ParsecExe $parsec

Write-Launchers

Write-Step 'Setup complete'
Write-OK "KUM-FPS is installed in: $Root"
Write-Host ''
Write-Host 'Desktop shortcuts:' -ForegroundColor White
Write-Host '  KUM-FPS.bat         -> local dashboard'
Write-Host '  KUM-FPS REMOTE.bat  -> local dashboard + public Tunnelmole URL'
Write-Host ''
Write-Host 'Notes:' -ForegroundColor White
Write-Host '  - HWiNFO Shared Memory is enabled automatically.'
Write-Host '  - HWiNFO polling is currently set to 1000 ms.'
Write-Host '  - The HWiNFO Free shared-memory session can deactivate after 12 hours; restarting HWiNFO restores it.'
Write-Host '  - Parsec may still require you to log in the first time.'
Write-Host '  - win-stat-server is NOT started automatically by this installer.'
Write-Host '  - Remote mode exposes a PUBLIC URL. Close Tunnelmole when finished.'
Write-Host ''

Write-Info 'Installation/configuration complete. win-stat-server was NOT started.'
Write-Info 'Use the generated KUM-FPS launcher manually when you want to start the local stack.'

$SetupSucceeded = $true
}
catch {
    Write-Host ''
    Write-Host '[FAILED] KUM-FPS setup did not complete.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host 'Detailed error:' -ForegroundColor DarkGray
    Write-Host ($_ | Out-String) -ForegroundColor DarkGray
}
finally {
    Stop-InstallLog

    if ($SetupSucceeded) {
        Wait-BeforeExit -Status 'SUCCESS' -Color Green
    }
    else {
        Wait-BeforeExit -Status 'FAILED' -Color Red
    }
}

if (-not $SetupSucceeded) {
    exit 1
}

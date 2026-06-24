<#
.SYNOPSIS
    Build a Visual Studio C++ solution via MSBuild command line.
.DESCRIPTION
    Auto-detects the installed Visual Studio / MSBuild toolchain via vswhere
    (no hardcoded VS version). Detects the latest available PlatformToolset
    and Windows SDK so the build adapts to whatever is installed. Handles the
    PATH/Path conflict, builds the solution, and optionally copies outputs.
.PARAMETER SolutionPath
    Path to the .sln file.
.PARAMETER Configuration
    Build configuration (Release or Debug). Default: Release.
.PARAMETER Platform
    Target platform. Default: x64.
.PARAMETER DeployDir
    Optional deploy directory. If provided, copies outputs there.
.PARAMETER ExtraMsBuildArgs
    Additional MSBuild arguments (e.g., "/p:TargetName=foo").
.PARAMETER ForceToolset
    Optional: override the auto-detected PlatformToolset (e.g. v142).
.PARAMETER ForceSdk
    Optional: override the auto-detected WindowsTargetPlatformVersion.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$SolutionPath,
    [string]$Configuration = "Release",
    [string]$Platform = "x64",
    [string]$DeployDir = $null,
    [string]$ExtraMsBuildArgs = "",
    [string]$ForceToolset = "",
    [string]$ForceSdk = ""
)

$ErrorActionPreference = "Stop"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found. Is Visual Studio (Build Tools) installed?"
    exit 1
}

# 1. Locate MSBuild for the latest installed Visual Studio (any version, not just 2022)
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
    -find MSBuild\**\Bin\MSBuild.exe 2>$null | Select-Object -First 1
if (-not $msbuild) {
    Write-Error "MSBuild.exe not found. Is the 'MSBuild' VS component installed?"
    exit 1
}

# 2. Detect PlatformToolset from the installed VS version
$vsVer = & $vswhere -latest -products * -property installationVersion 2>$null
$major = if ($vsVer) { ($vsVer -split '\.')[0] } else { "" }
$toolset = if ($ForceToolset) {
    $ForceToolset
} else {
    switch ($major) { 17 {'v143'} 16 {'v142'} 15 {'v141'} default {'v143'} }
}

# 3. Detect the newest installed Windows SDK version
$sdk = $ForceSdk
if (-not $sdk) {
    $roots = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue
    if ($roots -and $roots.KitsRoot10) {
        $libDir = Join-Path $roots.KitsRoot10 'Lib'
        if (Test-Path $libDir) {
            $sdk = (Get-ChildItem $libDir -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | Select-Object -First 1).Name
        }
    }
    if (-not $sdk) { $sdk = '10.0' }
}

Write-Host "MSBuild : $msbuild"
Write-Host "VS ver  : $vsVer (toolset $toolset)"
Write-Host "SDK     : $sdk"
Write-Host "Solution: $SolutionPath"
Write-Host "Config  : $Configuration|$Platform"

# 4. Fix PATH/Path conflict (MSB6001: CL.exe duplicate key)
Remove-Item Env:\PATH -ErrorAction SilentlyContinue

# 5. Build
$workDir = Split-Path $SolutionPath -Parent
$buildArgs = @(
    $SolutionPath,
    "/p:Configuration=$Configuration",
    "/p:Platform=$Platform",
    "/p:PlatformToolset=$toolset",
    "/p:WindowsTargetPlatformVersion=$sdk",
    "/v:minimal",
    "/m",
    "/t:Build"
)
if ($ExtraMsBuildArgs) {
    $buildArgs += $ExtraMsBuildArgs.Split(" ")
}

& $msbuild @buildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "Build succeeded."

# 6. Deploy if requested
if ($DeployDir) {
    $binDir = Join-Path $workDir "bin\$Platform\$Configuration"
    if (Test-Path $binDir) {
        New-Item -ItemType Directory -Path $DeployDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item "$binDir\*" -Destination $DeployDir -Force
        Write-Host "Deployed to: $DeployDir"
    }
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$AppVersion,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildDirectory = Join-Path $ProjectRoot 'build\windows\x64\runner\Release'
$IconFile = Join-Path $ProjectRoot 'windows\runner\resources\app_icon.ico'
$InstallerScript = Join-Path $ProjectRoot 'packaging\windows\Airbridge.iss'

if (-not (Test-Path (Join-Path $BuildDirectory 'airbridge_mobile.exe'))) {
    throw "Flutter Windows release bundle not found at $BuildDirectory. Run 'flutter build windows --release' first."
}
if (-not (Test-Path $IconFile)) {
    throw "Airbridge installer icon not found at $IconFile. Run tool\bootstrap_platforms.ps1 first."
}
if (-not (Test-Path $InstallerScript)) {
    throw "Inno Setup script not found at $InstallerScript."
}

if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $ProjectRoot $OutputDirectory
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
$Compiler = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
if ($Compiler) {
    $CompilerPath = $Compiler.Source
} else {
    $DefaultCompiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    if (-not (Test-Path $DefaultCompiler)) {
        throw 'Inno Setup 6 was not found. Install it with: choco install innosetup --yes --no-progress'
    }
    $CompilerPath = $DefaultCompiler
}

Push-Location $ProjectRoot
try {
    & $CompilerPath "/DAppVersion=$AppVersion" "/O$OutputDirectory" $InstallerScript
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}

$Installer = Join-Path $OutputDirectory "Airbridge-Windows-Setup-$AppVersion.exe"
if (-not (Test-Path $Installer) -or (Get-Item $Installer).Length -eq 0) {
    throw "Inno Setup did not create the expected installer: $Installer"
}
Write-Host "Created Windows installer: $Installer"

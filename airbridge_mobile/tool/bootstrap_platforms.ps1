$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter 3.24+ is required. Install Flutter and add it to PATH.'
}

$TemporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("airbridge-flutter-" + [guid]::NewGuid().ToString('N'))
$Scaffold = Join-Path $TemporaryRoot 'airbridge_mobile'
New-Item -ItemType Directory -Path $TemporaryRoot | Out-Null
try {
    # Create host projects away from lib/ and pubspec.yaml so Flutter cannot
    # replace the hand-written application source.
    flutter create `
        --no-pub `
        --platforms=android,ios,linux,macos,windows `
        --org com.coderosus `
        --project-name airbridge_mobile `
        $Scaffold
    if ($LASTEXITCODE -ne 0) { throw 'flutter create failed.' }

    foreach ($Platform in @('android', 'ios', 'linux', 'macos', 'windows')) {
        $Destination = Join-Path $Root $Platform
        if (-not (Test-Path $Destination)) {
            Copy-Item -Recurse (Join-Path $Scaffold $Platform) $Destination
        }
    }
    $Metadata = Join-Path $Root '.metadata'
    if (-not (Test-Path $Metadata)) {
        Copy-Item (Join-Path $Scaffold '.metadata') $Metadata
    }

    $PythonLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($PythonLauncher) {
        py -3 tool/configure_platforms.py
    } else {
        python tool/configure_platforms.py
    }
    if ($LASTEXITCODE -ne 0) { throw 'Platform configuration failed.' }

    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }

    dart run flutter_launcher_icons
    if ($LASTEXITCODE -ne 0) { throw 'Launcher icon generation failed.' }

    # Some Flutter/plugin combinations generate the Podfile during dependency resolution.
    if ($PythonLauncher) {
        py -3 tool/configure_platforms.py
    } else {
        python tool/configure_platforms.py
    }
    if ($LASTEXITCODE -ne 0) { throw 'Platform configuration failed after pub get.' }
} finally {
    if (Test-Path $TemporaryRoot) {
        Remove-Item -Recurse -Force $TemporaryRoot
    }
}

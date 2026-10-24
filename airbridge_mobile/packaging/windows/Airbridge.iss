#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define ProductName "Airbridge"
#define BuildDirectory AddBackslash(SourcePath) + "..\\..\\build\\windows\\x64\\runner\\Release"
#define IconFile AddBackslash(SourcePath) + "..\\..\\windows\\runner\\resources\\app_icon.ico"

[Setup]
AppId={{5A2F9F04-EC98-4A9B-B54D-77FCFDFB5DA4}
AppName={#ProductName}
AppVersion={#AppVersion}
AppPublisher=Airbridge contributors
AppPublisherURL=https://github.com/codero-sus/AirBridge
DefaultDirName={autopf}\Airbridge
DefaultGroupName=Airbridge
UninstallDisplayName=Airbridge
UninstallDisplayIcon={app}\airbridge_mobile.exe
SetupIconFile={#IconFile}
OutputDir=..\..\build\release
OutputBaseFilename=Airbridge-Windows-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BuildDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Airbridge"; Filename: "{app}\airbridge_mobile.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Airbridge"; Filename: "{app}\airbridge_mobile.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
Root: HKCR; Subkey: "airbridge"; ValueType: string; ValueName: ""; ValueData: "URL:Airbridge Protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "airbridge"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCR; Subkey: "airbridge\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\airbridge_mobile.exe"",0"
Root: HKCR; Subkey: "airbridge\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\airbridge_mobile.exe"" ""%1"""

[Run]
Filename: "{app}\airbridge_mobile.exe"; Description: "Launch Airbridge"; Flags: postinstall nowait skipifsilent

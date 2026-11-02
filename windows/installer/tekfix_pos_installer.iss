; Script generated for Inno Setup 6
; TekFix ERP Windows Desktop Installer
; Supports silent in-app automatic upgrades, desktop shortcuts, and data preservation.

#ifndef MyAppVersion
#define MyAppVersion "1.0.14"
#endif

#define MyAppName "TekFix ERP"
#define MyAppPublisher "TekFix Solutions"
#define MyAppURL "https://github.com/infotekfix-del/tekfix_pos"
#define MyAppExeName "tekfix_pos.exe"

[Setup]
; AppId uniquely identifies this application. Do not change it across releases!
AppId={{B8F8B12C-9C14-4B7E-9721-6A25867E3F11}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} v{#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
; Output directory and installer filename matching TekFixERP-Setup-vX.X.X.exe
OutputDir=..\..\Output
OutputBaseFilename=TekFixERP-Setup-v{#MyAppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

; Seamless In-App Silent Upgrade Configuration
CloseApplications=yes
RestartApplications=no
CloseApplicationsFilter=*.exe
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Main application binaries and Flutter assets
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Fallback location if built without x64 subfolder
; Source: "..\..\build\windows\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Launch TekFix ERP after interactive install (skipped in silent update mode)
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent


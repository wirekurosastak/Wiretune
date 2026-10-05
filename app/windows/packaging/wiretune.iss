; The Windows installer, made with Inno Setup 6 by `dart tool/build.dart windows-installer`, which defines what follows
; from the build: AppVersion (2.0.0), FileVersion (2.0.0.2), Arch (x64compatible or arm64), ArchName (x64 or arm64),
; SourceDir (dist\windows), OutputDir, IconFile and LicenseFile.
;
; It installs for the current user by default (no administrator needed), or for everyone if they choose so. The AppId
; must never change: it is how an update finds the installed Wiretune.
#ifndef AppVersion
  #error Build the installer through tool/build.dart, which defines the version and the folders.
#endif

[Setup]
AppId={{350CE544-0729-4A63-840D-8D7E5DD331B5}
AppName=Wiretune
AppVersion={#AppVersion}
AppVerName=Wiretune {#AppVersion}
VersionInfoVersion={#FileVersion}
AppPublisher=Wiretune contributors
AppPublisherURL=https://github.com/wirekurosastak/Wiretune
AppSupportURL=https://github.com/wirekurosastak/Wiretune/issues
DefaultDirName={autopf}\Wiretune
DefaultGroupName=Wiretune
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed={#Arch}
ArchitecturesInstallIn64BitMode={#Arch}
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Wiretune-{#AppVersion}-windows-{#ArchName}-setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\wiretune.exe
LicenseFile={#LicenseFile}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
#if FileExists(CompilerPath + "Languages\Hungarian.isl")
Name: "hungarian"; MessagesFile: "compiler:Languages\Hungarian.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; The assets of an earlier version: what it shipped and this one doesn't must not linger. (The player's own data is in
; %APPDATA%\Wiretune, never here.)
Type: filesandordirs; Name: "{app}\data"

[Icons]
Name: "{autoprograms}\Wiretune"; Filename: "{app}\wiretune.exe"
Name: "{autodesktop}\Wiretune"; Filename: "{app}\wiretune.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\wiretune.exe"; Description: "{cm:LaunchProgram,Wiretune}"; Flags: nowait postinstall skipifsilent

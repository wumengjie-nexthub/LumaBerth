#ifndef AppVersion
  #error Pass /DAppVersion=... matching pubspec.yaml
#endif
#ifndef VCRedistDir
  #error Pass /DVCRedistDir=... pointing to the matching x64 Microsoft.VC*.CRT Redistributable directory
#endif
#define Bundle "..\build\windows\x64\runner\Release"

[Setup]
AppId={{69D62926-8AC5-4A81-986E-906704A8B97E}
AppName=映格
AppVersion={#AppVersion}
AppPublisher=LumaBerth
AppPublisherURL=https://github.com/wumengjie-nexthub/LumaBerth
DefaultDirName={localappdata}\Programs\LumaBerth
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\LumaBerth.exe
SetupIconFile=runner\resources\app_icon.ico
OutputDir=..\build\dist
OutputBaseFilename=LumaBerth-{#AppVersion}-Windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#Bundle}\LumaBerth.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Bundle}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Bundle}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#VCRedistDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\映格"; Filename: "{app}\LumaBerth.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\LumaBerth.exe"; Description: "{cm:LaunchProgram,映格}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

#define AppName "智悲佛网"
#define AppExe AppName + ".exe"

[Setup]
AppId={{1E55D5B0-8BDE-45B7-BA0C-61D8372E0D2D}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppName}
AppPublisherURL=https://zhibeifw.com/
DefaultDirName={localappdata}\Programs\ZhibeiFW
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.22621
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
OutputBaseFilename=zhibeifw-{#AppVersion}-win-setup
VersionInfoVersion={#FileVersion}
; Inno Setup's estimate omits files selected by a runtime Check.
ExtraDiskSpaceRequired={#PayloadSize}
SetupIconFile=..\App\App.ico
UninstallDisplayIcon={app}\{#AppExe}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Languages]
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#PayloadRoot}\win-arm64\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsArm64
Source: "{#PayloadRoot}\win-x64\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: not IsArm64
Source: "..\Notices\*.txt"; DestDir: "{app}\Licenses"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"

[Run]
Filename: "{app}\{#AppExe}"; Description: "打开{#AppName}"; Flags: postinstall nowait skipifsilent

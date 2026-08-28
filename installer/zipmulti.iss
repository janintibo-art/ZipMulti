#define MyAppName "ZipMulti"
#define MyAppVersion "0.3.0"
#define MyAppPublisher "ZipMulti"
#define MyAppExeName "zip_multi.exe"

[Setup]
AppId={{6D91F1C1-4F65-4D97-BDF2-6C21BCA11EF0}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\ZipMulti
DefaultGroupName=ZipMulti
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=ZipMulti-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\ZipMulti"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\ZipMulti"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Créer un raccourci sur le bureau"; GroupDescription: "Raccourcis :"; Flags: unchecked

[Registry]
; Ajoute une commande contextuelle sans remplacer l'application ZIP par défaut.
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\.zip\shell\ZipMulti"; ValueType: string; ValueName: ""; ValueData: "Reconstruire avec ZipMulti"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\.zip\shell\ZipMulti\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Lancer ZipMulti"; Flags: nowait postinstall skipifsilent

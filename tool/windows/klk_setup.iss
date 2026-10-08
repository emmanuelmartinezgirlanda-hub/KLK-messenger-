; Instalador de KLK messenger para Windows (Inno Setup 6).
; Lo compila .github/workflows/windows.yml.

#define AppName "KLK messenger"
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{6F1C2D7E-3B5A-4C8E-9A41-7D2E0B9C51A3}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=KLK
DefaultDirName={autopf}\KLK messenger
DefaultGroupName=KLK messenger
DisableProgramGroupPage=yes
; Se instala solo para el usuario: no pide permisos de administrador.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\..\build\installer
OutputBaseFilename=KLK-messenger-Setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\klk.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un icono en el escritorio"; GroupDescription: "Iconos:"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\KLK messenger"; Filename: "{app}\klk.exe"
Name: "{autodesktop}\KLK messenger"; Filename: "{app}\klk.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\klk.exe"; Description: "Abrir KLK messenger"; Flags: nowait postinstall skipifsilent

#ifndef SourceRoot
  #error SourceRoot must point to the staged InkBeam payload.
#endif
#ifndef BuildOutput
  #error BuildOutput must point to the release output directory.
#endif
#ifndef AppVersion
  #error AppVersion must be supplied by Build-Release.ps1.
#endif

#define AppDataRoot "{localappdata}\iPadWhiteboardReceiver"
#define AppPayloadRoot AppDataRoot + "\app"
#define DesktopRoot AppPayloadRoot + "\desktop"

[Setup]
AppId={{A8613768-E4F7-4DCF-A502-339231A185A7}
AppName=InkBeam
AppVersion={#AppVersion}
AppPublisher=InkBeam contributors
AppPublisherURL=https://github.com/danielfears/inkbeam
AppSupportURL=https://github.com/danielfears/inkbeam/issues
AppUpdatesURL=https://github.com/danielfears/inkbeam/releases/latest
DefaultDirName={localappdata}\Programs\InkBeam
DefaultGroupName=InkBeam
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
OutputDir={#BuildOutput}
OutputBaseFilename=InkBeam-Setup-v{#AppVersion}
SetupIconFile={#SourceRoot}\desktop\InkBeam.ico
UninstallDisplayIcon={#DesktopRoot}\InkBeam.exe
UninstallDisplayName=InkBeam
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=InkBeam.exe
RestartApplications=no
UsePreviousAppDir=yes
VersionInfoVersion={#AppVersion}
VersionInfoCompany=InkBeam contributors
VersionInfoDescription=InkBeam Windows installer
VersionInfoProductName=InkBeam
VersionInfoProductVersion={#AppVersion}

[Files]
Source: "{#SourceRoot}\*"; DestDir: "{#AppPayloadRoot}"; Excludes: "desktop\bin\*"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\desktop\bin\win-arm64\InkBeam.exe"; DestDir: "{#DesktopRoot}"; DestName: "InkBeam.exe"; Check: PreferArm64Files; Flags: ignoreversion
Source: "{#SourceRoot}\desktop\bin\win-x64\InkBeam.exe"; DestDir: "{#DesktopRoot}"; DestName: "InkBeam.exe"; Check: PreferX64Files; Flags: ignoreversion solidbreak

[Icons]
Name: "{group}\InkBeam"; Filename: "{#DesktopRoot}\InkBeam.exe"; WorkingDir: "{#DesktopRoot}"
Name: "{group}\Uninstall InkBeam"; Filename: "{uninstallexe}"

[Run]
Filename: "{#DesktopRoot}\InkBeam.exe"; Description: "Launch InkBeam"; WorkingDir: "{#DesktopRoot}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{#AppPayloadRoot}\uninstall.ps1"""; WorkingDir: "{#AppPayloadRoot}"; RunOnceId: "RemoveInkBeamRuntime"; Flags: waituntilterminated

[Code]
function PreferArm64Files: Boolean;
begin
  Result := IsArm64;
end;

function PreferX64Files: Boolean;
begin
  Result := not PreferArm64Files and IsX64Compatible;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PowerShell: String;
  Parameters: String;
begin
  if CurStep <> ssPostInstall then
    exit;

  ResultCode := -1;
  WizardForm.StatusLabel.Caption := 'Installing the local AirPlay receiver…';
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{#AppPayloadRoot}\install.ps1') +
    '" -NoLaunch -ManagedInstaller';
  if not Exec(
      PowerShell,
      Parameters,
      ExpandConstant('{#AppPayloadRoot}'),
      SW_HIDE,
      ewWaitUntilTerminated,
      ResultCode) or (ResultCode <> 0) then
  begin
    RaiseException(Format(
      'InkBeam receiver setup failed with exit code %d.', [ResultCode]));
  end;
end;

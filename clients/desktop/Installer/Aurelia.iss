; Aurelia for Windows, installed for all users (Program Files) by scripts/build-desktop.sh with
; Inno Setup. The app brings its own VLC and the Aurelia Server it hosts; neither .NET nor VLC must
; be installed. Windows Firewall lets the server answer devices on the home network (Private
; networks, same subnet) only. Updating replaces the program and keeps every setting; uninstalling
; asks whether the server data should go too, and keeps it unless the person says so. Movie and TV
; show files are never touched.
;
; Defines: AppVersion, AppBuild, Arch (x64 or arm64), SourceDir, OutputDir, IconFile, WizardImage.

#if !Defined(AppVersion) || !Defined(AppBuild) || !Defined(Arch) || !Defined(SourceDir) || !Defined(OutputDir)
  #error Build this with scripts/build-desktop.sh.
#endif

[Setup]
; The AppId identifies Aurelia across updates; never change it.
AppId={{5C492DDE-092C-42C6-9EE4-A7280B31BB37}
AppName=Aurelia
AppVersion={#AppVersion}
AppVerName=Aurelia {#AppVersion} ({#AppBuild})
AppPublisher=Aurelia
VersionInfoVersion={#AppVersion}.{#AppBuild}
VersionInfoProductName=Aurelia
VersionInfoDescription=Aurelia Setup
DefaultDirName={autopf}\Aurelia
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
; Windows 10 version 1809 or later, as .NET 10 requires.
MinVersion=10.0.17763
WizardStyle=modern dynamic
SetupIconFile={#IconFile}
WizardSmallImageFile={#WizardImage}
UninstallDisplayIcon={app}\Aurelia.exe
UninstallDisplayName=Aurelia
; Setup quits a running Aurelia itself (see PrepareToInstall); this only keeps two setups apart.
SetupMutex=AureliaSetupRunning
CloseApplications=yes
RestartApplications=no
OutputDir={#OutputDir}
OutputBaseFilename=Aurelia-{#AppVersion}-{#AppBuild}-Setup-{#Arch}
Compression=lzma2/max
SolidCompression=yes
; The per-user data Setup may remove belongs to the person who runs it.
UsedUserAreasWarning=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; An update replaces the server and VLC completely, so no file of an older version stays behind.
Type: filesandordirs; Name: "{app}\server"
Type: filesandordirs; Name: "{app}\libvlc"
Type: filesandordirs; Name: "{app}\Third-Party Notices"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Aurelia"; Filename: "{app}\Aurelia.exe"
Name: "{autodesktop}\Aurelia"; Filename: "{app}\Aurelia.exe"; Tasks: desktopicon

[Run]
; Windows Firewall: the server may answer devices on the same home network (Private networks) only:
; HTTPS for paired devices and Bonjour (mDNS) so the Apple TV and Mac find it. Replaced on updates.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Aurelia Server"""; Flags: runhidden waituntilterminated; StatusMsg: "Allowing Aurelia Server on your home network..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Aurelia Server"" dir=in action=allow program=""{app}\server\Aurelia.Server.exe"" protocol=TCP profile=private remoteip=localsubnet enable=yes"; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Aurelia Server"" dir=in action=allow program=""{app}\server\Aurelia.Server.exe"" protocol=UDP localport=5353 profile=private remoteip=localsubnet enable=yes"; Flags: runhidden waituntilterminated
Filename: "{app}\Aurelia.exe"; Description: "{cm:LaunchProgram,Aurelia}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Aurelia Server"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveFirewallRule"

[Code]
const
  RunningMutex = 'AureliaDesktopRunning';
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  ApprovedKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';

function AureliaRunning: Boolean;
begin
  Result := CheckForMutexes(RunningMutex);
end;

// Asks a running Aurelia to stop its server cleanly and quit, as Quit Aurelia in the notification
// area does, then waits until it has.
procedure QuitAurelia(AsOriginalUser: Boolean);
var
  App: String;
  Code, Waited: Integer;
begin
  App := ExpandConstant('{app}\Aurelia.exe');
  if not AureliaRunning or not FileExists(App) then Exit;
  if AsOriginalUser then
    ExecAsOriginalUser(App, '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code)
  else
    Exec(App, '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Waited := 0;
  while AureliaRunning and (Waited < 20000) do
  begin
    Sleep(250);
    Waited := Waited + 250;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  QuitAurelia(True);
  if AureliaRunning then
    Result := 'Aurelia is still running. Choose Quit Aurelia from its icon in the notification area, then run Setup again.'
  else
    Result := '';
end;

function InitializeUninstall: Boolean;
begin
  QuitAurelia(False);
  Result := not AureliaRunning;
  if not Result then
    SuppressibleMsgBox('Aurelia is still running. Choose Quit Aurelia from its icon in the notification area, then uninstall again.',
      mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    // Windows should no longer start the removed app at sign-in.
    RegDeleteValue(HKCU, RunKey, 'Aurelia');
    RegDeleteValue(HKCU, ApprovedKey, 'Aurelia');
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    // Kept unless the person chooses otherwise; a silent uninstall keeps it too.
    if SuppressibleMsgBox('Also remove your Aurelia server data from this PC?' + #13#13 +
      'This deletes your library, profiles, watch progress, paired devices and settings. ' +
      'Your movie and TV show files are not touched.' + #13#13 +
      'Choose No to keep everything for a later installation.',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
    begin
      DelTree(ExpandConstant('{localappdata}\Aurelia Server'), True, True, True);
      DelTree(ExpandConstant('{localappdata}\Aurelia'), True, True, True);
    end;
  end;
end;

#ifndef MyAppVersion
  #define MyAppVersion "1.0.1+2"
#endif
#ifndef MyPackageVersion
  #define MyPackageVersion "1.0.1-2"
#endif
#ifndef MyNumericVersion
  #define MyNumericVersion "1.0.1.2"
#endif
#ifndef MyBuildSource
  #define MyBuildSource "build\windows\x64\runner\Release"
#endif
#ifndef MyPreview
  #define MyPreview 0
#endif
#ifndef MyPreviewPage
  #define MyPreviewPage ""
#endif
#ifndef MyCompression
  #define MyCompression "lzma2/ultra64"
#endif
#ifndef MyProductDisplayName
  #define MyProductDisplayName "sohun"
#endif
#ifndef MyProductSlug
  #define MyProductSlug "sohun"
#endif
#ifndef MyProductInstallName
  #define MyProductInstallName "sohun"
#endif
#ifndef MyExecutableName
  #define MyExecutableName "sohun.exe"
#endif
#ifndef MySetupAppId
  #define MySetupAppId "{{1B106F39-A423-46DC-975A-DFE21DA13F80}"
#endif
#ifndef MyAppMutex
  #define MyAppMutex "Local\sohun-desktop-4bf123ad-8fb7-4ba9-a035-c0323928bb52"
#endif

[Setup]
#if MyPreview
Uninstallable=no
#endif
AppId={#MySetupAppId}
AppName={#MyProductDisplayName}
AppVerName={#MyProductDisplayName} {#MyAppVersion}
AppVersion={#MyAppVersion}
AppPublisher=生腌焦糖
AppComments=3D 打印耗材、设备与打印工作流
VersionInfoCompany=生腌焦糖
VersionInfoDescription={#MyProductDisplayName} 安装程序
VersionInfoProductName={#MyProductDisplayName}
VersionInfoProductVersion={#MyNumericVersion}
VersionInfoVersion={#MyNumericVersion}
DefaultDirName={localappdata}\Programs\{#MyProductInstallName}
DefaultGroupName={#MyProductDisplayName}
DisableProgramGroupPage=yes
DisableStartupPrompt=yes
#if MyProductSlug == "sohun"
DisableWelcomePage=yes
#else
DisableWelcomePage=no
#endif
DisableDirPage=no
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\dist\installer
OutputBaseFilename={#MyProductSlug}-setup-{#MyPackageVersion}-windows-x64
SetupIconFile=..\assets\images\branding\themes\sohun_aurora_green_light.ico
UninstallDisplayIcon={app}\{#MyExecutableName}
Compression={#MyCompression}
SolidCompression=yes
WizardStyle=modern light windows11 hidebevels
WizardSizePercent=108
WizardResizable=no
WizardKeepAspectRatio=yes
WizardImageStretch=yes
WizardImageAlphaFormat=defined
WizardImageFile=..\assets\images\branding\themes\sohun_aurora_green_light.png
WizardSmallImageFile=..\assets\images\branding\themes\sohun_aurora_green_light.png
WizardBackColor=#F7FBF6
WizardImageBackColor=#F7FBF6
WizardSmallImageBackColor=#F7FBF6
DefaultDialogFontName=Microsoft YaHei UI
LicenseFile=INSTALL_AGREEMENT.txt
ShowLanguageDialog=no
LanguageDetectionMethod=uilanguage
CloseApplications=yes
CloseApplicationsFilter={#MyExecutableName}
RestartApplications=no
AppMutex={#MyAppMutex}
SetupLogging=yes
UsePreviousAppDir=yes
UsePreviousTasks=yes

[Languages]
Name: "chinesesimp"; MessagesFile: "Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
#include "personal-messages.iss"
chinesesimp.InstallerCaption={#MyProductDisplayName} · 安装
english.InstallerCaption={#MyProductDisplayName} · Setup
chinesesimp.BrandKicker={#MyProductDisplayName}
english.BrandKicker={#MyProductDisplayName}
chinesesimp.WelcomeTitle=准备好，开始吧
english.WelcomeTitle=Ready when you are
chinesesimp.WelcomeBody=让耗材与打印，轻松归位。
english.WelcomeBody=Let filament and printing fall into place.
chinesesimp.WelcomeAction=立即安装
english.WelcomeAction=Install now
chinesesimp.InstallingTitle=正在安放你的工作台
english.InstallingTitle=Setting up your workspace
chinesesimp.InstallingText=正在准备 {#MyProductDisplayName} · %d%%
english.InstallingText=Preparing {#MyProductDisplayName} · %d%%
chinesesimp.InstallingStage1=整理所需文件
english.InstallingStage1=Organizing the essentials
chinesesimp.InstallingStage2=安放应用组件
english.InstallingStage2=Placing the app components
chinesesimp.InstallingStage3=整理快捷方式
english.InstallingStage3=Finishing your shortcuts
chinesesimp.InstallingStage4=马上就好
english.InstallingStage4=Almost there
chinesesimp.FinishedTitle=安装好了
english.FinishedTitle=All set
chinesesimp.FinishedText=现在，去看看你的工作台。
english.FinishedText=Now, take a look at your workspace.
chinesesimp.FinishedAction=打开 {#MyProductDisplayName}
english.FinishedAction=Open {#MyProductDisplayName}
chinesesimp.AgreementTitle=安装前确认
english.AgreementTitle=Before you install
chinesesimp.AgreementSubtitle=请阅读安装说明，并在同意后继续
english.AgreementSubtitle=Review the installation notice before continuing
chinesesimp.AgreementCheck=我已阅读并同意《{#MyProductDisplayName} 安装与使用说明》
english.AgreementCheck=I have read and accept the {#MyProductDisplayName} Installation & Use Notice
chinesesimp.DestinationTitle=选择安装位置
english.DestinationTitle=Choose where to install
chinesesimp.DestinationSubtitle=默认安装到当前用户目录，也可以更改
english.DestinationSubtitle=The default is your user folder, and you can change it
chinesesimp.DestinationField=安装到
english.DestinationField=Install to
chinesesimp.ContinueAction=继续
english.ContinueAction=Continue
chinesesimp.InstallAction=开始安装
english.InstallAction=Install
chinesesimp.BackAction=返回
english.BackAction=Back
chinesesimp.BrowseAction=浏览
english.BrowseAction=Browse
chinesesimp.CloseAction=关闭
english.CloseAction=Close
chinesesimp.CloseHint=关闭安装程序
english.CloseHint=Close setup
chinesesimp.PreviewBlocked=这是安装器界面预览，已停止在写入文件之前；本次不会安装任何软件。
english.PreviewBlocked=This is an installer UI preview. It stops before writing files and does not install anything.
chinesesimp.PreparingTitle=安装尚未开始
english.PreparingTitle=Installation has not started

[LangOptions]
DialogFontName=Microsoft YaHei UI
DialogFontSize=9
WelcomeFontName=Microsoft YaHei UI
WelcomeFontSize=15

[Files]
#if MyPreview
#else
Source: "{#MyBuildSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "Languages\ChineseSimplified.LICENSE.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
#endif

[Icons]
#if MyPreview
#else
Name: "{autoprograms}\{#MyProductDisplayName}"; Filename: "{app}\{#MyExecutableName}"; WorkingDir: "{app}"
#endif
#if MyProductSlug == "sohun"
#if MyPreview
#else
Name: "{autodesktop}\{#MyProductDisplayName}"; Filename: "{app}\{#MyExecutableName}"; WorkingDir: "{app}"; Tasks: desktopicon
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:PersonalDesktopShortcut}"; Flags: checkedonce
#else
#if MyPreview
#else
Name: "{autodesktop}\{#MyProductDisplayName}"; Filename: "{app}\{#MyExecutableName}"; WorkingDir: "{app}"
#endif
#endif

[Run]
#if MyPreview
#else
Filename: "{app}\{#MyExecutableName}"; Description: "启动 {#MyProductDisplayName}"; Flags: nowait postinstall skipifsilent
#endif

[Code]
#if MyProductSlug == "sohun"
#include "personal-ui.iss"
#else
const
  UiFont = 'Microsoft YaHei UI';
  MonoFont = 'Cascadia Code';
  ColorBackground = $00F5F7F5;
  ColorSurface = $00FFFFFF;
  ColorSurfaceHigh = $00FAF9F8;
  ColorPrimary = $002AB400;
  ColorPrimaryDisabled = $00BFD2B9;
  ColorText = $001F1D1D;
  ColorTextSecondary = $00575049;
  ColorTextTertiary = $00968E86;
  ColorOutline = $00E6E2DE;

var
  TopBar: TPanel;
  CloseButton: TBitmapButton;
  PrimaryButton: TBitmapButton;
  BackActionButton: TBitmapButton;
  BrowseButton: TBitmapButton;
  CloseBitmap: TBitmap;
  PrimaryBitmap: TBitmap;
  BackBitmap: TBitmap;
  BrowseBitmap: TBitmap;
  AgreementToggleBitmap: TBitmap;
  AgreementTitle: TNewStaticText;
  AgreementSubtitle: TNewStaticText;
  AgreementCard: TPanel;
  AgreementBody: TNewStaticText;
  AgreementToggle: TBitmapButton;
  AgreementCheckLabel: TNewStaticText;
  AgreementAccepted: Boolean;
  DestinationTitle: TNewStaticText;
  DestinationSubtitle: TNewStaticText;
  DestinationCard: TPanel;
  DestinationFieldLabel: TNewStaticText;
  DestinationInputFrame: TPanel;
  DestinationInputSurface: TPanel;
  DestinationFolderImage: TBitmapImage;
  DestinationFolderBitmap: TBitmap;
  DestinationEdit: TNewPathEdit;
  DestinationHint: TNewStaticText;
  InstallingTitleLabel: TNewStaticText;
  InstallingStageLabel: TNewStaticText;
  InstallingPercentLabel: TNewStaticText;
  PreparingTitleLabel: TNewStaticText;
  PreparingBodyLabel: TNewStaticText;
  ProgressTrack: TPanel;
  ProgressFill: TPanel;
  InstallPercent: Integer;
  InstallStage: String;
  PreparingMessage: String;

function DwmSetWindowAttribute(hWnd: HWND; dwAttribute: Cardinal;
  var pvAttribute: Cardinal; cbAttribute: Cardinal): Integer;
external 'DwmSetWindowAttribute@dwmapi.dll stdcall delayload';

function CreateRoundRectRgn(Left, Top, Right, Bottom,
  EllipseWidth, EllipseHeight: Integer): Longword;
external 'CreateRoundRectRgn@gdi32.dll stdcall';

function SetWindowRgn(hWnd: HWND; Region: Longword; Redraw: Boolean): Integer;
external 'SetWindowRgn@user32.dll stdcall';

procedure ExitProcess(ExitCode: Cardinal);
external 'ExitProcess@kernel32.dll stdcall';

procedure ApplyRoundedRegion(Control: TWinControl; Radius: Integer);
var
  Region: Longword;
begin
  if (Control.Width <= 0) or (Control.Height <= 0) then
    exit;
  Region := CreateRoundRectRgn(
    0, 0, Control.Width + 1, Control.Height + 1, Radius, Radius);
  SetWindowRgn(Control.Handle, Region, True);
end;

procedure ApplySohunWindowChrome;
var
  CornerPreference: Cardinal;
  BorderColor: Cardinal;
begin
  CornerPreference := 2;
  BorderColor := $00DDE7DC;
  try
    DwmSetWindowAttribute(WizardForm.Handle, 33, CornerPreference, 4);
    DwmSetWindowAttribute(WizardForm.Handle, 34, BorderColor, 4);
  except
    { Older Windows versions keep their native window chrome. }
  end;
end;

procedure DrawCloseBitmap;
begin
  CloseBitmap.Width := ScaleX(28);
  CloseBitmap.Height := ScaleY(28);
  CloseBitmap.AlphaFormat := afDefined;
  CloseBitmap.Canvas.Brush.Style := bsSolid;
  CloseBitmap.Canvas.Brush.Color := ColorBackground;
  CloseBitmap.Canvas.Pen.Color := ColorBackground;
  CloseBitmap.Canvas.Rectangle(0, 0, CloseBitmap.Width, CloseBitmap.Height);
  CloseBitmap.Canvas.Pen.Color := ColorTextSecondary;
  CloseBitmap.Canvas.Pen.Width := ScaleX(2);
  CloseBitmap.Canvas.MoveTo(ScaleX(9), ScaleY(9));
  CloseBitmap.Canvas.LineTo(ScaleX(19), ScaleY(19));
  CloseBitmap.Canvas.MoveTo(ScaleX(19), ScaleY(9));
  CloseBitmap.Canvas.LineTo(ScaleX(9), ScaleY(19));
end;

procedure DrawPrimaryBitmap(const Caption: String;
  IsEnabled, IsCompact: Boolean);
var
  FillColor: Integer;
  TextX: Integer;
  TextY: Integer;
begin
  if IsEnabled then
    FillColor := ColorPrimary
  else
    FillColor := ColorPrimaryDisabled;
  if IsCompact then
  begin
    PrimaryBitmap.Width := ScaleX(116);
    PrimaryBitmap.Height := ScaleY(38);
  end
  else
  begin
  PrimaryBitmap.Width := ScaleX(156);
    PrimaryBitmap.Height := ScaleY(42);
  end;
  PrimaryBitmap.AlphaFormat := afDefined;
  PrimaryBitmap.Canvas.Brush.Style := bsSolid;
  PrimaryBitmap.Canvas.Brush.Color := ColorBackground;
  PrimaryBitmap.Canvas.Pen.Color := ColorBackground;
  PrimaryBitmap.Canvas.Rectangle(
    0, 0, PrimaryBitmap.Width, PrimaryBitmap.Height);
  PrimaryBitmap.Canvas.Brush.Color := FillColor;
  PrimaryBitmap.Canvas.Pen.Color := FillColor;
  PrimaryBitmap.Canvas.RoundRect(
    0, 0, PrimaryBitmap.Width, PrimaryBitmap.Height, ScaleX(12), ScaleY(12));
  PrimaryBitmap.Canvas.Font.Name := UiFont;
  if IsCompact then
    PrimaryBitmap.Canvas.Font.Size := 9
  else
    PrimaryBitmap.Canvas.Font.Size := 10;
  PrimaryBitmap.Canvas.Font.Style := [fsBold];
  PrimaryBitmap.Canvas.Font.Color := clWhite;
  TextX := (PrimaryBitmap.Width - PrimaryBitmap.Canvas.TextWidth(Caption)) div 2;
  TextY := (PrimaryBitmap.Height - PrimaryBitmap.Canvas.TextHeight(Caption)) div 2;
  PrimaryBitmap.Canvas.TextOut(TextX, TextY, Caption);
end;

procedure DrawOutlineBitmap(Target: TBitmap; Width, Height: Integer;
  const Caption: String; BackgroundColor, TextColor: Integer);
var
  TextX: Integer;
  TextY: Integer;
begin
  Target.Width := Width;
  Target.Height := Height;
  Target.AlphaFormat := afDefined;
  Target.Canvas.Brush.Style := bsSolid;
  Target.Canvas.Brush.Color := BackgroundColor;
  Target.Canvas.Pen.Color := ColorOutline;
  Target.Canvas.Pen.Width := ScaleX(1);
  Target.Canvas.RoundRect(
    0, 0, Width, Height, ScaleX(10), ScaleY(10));
  Target.Canvas.Font.Name := UiFont;
  Target.Canvas.Font.Size := 9;
  Target.Canvas.Font.Style := [fsBold];
  Target.Canvas.Font.Color := TextColor;
  TextX := (Width - Target.Canvas.TextWidth(Caption)) div 2;
  TextY := (Height - Target.Canvas.TextHeight(Caption)) div 2;
  Target.Canvas.TextOut(TextX, TextY, Caption);
end;

procedure DrawDestinationFolderBitmap;
begin
  DestinationFolderBitmap.Width := ScaleX(24);
  DestinationFolderBitmap.Height := ScaleY(24);
  DestinationFolderBitmap.AlphaFormat := afDefined;
  DestinationFolderBitmap.Canvas.Brush.Style := bsSolid;
  DestinationFolderBitmap.Canvas.Brush.Color := ColorSurfaceHigh;
  DestinationFolderBitmap.Canvas.Pen.Color := ColorSurfaceHigh;
  DestinationFolderBitmap.Canvas.Rectangle(
    0, 0, DestinationFolderBitmap.Width, DestinationFolderBitmap.Height);
  DestinationFolderBitmap.Canvas.Brush.Style := bsClear;
  DestinationFolderBitmap.Canvas.Pen.Color := ColorPrimary;
  DestinationFolderBitmap.Canvas.Pen.Width := ScaleX(2);
  DestinationFolderBitmap.Canvas.RoundRect(
    ScaleX(3), ScaleY(7), ScaleX(21), ScaleY(19), ScaleX(4), ScaleY(4));
  DestinationFolderBitmap.Canvas.MoveTo(ScaleX(4), ScaleY(8));
  DestinationFolderBitmap.Canvas.LineTo(ScaleX(9), ScaleY(8));
  DestinationFolderBitmap.Canvas.LineTo(ScaleX(11), ScaleY(10));
end;

procedure HideNativePreparingControls;
begin
  WizardForm.PreparingErrorBitmapImage.Visible := False;
  WizardForm.PreparingLabel.Visible := False;
  WizardForm.PreparingYesRadio.Visible := False;
  WizardForm.PreparingNoRadio.Visible := False;
  WizardForm.PreparingMemo.Visible := False;
end;

procedure HideNativeChrome;
begin
  WizardForm.NextButton.Visible := False;
  WizardForm.NextButton.TabStop := False;
  WizardForm.BackButton.Visible := False;
  WizardForm.BackButton.TabStop := False;
  WizardForm.CancelButton.Visible := False;
  WizardForm.CancelButton.TabStop := False;
  WizardForm.MainPanel.Visible := False;
  WizardForm.Bevel1.Visible := False;
  WizardForm.BeveledLabel.Visible := False;
  WizardForm.WizardSmallBitmapImage.Visible := False;
  WizardForm.StatusLabel.Visible := False;
  WizardForm.ProgressGauge.Visible := False;
  WizardForm.RunList.Visible := False;
  HideNativePreparingControls;
end;

procedure HideNativeLicenseControls;
begin
  WizardForm.LicenseLabel1.Visible := False;
  WizardForm.LicenseMemo.Visible := False;
  WizardForm.YesRadio.Visible := False;
  WizardForm.NoRadio.Visible := False;
  WizardForm.LicenseAcceptedRadio.Visible := False;
  WizardForm.LicenseNotAcceptedRadio.Visible := False;
end;

procedure HideNativeDirectoryControls;
begin
  WizardForm.SelectDirBitmapImage.Visible := False;
  WizardForm.SelectDirBrowseLabel.Visible := False;
  WizardForm.SelectDirLabel.Visible := False;
  WizardForm.DirEdit.Visible := False;
  WizardForm.DirBrowseButton.Visible := False;
  WizardForm.DiskSpaceLabel.Visible := False;
end;

function LocalizedAgreementBody: String;
begin
  if ActiveLanguage = 'chinesesimp' then
    Result :=
      '1. 默认按当前 Windows 用户安装，下一步可以更改位置.' + #13#10 +
      '2. 库存、打印记录和设备配置默认保存在本机；主动登录或启用联网功能时才访问网络.' + #13#10 +
      '3. 安装程序不会修改 Bambu Studio 项目，打印前请核验参数和设备操作.' + #13#10 +
      '4. 第三方组件及其许可说明会随软件一起提供.' + #13#10 +
      '5. 继续安装表示你已阅读并同意本说明.'
  else
    Result :=
      '1. sohun installs for the current Windows user; you can change the location next.' + #13#10 +
      '2. Inventory, print history, and device settings stay on this device unless you sign in or enable an online feature.' + #13#10 +
      '3. The installer does not modify Bambu Studio projects; verify print parameters and device actions before use.' + #13#10 +
      '4. Third-party components and their notices ship with the application.' + #13#10 +
      '5. Continuing means that you have read and accepted this notice.';
end;

procedure DrawAgreementToggle;
begin
  AgreementToggleBitmap.Width := ScaleX(22);
  AgreementToggleBitmap.Height := ScaleY(22);
  AgreementToggleBitmap.AlphaFormat := afDefined;
  AgreementToggleBitmap.Canvas.Brush.Style := bsSolid;
  AgreementToggleBitmap.Canvas.Brush.Color := ColorBackground;
  AgreementToggleBitmap.Canvas.Pen.Color := ColorBackground;
  AgreementToggleBitmap.Canvas.Rectangle(
    0, 0, AgreementToggleBitmap.Width, AgreementToggleBitmap.Height);
  if AgreementAccepted then
  begin
    AgreementToggleBitmap.Canvas.Brush.Color := ColorPrimary;
    AgreementToggleBitmap.Canvas.Pen.Color := ColorPrimary;
  end
  else
  begin
    AgreementToggleBitmap.Canvas.Brush.Color := ColorSurface;
    AgreementToggleBitmap.Canvas.Pen.Color := ColorOutline;
  end;
  AgreementToggleBitmap.Canvas.RoundRect(
    ScaleX(3), ScaleY(3), ScaleX(19), ScaleY(19), ScaleX(4), ScaleY(4));
  if AgreementAccepted then
  begin
    AgreementToggleBitmap.Canvas.Pen.Color := clWhite;
    AgreementToggleBitmap.Canvas.Pen.Width := ScaleX(2);
    AgreementToggleBitmap.Canvas.MoveTo(ScaleX(7), ScaleY(11));
    AgreementToggleBitmap.Canvas.LineTo(ScaleX(10), ScaleY(14));
    AgreementToggleBitmap.Canvas.LineTo(ScaleX(16), ScaleY(8));
  end;
  AgreementToggle.Bitmap := AgreementToggleBitmap;
end;

procedure SyncNativeLicenseState;
begin
  WizardForm.YesRadio.Checked := AgreementAccepted;
  WizardForm.NoRadio.Checked := not AgreementAccepted;
  WizardForm.LicenseAcceptedRadio.Checked := AgreementAccepted;
  WizardForm.LicenseNotAcceptedRadio.Checked := not AgreementAccepted;
end;

procedure SetPrimaryAction(const Caption: String;
  IsEnabled, AlignRight: Boolean);
begin
  DrawPrimaryBitmap(Caption, IsEnabled, AlignRight);
  PrimaryButton.Bitmap := PrimaryBitmap;
  PrimaryButton.Caption := Caption;
  PrimaryButton.Enabled := IsEnabled;
  PrimaryButton.Width := PrimaryBitmap.Width + ScaleX(4);
  PrimaryButton.Height := PrimaryBitmap.Height + ScaleY(4);
  if AlignRight then
  begin
    PrimaryButton.Left := WizardForm.ClientWidth - PrimaryButton.Width - ScaleX(36);
    PrimaryButton.Top := WizardForm.ClientHeight - ScaleY(54);
  end
  else
    PrimaryButton.Left := (WizardForm.ClientWidth - PrimaryButton.Width) div 2;
  PrimaryButton.Visible := True;
end;

procedure CloseButtonClick(Sender: TObject);
begin
  ExitProcess(0);
end;

procedure PrimaryButtonClick(Sender: TObject);
begin
  if WizardForm.CurPageID = wpLicense then
  begin
    SyncNativeLicenseState;
  end
  else if WizardForm.CurPageID = wpSelectDir then
    WizardForm.DirEdit.Text := DestinationEdit.Text;
  if WizardForm.NextButton.OnClick <> nil then
    WizardForm.NextButton.OnClick(WizardForm.NextButton);
end;

procedure BackActionButtonClick(Sender: TObject);
begin
  if WizardForm.BackButton.OnClick <> nil then
    WizardForm.BackButton.OnClick(WizardForm.BackButton);
end;

procedure AgreementToggleClick(Sender: TObject);
begin
  AgreementAccepted := not AgreementAccepted;
  DrawAgreementToggle;
  SyncNativeLicenseState;
  if WizardForm.YesRadio.OnClick <> nil then
    WizardForm.YesRadio.OnClick(WizardForm.YesRadio);
  if WizardForm.LicenseAcceptedRadio.OnClick <> nil then
    WizardForm.LicenseAcceptedRadio.OnClick(WizardForm.LicenseAcceptedRadio);
  if WizardForm.CurPageID = wpLicense then
  begin
    HideNativeLicenseControls;
    SetPrimaryAction(
      CustomMessage('ContinueAction'), AgreementAccepted, True);
  end;
end;

procedure DestinationEditChanged(Sender: TObject);
begin
  if WizardForm.CurPageID = wpSelectDir then
    SetPrimaryAction(
      CustomMessage('InstallAction'), Trim(DestinationEdit.Text) <> '', True);
end;

procedure BrowseButtonClick(Sender: TObject);
begin
  WizardForm.DirEdit.Text := DestinationEdit.Text;
  if WizardForm.DirBrowseButton.OnClick <> nil then
    WizardForm.DirBrowseButton.OnClick(WizardForm.DirBrowseButton);
  DestinationEdit.Text := WizardForm.DirEdit.Text;
end;

function StageForProgress(Value: Integer): String;
begin
  if Value < 25 then
    Result := CustomMessage('InstallingStage1')
  else if Value < 72 then
    Result := CustomMessage('InstallingStage2')
  else if Value < 96 then
    Result := CustomMessage('InstallingStage3')
  else
    Result := CustomMessage('InstallingStage4');
end;

procedure InitializeWizard;
var
  ContentWidth: Integer;
  CenterX: Integer;
  InnerWidth: Integer;
begin
  WizardForm.Caption := '';
  WizardForm.BorderStyle := bsNone;
  WizardForm.BorderIcons := [biSystemMenu];
  WizardForm.Color := ColorBackground;
  WizardForm.Font.Name := UiFont;
  ApplySohunWindowChrome;

  TopBar := TPanel.Create(WizardForm);
  TopBar.Parent := WizardForm;
  TopBar.Align := alTop;
  TopBar.Height := ScaleY(34);
  TopBar.BevelOuter := bvNone;
  TopBar.Color := ColorBackground;
  TopBar.StyleElements := [seFont, seBorder];
  WizardForm.InnerNotebook.Align := alClient;

  CloseBitmap := TBitmap.Create;
  DrawCloseBitmap;
  CloseButton := TBitmapButton.Create(WizardForm);
  CloseButton.Parent := WizardForm;
  CloseButton.Bitmap := CloseBitmap;
  CloseButton.BackColor := clNone;
  CloseButton.Caption := CustomMessage('CloseAction');
  CloseButton.Hint := CustomMessage('CloseHint');
  CloseButton.ShowHint := True;
  CloseButton.Cursor := crHand;
  CloseButton.TabStop := False;
  CloseButton.SetBounds(
    WizardForm.ClientWidth - ScaleX(40), ScaleY(4), ScaleX(32), ScaleY(32));
  CloseButton.OnClick := @CloseButtonClick;
  CloseButton.BringToFront;

  CenterX := (WizardForm.WelcomePage.Width - ScaleX(128)) div 2;
  WizardForm.WizardBitmapImage.Parent := WizardForm.WelcomePage;
  WizardForm.WizardBitmapImage.SetBounds(
    CenterX, ScaleY(54), ScaleX(128), ScaleY(128));
  WizardForm.WizardBitmapImage.Stretch := True;
  WizardForm.WizardBitmapImage.Center := True;
  WizardForm.WizardBitmapImage.BackColor := clNone;
  WizardForm.WizardBitmapImage.Visible := True;
  WizardForm.WizardBitmapImage.BringToFront;

  ContentWidth := WizardForm.WelcomePage.Width - ScaleX(64);
  WizardForm.WelcomeLabel1.Caption := CustomMessage('WelcomeTitle');
  WizardForm.WelcomeLabel1.SetBounds(
    ScaleX(32), ScaleY(202), ContentWidth, ScaleY(42));
  WizardForm.WelcomeLabel1.Alignment := taCenter;
  WizardForm.WelcomeLabel1.Font.Name := UiFont;
  WizardForm.WelcomeLabel1.Font.Size := 18;
  WizardForm.WelcomeLabel1.Font.Style := [];
  WizardForm.WelcomeLabel1.Font.Color := ColorText;
  WizardForm.WelcomeLabel1.StyleElements := [seBorder];
  WizardForm.WelcomeLabel2.Caption := CustomMessage('WelcomeBody');
  WizardForm.WelcomeLabel2.SetBounds(
    ScaleX(32), ScaleY(250), ContentWidth, ScaleY(28));
  WizardForm.WelcomeLabel2.Alignment := taCenter;
  WizardForm.WelcomeLabel2.Font.Name := UiFont;
  WizardForm.WelcomeLabel2.Font.Size := 10;
  WizardForm.WelcomeLabel2.Font.Color := ColorTextSecondary;
  WizardForm.WelcomeLabel2.StyleElements := [seBorder];

  WizardForm.WizardBitmapImage2.SetBounds(
    CenterX, ScaleY(54), ScaleX(128), ScaleY(128));
  WizardForm.WizardBitmapImage2.Stretch := True;
  WizardForm.WizardBitmapImage2.Center := True;
  WizardForm.WizardBitmapImage2.BackColor := clNone;
  WizardForm.FinishedHeadingLabel.Caption := CustomMessage('FinishedTitle');
  WizardForm.FinishedHeadingLabel.SetBounds(
    ScaleX(32), ScaleY(194), ContentWidth, ScaleY(38));
  WizardForm.FinishedHeadingLabel.Alignment := taCenter;
  WizardForm.FinishedHeadingLabel.Font.Name := UiFont;
  WizardForm.FinishedHeadingLabel.Font.Size := 16;
  WizardForm.FinishedHeadingLabel.Font.Style := [fsBold];
  WizardForm.FinishedHeadingLabel.Font.Color := ColorText;
  WizardForm.FinishedHeadingLabel.StyleElements := [seBorder];
  WizardForm.FinishedLabel.Caption := CustomMessage('FinishedText');
  WizardForm.FinishedLabel.SetBounds(
    ScaleX(32), ScaleY(238), ContentWidth, ScaleY(26));
  WizardForm.FinishedLabel.Alignment := taCenter;
  WizardForm.FinishedLabel.Font.Name := UiFont;
  WizardForm.FinishedLabel.Font.Size := 10;
  WizardForm.FinishedLabel.Font.Color := ColorTextSecondary;
  WizardForm.FinishedLabel.StyleElements := [seBorder];

  HideNativeLicenseControls;
  InnerWidth := WizardForm.LicensePage.Width - ScaleX(80);
  AgreementTitle := TNewStaticText.Create(WizardForm);
  AgreementTitle.Parent := WizardForm.LicensePage;
  AgreementTitle.AutoSize := False;
  AgreementTitle.Caption := CustomMessage('AgreementTitle');
  AgreementTitle.SetBounds(
    ScaleX(40), TopBar.Height + ScaleY(6), InnerWidth, ScaleY(30));
  AgreementTitle.Font.Name := UiFont;
  AgreementTitle.Font.Size := 15;
  AgreementTitle.Font.Style := [fsBold];
  AgreementTitle.Font.Color := ColorText;
  AgreementTitle.StyleElements := [seBorder];
  AgreementSubtitle := TNewStaticText.Create(WizardForm);
  AgreementSubtitle.Parent := WizardForm.LicensePage;
  AgreementSubtitle.AutoSize := False;
  AgreementSubtitle.Caption := CustomMessage('AgreementSubtitle');
  AgreementSubtitle.SetBounds(
    ScaleX(40), TopBar.Height + ScaleY(40), InnerWidth, ScaleY(24));
  AgreementSubtitle.Font.Name := UiFont;
  AgreementSubtitle.Font.Size := 9;
  AgreementSubtitle.Font.Color := ColorTextSecondary;
  AgreementSubtitle.StyleElements := [seBorder];
  AgreementCard := TPanel.Create(WizardForm);
  AgreementCard.Parent := WizardForm.LicensePage;
  AgreementCard.SetBounds(
    ScaleX(40), TopBar.Height + ScaleY(74), InnerWidth, ScaleY(190));
  AgreementCard.BevelOuter := bvNone;
  AgreementCard.Color := ColorSurface;
  AgreementCard.StyleElements := [seFont, seBorder];
  ApplyRoundedRegion(AgreementCard, ScaleX(16));
  AgreementBody := TNewStaticText.Create(WizardForm);
  AgreementBody.Parent := AgreementCard;
  AgreementBody.AutoSize := False;
  AgreementBody.WordWrap := True;
  AgreementBody.Caption := LocalizedAgreementBody;
  AgreementBody.SetBounds(
    ScaleX(16), ScaleY(12), AgreementCard.Width - ScaleX(32), ScaleY(166));
  AgreementBody.Font.Name := UiFont;
  AgreementBody.Font.Size := 9;
  AgreementBody.Font.Color := ColorTextSecondary;
  AgreementBody.StyleElements := [seBorder];
  AgreementAccepted := False;
  SyncNativeLicenseState;
  AgreementToggleBitmap := TBitmap.Create;
  AgreementToggle := TBitmapButton.Create(WizardForm);
  AgreementToggle.Parent := WizardForm.LicensePage;
  AgreementToggle.BackColor := clNone;
  AgreementToggle.Caption := CustomMessage('AgreementCheck');
  AgreementToggle.Hint := CustomMessage('AgreementCheck');
  AgreementToggle.ShowHint := True;
  AgreementToggle.Cursor := crHand;
  AgreementToggle.TabStop := False;
  AgreementToggle.SetBounds(
    ScaleX(40), TopBar.Height + ScaleY(279), ScaleX(24), ScaleY(24));
  AgreementToggle.OnClick := @AgreementToggleClick;
  AgreementCheckLabel := TNewStaticText.Create(WizardForm);
  AgreementCheckLabel.Parent := WizardForm.LicensePage;
  AgreementCheckLabel.AutoSize := False;
  AgreementCheckLabel.WordWrap := True;
  AgreementCheckLabel.Caption := CustomMessage('AgreementCheck');
  AgreementCheckLabel.SetBounds(
    ScaleX(70), TopBar.Height + ScaleY(280),
    InnerWidth - ScaleX(30), ScaleY(24));
  AgreementCheckLabel.Font.Name := UiFont;
  AgreementCheckLabel.Font.Size := 9;
  AgreementCheckLabel.Font.Color := ColorText;
  AgreementCheckLabel.Cursor := crHand;
  AgreementCheckLabel.StyleElements := [seBorder];
  AgreementCheckLabel.OnClick := @AgreementToggleClick;
  DrawAgreementToggle;

  HideNativeDirectoryControls;
  InnerWidth := WizardForm.SelectDirPage.Width - ScaleX(80);
  DestinationTitle := TNewStaticText.Create(WizardForm);
  DestinationTitle.Parent := WizardForm.SelectDirPage;
  DestinationTitle.AutoSize := False;
  DestinationTitle.Caption := CustomMessage('DestinationTitle');
  DestinationTitle.SetBounds(
    ScaleX(40), TopBar.Height + ScaleY(30), InnerWidth, ScaleY(30));
  DestinationTitle.Font.Name := UiFont;
  DestinationTitle.Font.Size := 15;
  DestinationTitle.Font.Style := [fsBold];
  DestinationTitle.Font.Color := ColorText;
  DestinationTitle.StyleElements := [seBorder];
  DestinationSubtitle := TNewStaticText.Create(WizardForm);
  DestinationSubtitle.Parent := WizardForm.SelectDirPage;
  DestinationSubtitle.AutoSize := False;
  DestinationSubtitle.Caption := CustomMessage('DestinationSubtitle');
  DestinationSubtitle.SetBounds(
    ScaleX(40), TopBar.Height + ScaleY(64), InnerWidth, ScaleY(24));
  DestinationSubtitle.Font.Name := UiFont;
  DestinationSubtitle.Font.Size := 9;
  DestinationSubtitle.Font.Color := ColorTextSecondary;
  DestinationSubtitle.StyleElements := [seBorder];
  DestinationCard := TPanel.Create(WizardForm);
  DestinationCard.Parent := WizardForm.SelectDirPage;
  DestinationCard.SetBounds(
    ScaleX(40), TopBar.Height + ScaleY(100), InnerWidth, ScaleY(136));
  DestinationCard.BevelOuter := bvNone;
  DestinationCard.Color := ColorSurface;
  DestinationCard.StyleElements := [seFont, seBorder];
  ApplyRoundedRegion(DestinationCard, ScaleX(18));
  DestinationFieldLabel := TNewStaticText.Create(WizardForm);
  DestinationFieldLabel.Parent := DestinationCard;
  DestinationFieldLabel.AutoSize := False;
  DestinationFieldLabel.Caption := CustomMessage('DestinationField');
  DestinationFieldLabel.SetBounds(
    ScaleX(18), ScaleY(14), DestinationCard.Width - ScaleX(36), ScaleY(20));
  DestinationFieldLabel.Font.Name := UiFont;
  DestinationFieldLabel.Font.Size := 9;
  DestinationFieldLabel.Font.Style := [fsBold];
  DestinationFieldLabel.Font.Color := ColorText;
  DestinationFieldLabel.StyleElements := [seBorder];
  DestinationInputFrame := TPanel.Create(WizardForm);
  DestinationInputFrame.Parent := DestinationCard;
  DestinationInputFrame.SetBounds(
    ScaleX(18), ScaleY(42), DestinationCard.Width - ScaleX(36), ScaleY(46));
  DestinationInputFrame.BevelOuter := bvNone;
  DestinationInputFrame.Color := ColorOutline;
  DestinationInputFrame.StyleElements := [seFont, seBorder];
  ApplyRoundedRegion(DestinationInputFrame, ScaleX(12));
  DestinationInputSurface := TPanel.Create(WizardForm);
  DestinationInputSurface.Parent := DestinationInputFrame;
  DestinationInputSurface.SetBounds(
    ScaleX(1), ScaleY(1), DestinationInputFrame.Width - ScaleX(2),
    DestinationInputFrame.Height - ScaleY(2));
  DestinationInputSurface.BevelOuter := bvNone;
  DestinationInputSurface.Color := ColorSurfaceHigh;
  DestinationInputSurface.StyleElements := [seFont, seBorder];
  ApplyRoundedRegion(DestinationInputSurface, ScaleX(11));
  DestinationFolderBitmap := TBitmap.Create;
  DrawDestinationFolderBitmap;
  DestinationFolderImage := TBitmapImage.Create(WizardForm);
  DestinationFolderImage.Parent := DestinationInputSurface;
  DestinationFolderImage.Bitmap := DestinationFolderBitmap;
  DestinationFolderImage.BackColor := ColorSurfaceHigh;
  DestinationFolderImage.SetBounds(
    ScaleX(10), ScaleY(10), ScaleX(24), ScaleY(24));
  DestinationEdit := TNewPathEdit.Create(WizardForm);
  DestinationEdit.Parent := DestinationInputSurface;
  DestinationEdit.AutoSize := False;
  DestinationEdit.SetBounds(
    ScaleX(42), ScaleY(8), DestinationInputSurface.Width - ScaleX(130),
    ScaleY(28));
  DestinationEdit.BorderStyle := bsNone;
  DestinationEdit.Color := ColorSurfaceHigh;
  DestinationEdit.Font.Name := UiFont;
  DestinationEdit.Font.Size := 9;
  DestinationEdit.Font.Color := ColorText;
  DestinationEdit.Text := WizardForm.DirEdit.Text;
  DestinationEdit.StyleElements := [seBorder];
  DestinationEdit.OnChange := @DestinationEditChanged;
  BrowseBitmap := TBitmap.Create;
  DrawOutlineBitmap(
    BrowseBitmap, ScaleX(72), ScaleY(34),
    CustomMessage('BrowseAction'), ColorSurfaceHigh, ColorPrimary);
  BrowseButton := TBitmapButton.Create(WizardForm);
  BrowseButton.Parent := DestinationInputSurface;
  BrowseButton.Bitmap := BrowseBitmap;
  BrowseButton.BackColor := clNone;
  BrowseButton.Caption := CustomMessage('BrowseAction');
  BrowseButton.Cursor := crHand;
  BrowseButton.TabStop := False;
  BrowseButton.SetBounds(
    DestinationInputSurface.Width - ScaleX(80), ScaleY(4),
    ScaleX(76), ScaleY(38));
  BrowseButton.OnClick := @BrowseButtonClick;
  DestinationHint := TNewStaticText.Create(WizardForm);
  DestinationHint.Parent := DestinationCard;
  DestinationHint.AutoSize := False;
  DestinationHint.Caption := WizardForm.DiskSpaceLabel.Caption;
  DestinationHint.SetBounds(
    ScaleX(18), ScaleY(102), DestinationCard.Width - ScaleX(36), ScaleY(22));
  DestinationHint.Font.Name := UiFont;
  DestinationHint.Font.Size := 8;
  DestinationHint.Font.Color := ColorTextTertiary;
  DestinationHint.StyleElements := [seBorder];

  PreparingTitleLabel := TNewStaticText.Create(WizardForm);
  PreparingTitleLabel.Parent := WizardForm.PreparingPage;
  PreparingTitleLabel.AutoSize := False;
  PreparingTitleLabel.Caption := CustomMessage('PreparingTitle');
  PreparingTitleLabel.SetBounds(
    ScaleX(48), TopBar.Height + ScaleY(92),
    WizardForm.PreparingPage.Width - ScaleX(96), ScaleY(36));
  PreparingTitleLabel.Alignment := taCenter;
  PreparingTitleLabel.Font.Name := UiFont;
  PreparingTitleLabel.Font.Size := 15;
  PreparingTitleLabel.Font.Style := [fsBold];
  PreparingTitleLabel.Font.Color := ColorText;
  PreparingTitleLabel.StyleElements := [seBorder];
  PreparingBodyLabel := TNewStaticText.Create(WizardForm);
  PreparingBodyLabel.Parent := WizardForm.PreparingPage;
  PreparingBodyLabel.AutoSize := False;
  PreparingBodyLabel.WordWrap := True;
  PreparingBodyLabel.SetBounds(
    ScaleX(72), TopBar.Height + ScaleY(140),
    WizardForm.PreparingPage.Width - ScaleX(144), ScaleY(82));
  PreparingBodyLabel.Alignment := taCenter;
  PreparingBodyLabel.Font.Name := UiFont;
  PreparingBodyLabel.Font.Size := 10;
  PreparingBodyLabel.Font.Color := ColorTextSecondary;
  PreparingBodyLabel.StyleElements := [seBorder];
  PreparingMessage := '';

  WizardForm.StatusLabel.Visible := False;
  WizardForm.ProgressGauge.Visible := False;
  InnerWidth := WizardForm.InstallingPage.Width - ScaleX(96);
  InstallingTitleLabel := TNewStaticText.Create(WizardForm);
  InstallingTitleLabel.Parent := WizardForm.InstallingPage;
  InstallingTitleLabel.AutoSize := False;
  InstallingTitleLabel.Caption := CustomMessage('InstallingTitle');
  InstallingTitleLabel.SetBounds(
    ScaleX(48), TopBar.Height + ScaleY(54), InnerWidth, ScaleY(34));
  InstallingTitleLabel.Alignment := taCenter;
  InstallingTitleLabel.Font.Name := UiFont;
  InstallingTitleLabel.Font.Size := 15;
  InstallingTitleLabel.Font.Style := [fsBold];
  InstallingTitleLabel.Font.Color := ColorText;
  InstallingTitleLabel.StyleElements := [seBorder];
  InstallingStageLabel := TNewStaticText.Create(WizardForm);
  InstallingStageLabel.Parent := WizardForm.InstallingPage;
  InstallingStageLabel.AutoSize := False;
  InstallingStageLabel.Caption := CustomMessage('InstallingStage1');
  InstallingStageLabel.SetBounds(
    ScaleX(48), TopBar.Height + ScaleY(94), InnerWidth, ScaleY(24));
  InstallingStageLabel.Alignment := taCenter;
  InstallingStageLabel.Font.Name := UiFont;
  InstallingStageLabel.Font.Size := 9;
  InstallingStageLabel.Font.Color := ColorTextSecondary;
  InstallingStageLabel.StyleElements := [seBorder];
  ProgressTrack := TPanel.Create(WizardForm);
  ProgressTrack.Parent := WizardForm.InstallingPage;
  ProgressTrack.SetBounds(ScaleX(72), TopBar.Height + ScaleY(144),
    WizardForm.InstallingPage.Width - ScaleX(144), ScaleY(8));
  ProgressTrack.BevelOuter := bvNone;
  ProgressTrack.Color := ColorOutline;
  ProgressTrack.StyleElements := [seFont, seBorder];
  ApplyRoundedRegion(ProgressTrack, ScaleX(8));
  ProgressFill := TPanel.Create(WizardForm);
  ProgressFill.Parent := ProgressTrack;
  ProgressFill.SetBounds(0, 0, ScaleX(1), ProgressTrack.Height);
  ProgressFill.BevelOuter := bvNone;
  ProgressFill.Color := ColorPrimary;
  ProgressFill.StyleElements := [seFont, seBorder];
  ApplyRoundedRegion(ProgressFill, ScaleX(8));
  InstallingPercentLabel := TNewStaticText.Create(WizardForm);
  InstallingPercentLabel.Parent := WizardForm.InstallingPage;
  InstallingPercentLabel.AutoSize := False;
  InstallingPercentLabel.Caption := '0%';
  InstallingPercentLabel.SetBounds(
    ScaleX(48), TopBar.Height + ScaleY(172), InnerWidth, ScaleY(28));
  InstallingPercentLabel.Alignment := taCenter;
  InstallingPercentLabel.Font.Name := MonoFont;
  InstallingPercentLabel.Font.Size := 11;
  InstallingPercentLabel.Font.Style := [fsBold];
  InstallingPercentLabel.Font.Color := ColorPrimary;
  InstallingPercentLabel.StyleElements := [seBorder];

  PrimaryBitmap := TBitmap.Create;
  DrawPrimaryBitmap(CustomMessage('WelcomeAction'), True, False);
  PrimaryButton := TBitmapButton.Create(WizardForm);
  PrimaryButton.Parent := WizardForm;
  PrimaryButton.Bitmap := PrimaryBitmap;
  PrimaryButton.BackColor := clNone;
  PrimaryButton.Caption := CustomMessage('WelcomeAction');
  PrimaryButton.Cursor := crHand;
  PrimaryButton.TabStop := False;
  PrimaryButton.SetBounds(
    (WizardForm.ClientWidth - ScaleX(160)) div 2,
    WizardForm.ClientHeight - ScaleY(58), ScaleX(160), ScaleY(46));
  PrimaryButton.OnClick := @PrimaryButtonClick;
  BackBitmap := TBitmap.Create;
  DrawOutlineBitmap(
    BackBitmap, ScaleX(116), ScaleY(38),
    CustomMessage('BackAction'), ColorBackground, ColorTextSecondary);
  BackActionButton := TBitmapButton.Create(WizardForm);
  BackActionButton.Parent := WizardForm;
  BackActionButton.Bitmap := BackBitmap;
  BackActionButton.BackColor := clNone;
  BackActionButton.Caption := CustomMessage('BackAction');
  BackActionButton.Cursor := crHand;
  BackActionButton.TabStop := False;
  BackActionButton.SetBounds(
    ScaleX(36), WizardForm.ClientHeight - ScaleY(54), ScaleX(120), ScaleY(42));
  BackActionButton.OnClick := @BackActionButtonClick;
  BackActionButton.Visible := False;

  HideNativeChrome;
  InstallPercent := 0;
  InstallStage := CustomMessage('InstallingStage1');
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  HideNativeChrome;
  TopBar.Visible := True;
  CloseButton.Visible := CurPageID <> wpInstalling;
  WizardForm.WizardBitmapImage.Visible := False;
  WizardForm.WizardBitmapImage2.Visible := False;
  PrimaryButton.Visible := False;
  PrimaryButton.OnClick := @PrimaryButtonClick;
  PrimaryButton.Top := WizardForm.ClientHeight - ScaleY(58);
  BackActionButton.Visible := False;
  PreparingTitleLabel.Visible := False;
  PreparingBodyLabel.Visible := False;
  case CurPageID of
    wpWelcome:
      begin
        PrimaryButton.Top := WizardForm.ClientHeight - ScaleY(96);
        SetPrimaryAction(CustomMessage('WelcomeAction'), True, False);
        WizardForm.WizardBitmapImage.Visible := True;
      end;
    wpLicense:
      begin
        HideNativeLicenseControls;
        AgreementAccepted := WizardForm.LicenseAcceptedRadio.Checked;
        DrawAgreementToggle;
        SetPrimaryAction(
          CustomMessage('ContinueAction'), AgreementAccepted, True);
        BackActionButton.Visible := True;
      end;
    wpSelectDir:
      begin
        HideNativeDirectoryControls;
        if Trim(DestinationEdit.Text) = '' then
          DestinationEdit.Text := WizardForm.DirEdit.Text;
        DestinationEdit.SelStart := 0;
        DestinationEdit.SelLength := 0;
        DestinationHint.Caption := WizardForm.DiskSpaceLabel.Caption;
        SetPrimaryAction(
          CustomMessage('InstallAction'), Trim(DestinationEdit.Text) <> '', True);
        BackActionButton.Visible := True;
      end;
    wpPreparing:
      begin
        HideNativePreparingControls;
        if Trim(PreparingMessage) = '' then
          PreparingMessage := WizardForm.PreparingMemo.Text;
        PreparingBodyLabel.Caption := PreparingMessage;
        PreparingTitleLabel.Visible := True;
        PreparingBodyLabel.Visible := True;
        SetPrimaryAction(CustomMessage('CloseAction'), True, False);
        PrimaryButton.OnClick := @CloseButtonClick;
      end;
    wpInstalling:
      begin
        InstallPercent := 0;
        InstallStage := CustomMessage('InstallingStage1');
        InstallingStageLabel.Caption := InstallStage;
        InstallingPercentLabel.Caption := '0%';
        ProgressFill.Width := ScaleX(1);
        ApplyRoundedRegion(ProgressFill, ScaleX(8));
      end;
    wpFinished:
      begin
        SetPrimaryAction(CustomMessage('FinishedAction'), True, False);
        WizardForm.WizardBitmapImage2.Visible := True;
      end;
  end;
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
var
  FillWidth: Integer;
begin
  if MaxProgress > 0 then
  begin
    InstallPercent := (CurProgress * 100) div MaxProgress;
    InstallStage := StageForProgress(InstallPercent);
    InstallingStageLabel.Caption := InstallStage;
    InstallingPercentLabel.Caption := IntToStr(InstallPercent) + '%';
    FillWidth := (ProgressTrack.Width * InstallPercent) div 100;
    if FillWidth < ScaleX(1) then
      FillWidth := ScaleX(1);
    ProgressFill.Width := FillWidth;
    ApplyRoundedRegion(ProgressFill, ScaleX(8));
  end;
end;

#if MyPreview
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  NeedsRestart := False;
  PreparingMessage := CustomMessage('PreviewBlocked');
  Result := PreparingMessage;
end;
#endif
#endif

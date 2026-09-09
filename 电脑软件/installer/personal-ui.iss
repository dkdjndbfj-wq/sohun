{ Personal installer. Native Inno pages remain the source of installation state;
  this presentation layer never installs, deletes or exits the process itself. }
type
#if VER >= 0x07000000
  TWindowUnsigned = NativeUInt;
  TWindowSigned = NativeInt;
#else
  TWindowUnsigned = LongWord;
  TWindowSigned = LongInt;
#endif

const
  UiFont = 'Microsoft YaHei UI';
  Background = $00F3F6F3;
  Surface = $00FCFDFC;
  Forest = $001F8700;
  Accent = $002AB400;
  Ink = $001F1D1D;
  Muted = $00575049;
  Outline = $00E4E9E3;

var
  BrandPanel, SettingsPanel, ProgressPanel, FinishedPanel: TPanel;
  PrimaryButton, SecondaryButton, BrowseButton, NoticeButton: TBitmapButton;
  PrimaryBitmap, SecondaryBitmap, BrowseBitmap, NoticeBitmap: TBitmap;
  FooterHint, SpaceHint, ProgressStatus, ProgressPercent, FinishedPath: TNewStaticText;
  DestinationEdit: TNewPathEdit;
  DesktopCheck, AgreementCheck: TNewCheckBox;
  ProgressTrack, ProgressFill: TPanel;
  CurrentUiPage: Integer;
  UiReady: Boolean;
  PageHeading, PageSubtitle: TNewStaticText;
  CloseActionButton, MinimizeActionButton: TBitmapButton;
  CloseActionBitmap, MinimizeActionBitmap: TBitmap;
  ChromeCallback: TWindowUnsigned;

function SetWindowSubclass(Window: HWND; Callback, ID, Data: TWindowUnsigned): Boolean;
external 'SetWindowSubclass@comctl32.dll stdcall';
function RemoveWindowSubclass(Window: HWND; Callback, ID: TWindowUnsigned): Boolean;
external 'RemoveWindowSubclass@comctl32.dll stdcall';
function DefSubclassProc(Window: HWND; Message: Cardinal; WParam: TWindowUnsigned;
  LParam: TWindowSigned): TWindowSigned;
external 'DefSubclassProc@comctl32.dll stdcall';
function GetWindowRect(Window: HWND; var Rect: TRect): Boolean;
external 'GetWindowRect@user32.dll stdcall';
function ShowWindow(Window: HWND; Command: Integer): Boolean;
external 'ShowWindow@user32.dll stdcall';

function WindowChromeProc(Window: HWND; Message: Cardinal; WParam: TWindowUnsigned;
  LParam: TWindowSigned; ID, Data: TWindowUnsigned): TWindowSigned;
var
  Rect: TRect;
  X, Y: Integer;
begin
  if Message = $0084 then
  begin
    X := LParam and $FFFF;
    Y := (LParam shr 16) and $FFFF;
    if X >= 32768 then X := X - 65536;
    if Y >= 32768 then Y := Y - 65536;
    if GetWindowRect(Window, Rect) then
    begin
      X := X - Rect.Left;
      Y := Y - Rect.Top;
      if (Y >= 0) and (Y < ScaleY(32)) and
        (X >= 0) and (X < WizardForm.Width - ScaleX(84)) then
      begin
        Result := 2; { HTCAPTION gives normal Windows dragging. }
        exit;
      end;
    end;
  end;
  Result := DefSubclassProc(Window, Message, WParam, LParam);
end;

procedure CloseActionClick(Sender: TObject);
begin
  WizardForm.Close;
end;

procedure MinimizeActionClick(Sender: TObject);
begin
  ShowWindow(WizardForm.Handle, 6);
end;

function DwmSetWindowAttribute(hWnd: HWND; dwAttribute: Cardinal;
  var pvAttribute: Cardinal; cbAttribute: Cardinal): Integer;
external 'DwmSetWindowAttribute@dwmapi.dll stdcall delayload';

function CreateRoundRectRgn(Left, Top, Right, Bottom,
  EllipseWidth, EllipseHeight: Integer): HWND;
external 'CreateRoundRectRgn@gdi32.dll stdcall';

function SetWindowRgn(hWnd: HWND; Region: HWND; Redraw: Boolean): Integer;
external 'SetWindowRgn@user32.dll stdcall';

function DeleteObject(Obj: HWND): Boolean;
external 'DeleteObject@gdi32.dll stdcall';

procedure RoundPanel(Panel: TPanel; Radius: Integer);
var
  Region: HWND;
begin
  Region := CreateRoundRectRgn(0, 0, Panel.Width + 1, Panel.Height + 1,
    ScaleX(Radius * 2), ScaleY(Radius * 2));
  if SetWindowRgn(Panel.Handle, Region, True) = 0 then
    DeleteObject(Region);
end;

procedure ApplyWindowShape(Sender: TObject);
var
  Region: HWND;
begin
  { One rounded outline for the complete frameless window. }
  Region := CreateRoundRectRgn(0, 0, WizardForm.Width + 1, WizardForm.Height + 1,
    ScaleX(36), ScaleY(36));
  if SetWindowRgn(WizardForm.Handle, Region, True) = 0 then DeleteObject(Region);
end;

function PanelAt(Parent: TWinControl; X, Y, W, H, Color: Integer): TPanel;
begin
  Result := TPanel.Create(WizardForm);
  Result.Parent := Parent;
  Result.SetBounds(ScaleX(X), ScaleY(Y), ScaleX(W), ScaleY(H));
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
  Result.Color := Color;
  Result.StyleElements := [];
end;

function LabelAt(Parent: TWinControl; const Text: String;
  X, Y, W, H, Size, Color: Integer; Bold: Boolean): TNewStaticText;
begin
  Result := TNewStaticText.Create(WizardForm);
  Result.Parent := Parent;
  Result.AutoSize := False;
  Result.WordWrap := True;
  Result.ShowAccelChar := False;
  Result.SetBounds(ScaleX(X), ScaleY(Y), ScaleX(W), ScaleY(H));
  Result.Caption := Text;
  Result.Font.Name := UiFont;
  Result.Font.Size := Size;
  Result.Font.Color := Color;
  if Bold then Result.Font.Style := [fsBold];
  Result.StyleElements := [];
end;

procedure PaintButton(Button: TBitmapButton; Bitmap: TBitmap;
  const Text: String; Primary, Enabled: Boolean);
var
  FillColor, TextColor: Integer;
begin
  Bitmap.Width := Button.Width;
  Bitmap.Height := Button.Height;
  { GDI drawing has no alpha channel. afDefined made the former UI transparent. }
  Bitmap.AlphaFormat := afIgnored;
  Bitmap.Canvas.Brush.Style := bsSolid;
  Bitmap.Canvas.Brush.Color := Background;
  Bitmap.Canvas.Pen.Color := Background;
  Bitmap.Canvas.Rectangle(0, 0, Bitmap.Width, Bitmap.Height);
  FillColor := Background;
  TextColor := Muted;
  if Primary then
  begin
    if Enabled then FillColor := Forest else FillColor := Outline;
    if Enabled then TextColor := clWhite else TextColor := Muted;
  end;
  Bitmap.Canvas.Brush.Color := FillColor;
  if Primary then Bitmap.Canvas.Pen.Color := FillColor
  else Bitmap.Canvas.Pen.Color := Outline;
  Bitmap.Canvas.RoundRect(1, 1, Bitmap.Width - 1, Bitmap.Height - 1,
    ScaleX(24), ScaleY(24));
  Bitmap.Canvas.Font.Name := UiFont;
  Bitmap.Canvas.Font.Size := 10;
  Bitmap.Canvas.Font.Color := TextColor;
  Bitmap.Canvas.Font.Style := [fsBold];
  Bitmap.Canvas.Brush.Style := bsClear;
  Bitmap.Canvas.TextOut(
    (Bitmap.Width - Bitmap.Canvas.TextWidth(Text)) div 2,
    (Bitmap.Height - Bitmap.Canvas.TextHeight(Text)) div 2 - ScaleY(1), Text);
  Button.Bitmap := Bitmap;
  Button.Caption := Text;
  Button.Enabled := Enabled;
  Button.Invalidate;
end;

function ButtonAt(Parent: TWinControl; X, Y, W, H: Integer;
  Handler: TNotifyEvent): TBitmapButton;
begin
  Result := TBitmapButton.Create(WizardForm);
  Result.Parent := Parent;
  Result.AutoSize := False;
  Result.SetBounds(ScaleX(X), ScaleY(Y), ScaleX(W), ScaleY(H));
  Result.BackColor := Background;
  Result.Cursor := crHand;
  Result.TabStop := True;
  Result.OnClick := Handler;
end;

procedure SetPrimary(const Text: String; Enabled: Boolean);
begin
  PaintButton(PrimaryButton, PrimaryBitmap, Text, True, Enabled);
  PrimaryButton.Visible := True;
end;

procedure UpdateSettings(Sender: TObject);
begin
  if not UiReady then exit;
  WizardForm.DirEdit.Text := DestinationEdit.Text;
  { The notice is shown through our link. Consent is enforced below and in
    NextButtonClick; the hidden native license page must not disable navigation. }
  if CurrentUiPage <> wpSelectDir then exit;
  SetPrimary(CustomMessage('PersonalInstallAction'),
    AgreementCheck.Checked and (Trim(DestinationEdit.Text) <> ''));
  FooterHint.Caption := 'v{#MyAppVersion}  ·  Windows 10 / 11  ·  x64';
#if MyPreview
  FooterHint.Caption := CustomMessage('PersonalPreview');
  PaintButton(PrimaryButton, PrimaryBitmap, CustomMessage('PersonalPreviewProgress'),
    True, PrimaryButton.Enabled);
#endif
end;

procedure BrowseClick(Sender: TObject);
begin
  WizardForm.DirEdit.Text := DestinationEdit.Text;
  WizardForm.DirBrowseButton.OnClick(WizardForm.DirBrowseButton);
  DestinationEdit.Text := WizardForm.DirEdit.Text;
  DestinationEdit.SelStart := 0;
  DestinationEdit.SelLength := 0;
end;

procedure NoticeClick(Sender: TObject);
var
  Dialog: TSetupForm;
  Memo: TNewMemo;
  CloseAction: TNewButton;
begin
  Dialog := CreateCustomForm(ScaleX(480), ScaleY(360), True, True);
  try
    Dialog.Caption := CustomMessage('PersonalNoticeTitle');
    Dialog.Color := Background;
    Dialog.Font.Name := UiFont;
    Dialog.Font.Size := 10;
    Dialog.Position := poOwnerFormCenter;
    Dialog.BorderStyle := bsDialog;
    Dialog.ClientWidth := ScaleX(480);
    Dialog.ClientHeight := ScaleY(360);
    Memo := TNewMemo.Create(Dialog);
    Memo.Parent := Dialog;
    Memo.SetBounds(ScaleX(20), ScaleY(20), ScaleX(440), ScaleY(278));
    Memo.ReadOnly := True;
    Memo.ScrollBars := ssVertical;
    Memo.WordWrap := True;
    Memo.Text := WizardForm.LicenseMemo.Text;
    Memo.Font.Name := UiFont;
    Memo.Font.Size := 9;
    Memo.Color := Background;
    Memo.BorderStyle := bsNone;
    CloseAction := TNewButton.Create(Dialog);
    CloseAction.Parent := Dialog;
    CloseAction.SetBounds(ScaleX(324), ScaleY(312), ScaleX(136), ScaleY(32));
    CloseAction.Caption := CustomMessage('PersonalNoticeClose');
    CloseAction.ModalResult := mrOk;
    CloseAction.Cancel := True;
    CloseAction.Default := True;
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

procedure ShowPersonalPage(PageID: Integer); forward;
procedure HideNativePresentation; forward;

procedure AdvanceNativeWizard;
begin
  { Native navigation checks button availability even when invoked by script. }
  WizardForm.NextButton.Visible := True;
  WizardForm.NextButton.Enabled := True;
  if WizardForm.NextButton.OnClick <> nil then
    WizardForm.NextButton.OnClick(WizardForm.NextButton);
  if CurrentUiPage <> wpPreparing then HideNativePresentation;
end;

procedure PrimaryClick(Sender: TObject);
begin
  if not PrimaryButton.Enabled then exit;
  Log('Personal installer action on page ' + IntToStr(CurrentUiPage));
#if MyPreview
  case CurrentUiPage of
    wpSelectDir:
      begin
        ShowPersonalPage(wpInstalling);
        exit;
      end;
    wpInstalling:
      begin
        ShowPersonalPage(wpFinished);
        exit;
      end;
    wpFinished:
      begin
        WizardForm.Close;
        exit;
      end;
  end;
#endif
  if CurrentUiPage = wpSelectDir then
  begin
    UpdateSettings(Sender);
    if not PrimaryButton.Enabled then exit;
    if DesktopCheck.Checked then WizardSelectTasks('desktopicon')
    else WizardSelectTasks('!desktopicon');
  end;
  if CurrentUiPage = wpFinished then
  begin
    if WizardForm.RunList.Items.Count > 0 then WizardForm.RunList.Checked[0] := True;
  end;
  AdvanceNativeWizard;
end;

procedure SecondaryClick(Sender: TObject);
begin
  if CurrentUiPage = wpFinished then
  begin
#if MyPreview
    WizardForm.Close;
#else
    if WizardForm.RunList.Items.Count > 0 then WizardForm.RunList.Checked[0] := False;
    AdvanceNativeWizard;
#endif
  end
  else if WizardForm.BackButton.OnClick <> nil then
    WizardForm.BackButton.OnClick(WizardForm.BackButton);
end;

procedure WizardKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  { Keep Tab/Space native, and make Enter work without bypassing consent. }
  if (Key = 13) and (Shift = []) and (CurrentUiPage <> wpPreparing) then
  begin
    Key := 0;
    if CloseActionButton.Focused then CloseActionClick(CloseActionButton)
    else if MinimizeActionButton.Focused then MinimizeActionClick(MinimizeActionButton)
    else if BrowseButton.Focused then BrowseClick(BrowseButton)
    else if NoticeButton.Focused then NoticeClick(NoticeButton)
    else if SecondaryButton.Focused and SecondaryButton.Visible then SecondaryClick(SecondaryButton)
    else if PrimaryButton.Visible and PrimaryButton.Enabled then PrimaryClick(PrimaryButton);
  end;
end;

procedure HideNativePresentation;
begin
  WizardForm.OuterNotebook.Visible := False;
  WizardForm.MainPanel.Visible := False;
  WizardForm.Bevel.Visible := False;
  WizardForm.Bevel1.Visible := False;
  WizardForm.BeveledLabel.Visible := False;
  WizardForm.NextButton.Visible := False;
  WizardForm.NextButton.TabStop := False;
  WizardForm.NextButton.Default := False;
  WizardForm.BackButton.Visible := False;
  WizardForm.BackButton.TabStop := False;
  WizardForm.CancelButton.Visible := False;
  WizardForm.CancelButton.TabStop := False;
end;

procedure ShowPersonalPage(PageID: Integer);
begin
  if not UiReady then exit;
  CurrentUiPage := PageID;
  HideNativePresentation;
  SettingsPanel.Visible := PageID = wpSelectDir;
  WizardForm.WizardBitmapImage.Visible := True;
  ProgressPanel.Visible := PageID = wpInstalling;
  FinishedPanel.Visible := PageID = wpFinished;
  PrimaryButton.Visible := False;
  SecondaryButton.Visible := False;
  NoticeButton.Visible := PageID = wpSelectDir;
  FooterHint.Caption := 'v{#MyAppVersion}  ·  Windows 10 / 11  ·  x64';
  case PageID of
    wpSelectDir:
      begin
        PageHeading.Caption := CustomMessage('PersonalSetupTitle');
        PageSubtitle.Caption := CustomMessage('PersonalSetupBody');
        DestinationEdit.Text := WizardForm.DirEdit.Text;
        DestinationEdit.SelStart := 0;
        DestinationEdit.SelLength := 0;
        DesktopCheck.Checked := WizardIsTaskSelected('desktopicon');
        SpaceHint.Caption := WizardForm.DiskSpaceLabel.Caption;
        UpdateSettings(nil);
      end;
    wpInstalling:
      begin
        PageHeading.Caption := CustomMessage('PersonalInstallingTitle');
        PageSubtitle.Caption := CustomMessage('PersonalInstallingBody');
        ProgressStatus.Caption := CustomMessage('PersonalCopying');
        ProgressPercent.Caption := '0%';
        ProgressFill.Width := 0;
#if MyPreview
        ProgressFill.Width := (ProgressTrack.Width * 68) div 100;
        ProgressPercent.Caption := '68%';
        SetPrimary(CustomMessage('PersonalPreviewFinish'), True);
#endif
      end;
    wpFinished:
      begin
        PageHeading.Caption := CustomMessage('PersonalSuccessTitle');
        PageSubtitle.Caption := CustomMessage('PersonalSuccessBody');
        FinishedPath.Caption := WizardDirValue;
        FinishedPath.Hint := WizardDirValue;
        FinishedPath.ShowHint := True;
        SetPrimary(CustomMessage('PersonalOpen'), True);
        PaintButton(SecondaryButton, SecondaryBitmap, CustomMessage('PersonalLater'), False, True);
        SecondaryButton.Visible := True;
        if WizardForm.RunList.Items.Count > 0 then WizardForm.RunList.Checked[0] := False;
#if MyPreview
        SetPrimary(CustomMessage('PersonalPreviewClose'), True);
        SecondaryButton.Visible := False;
#endif
      end;
    else
      begin
        { Keep real file-in-use, error, and restart controls visible. }
        PageHeading.Caption := CustomMessage('PersonalPreparingTitle');
        PageSubtitle.Caption := '';
        WizardForm.OuterNotebook.Parent := BrandPanel;
        WizardForm.OuterNotebook.SetBounds(0, ScaleY(104), ScaleX(424), ScaleY(158));
        WizardForm.InnerNotebook.Align := alClient;
        WizardForm.PreparingErrorBitmapImage.Visible := False;
        WizardForm.PreparingLabel.SetBounds(0, 0, ScaleX(424), ScaleY(32));
        WizardForm.PreparingMemo.SetBounds(0, ScaleY(34), ScaleX(424), ScaleY(82));
        WizardForm.PreparingMemo.ScrollBars := ssVertical;
        WizardForm.PreparingMemo.WordWrap := True;
        WizardForm.PreparingYesRadio.SetBounds(0, ScaleY(117), ScaleX(424), ScaleY(18));
        WizardForm.PreparingNoRadio.SetBounds(0, ScaleY(139), ScaleX(424), ScaleY(18));
        WizardForm.OuterNotebook.Visible := True;
        WizardForm.NextButton.Parent := BrandPanel;
        WizardForm.CancelButton.Parent := BrandPanel;
        WizardForm.NextButton.SetBounds(ScaleX(256), ScaleY(263), ScaleX(168), ScaleY(38));
        WizardForm.CancelButton.SetBounds(0, ScaleY(263), ScaleX(116), ScaleY(38));
        WizardForm.NextButton.Visible := True;
        WizardForm.NextButton.TabStop := True;
        WizardForm.NextButton.Default := True;
        WizardForm.CancelButton.Visible := True;
        WizardForm.CancelButton.TabStop := True;
        WizardForm.OuterNotebook.BringToFront;
        WizardForm.NextButton.BringToFront;
        WizardForm.CancelButton.BringToFront;
      end;
  end;
#if MyPreview
  FooterHint.Caption := CustomMessage('PersonalPreview');
  if PageID = wpSelectDir then
    PaintButton(PrimaryButton, PrimaryBitmap, CustomMessage('PersonalPreviewProgress'),
      True, PrimaryButton.Enabled);
#endif
end;

procedure DrawChromeButton(Button: TBitmapButton; Bitmap: TBitmap; IsClose: Boolean);
begin
  Bitmap.Width := Button.Width;
  Bitmap.Height := Button.Height;
  Bitmap.AlphaFormat := afIgnored;
  Bitmap.Canvas.Brush.Color := Background;
  Bitmap.Canvas.Pen.Color := Background;
  Bitmap.Canvas.Rectangle(0, 0, Bitmap.Width, Bitmap.Height);
  Bitmap.Canvas.Pen.Color := Muted;
  Bitmap.Canvas.Pen.Width := ScaleX(1);
  if IsClose then
  begin
    Bitmap.Canvas.MoveTo(ScaleX(10), ScaleY(9));
    Bitmap.Canvas.LineTo(ScaleX(20), ScaleY(19));
    Bitmap.Canvas.MoveTo(ScaleX(20), ScaleY(9));
    Bitmap.Canvas.LineTo(ScaleX(10), ScaleY(19));
  end
  else
  begin
    Bitmap.Canvas.MoveTo(ScaleX(10), ScaleY(17));
    Bitmap.Canvas.LineTo(ScaleX(20), ScaleY(17));
  end;
  Button.Bitmap := Bitmap;
end;

procedure InitializeWizard;
var
  InputFrame, InputSurface, SuccessTile: TPanel;
  LabelControl: TNewStaticText;
begin
  UiReady := False;
  { Unattended installs use Inno's own page lifecycle and command-line options. }
  if WizardSilent then exit;
  WizardForm.Caption := 'sohun · ' + CustomMessage('PersonalEdition');
  WizardForm.BorderStyle := bsNone;
  WizardForm.BorderIcons := [biSystemMenu, biMinimize];
  WizardForm.ClientWidth := ScaleX(480);
  WizardForm.ClientHeight := ScaleY(360);
  WizardForm.Position := poScreenCenter;
  WizardForm.Color := Background;
  WizardForm.Font.Name := UiFont;
  WizardForm.StyleElements := [];
  WizardForm.KeyPreview := True;
  WizardForm.OnKeyDown := @WizardKeyDown;
  WizardForm.OnResize := @ApplyWindowShape;
  ApplyWindowShape(nil);
  ChromeCallback := CreateCallback(@WindowChromeProc);
  SetWindowSubclass(WizardForm.Handle, ChromeCallback, 1, 0);

  CloseActionBitmap := TBitmap.Create;
  CloseActionButton := ButtonAt(WizardForm, 440, 6, 30, 28, @CloseActionClick);
  CloseActionButton.Caption := CustomMessage('CloseAction');
  CloseActionButton.Hint := CustomMessage('CloseHint');
  CloseActionButton.ShowHint := True;
  DrawChromeButton(CloseActionButton, CloseActionBitmap, True);
  MinimizeActionBitmap := TBitmap.Create;
  MinimizeActionButton := ButtonAt(WizardForm, 406, 6, 30, 28, @MinimizeActionClick);
  MinimizeActionButton.Caption := CustomMessage('PersonalMinimize');
  DrawChromeButton(MinimizeActionButton, MinimizeActionBitmap, False);

  BrandPanel := PanelAt(WizardForm, 28, 34, 424, 304, Background);
  WizardForm.WizardBitmapImage.Parent := BrandPanel;
  WizardForm.WizardBitmapImage.SetBounds(0, 0, ScaleX(46), ScaleY(46));
  WizardForm.WizardBitmapImage.Stretch := True;
  WizardForm.WizardBitmapImage.BackColor := Background;
  LabelAt(BrandPanel, 'sohun', 60, -2, 270, 33, 18, Ink, True);
  LabelAt(BrandPanel, CustomMessage('PersonalEdition'), 61, 31, 270, 19, 9, Muted, False);
  PageHeading := LabelAt(BrandPanel, '', 0, 70, 424, 30, 15, Ink, True);
  PageSubtitle := LabelAt(BrandPanel, '', 0, 106, 424, 25, 9, Muted, False);

  SettingsPanel := PanelAt(BrandPanel, 0, 144, 424, 106, Background);
  InputFrame := PanelAt(SettingsPanel, 0, 0, 424, 38, clWhite);
  RoundPanel(InputFrame, 10);
  InputSurface := PanelAt(InputFrame, 1, 1, 422, 36, Surface);
  RoundPanel(InputSurface, 9);
  DestinationEdit := TNewPathEdit.Create(WizardForm);
  DestinationEdit.Parent := InputSurface;
  DestinationEdit.AutoSize := False;
  DestinationEdit.SetBounds(ScaleX(10), ScaleY(8), ScaleX(332), ScaleY(22));
  DestinationEdit.BorderStyle := bsNone;
  DestinationEdit.Color := Surface;
  DestinationEdit.Font.Name := UiFont;
  DestinationEdit.Font.Size := 9;
  DestinationEdit.Font.Color := Ink;
  DestinationEdit.StyleElements := [];
  DestinationEdit.Text := WizardForm.DirEdit.Text;
  DestinationEdit.OnChange := @UpdateSettings;
  BrowseBitmap := TBitmap.Create;
  BrowseButton := ButtonAt(SettingsPanel, 350, 1, 72, 36, @BrowseClick);
  PaintButton(BrowseButton, BrowseBitmap, CustomMessage('PersonalBrowse'), False, True);
  SpaceHint := LabelAt(SettingsPanel, '', 0, 43, 424, 17, 8, Muted, False);
  DesktopCheck := TNewCheckBox.Create(WizardForm);
  DesktopCheck.Parent := SettingsPanel;
  DesktopCheck.SetBounds(0, ScaleY(64), ScaleX(424), ScaleY(20));
  DesktopCheck.Caption := CustomMessage('PersonalDesktopShortcut');
  DesktopCheck.Font.Size := 9;
  DesktopCheck.Font.Color := Muted;
  DesktopCheck.StyleElements := [];
  AgreementCheck := TNewCheckBox.Create(WizardForm);
  AgreementCheck.Parent := SettingsPanel;
  AgreementCheck.SetBounds(0, ScaleY(86), ScaleX(322), ScaleY(20));
  AgreementCheck.Caption := CustomMessage('PersonalAccept');
  AgreementCheck.Font.Size := 9;
  AgreementCheck.Font.Color := Muted;
  AgreementCheck.StyleElements := [];
  AgreementCheck.Checked := False;
  AgreementCheck.OnClick := @UpdateSettings;
  NoticeBitmap := TBitmap.Create;
  NoticeButton := ButtonAt(SettingsPanel, 336, 80, 88, 26, @NoticeClick);
  PaintButton(NoticeButton, NoticeBitmap, CustomMessage('PersonalReadNotice'), False, True);

  ProgressPanel := PanelAt(BrandPanel, 0, 155, 424, 92, Background);
  ProgressPercent := LabelAt(ProgressPanel, '0%', 0, 0, 424, 45, 27, Forest, True);
  ProgressPercent.Font.Name := 'Cascadia Code';
  ProgressTrack := PanelAt(ProgressPanel, 0, 55, 424, 6, Outline);
  RoundPanel(ProgressTrack, 3);
  ProgressFill := PanelAt(ProgressTrack, 0, 0, 0, 6, Accent);
  ProgressStatus := LabelAt(ProgressPanel, '', 0, 73, 424, 20, 9, Muted, False);

  FinishedPanel := PanelAt(BrandPanel, 0, 151, 424, 92, Background);
  SuccessTile := PanelAt(FinishedPanel, 0, 0, 32, 32, $00DDEED8);
  RoundPanel(SuccessTile, 16);
  LabelControl := LabelAt(SuccessTile, '✓', 0, 1, 32, 30, 17, Forest, True);
  LabelControl.Font.Name := 'Segoe UI';
  LabelControl.Alignment := taCenter;
  LabelAt(FinishedPanel, CustomMessage('PersonalInstalledTo'), 44, 6, 380, 23, 9, Muted, False);
  FinishedPath := LabelAt(FinishedPanel, '', 0, 47, 424, 42, 9, Muted, False);

  PrimaryBitmap := TBitmap.Create;
  PrimaryButton := ButtonAt(BrandPanel, 0, 263, 424, 38, @PrimaryClick);
  SecondaryBitmap := TBitmap.Create;
  SecondaryButton := ButtonAt(BrandPanel, 310, 229, 114, 26, @SecondaryClick);
  FooterHint := LabelAt(WizardForm, '', 28, 343, 424, 15, 8, Muted, False);
  FooterHint.Alignment := taCenter;
  WizardForm.YesRadio.Checked := True;
  WizardForm.NoRadio.Checked := False;
  WizardForm.LicenseAcceptedRadio.Checked := True;
  WizardForm.LicenseNotAcceptedRadio.Checked := False;
  UiReady := True;
  HideNativePresentation;
end;
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (not WizardSilent) and
    ((PageID = wpWelcome) or (PageID = wpLicense) or (PageID = wpSelectTasks));
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if WizardSilent then exit;
  if CurPageID = wpSelectDir then
  begin
    Result := AgreementCheck.Checked and (Trim(DestinationEdit.Text) <> '');
    if Result then WizardForm.DirEdit.Text := DestinationEdit.Text;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
#if MyPreview
  if ExpandConstant('{param:PREVIEWPAGE|{#MyPreviewPage}}') = 'progress' then
    ShowPersonalPage(wpInstalling)
  else if ExpandConstant('{param:PREVIEWPAGE|{#MyPreviewPage}}') = 'finished' then
    ShowPersonalPage(wpFinished)
  else
#endif
  ShowPersonalPage(CurPageID);
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
var
  Percent: Integer;
begin
  if not UiReady then exit;
  if MaxProgress <= 0 then exit;
  Percent := (Int64(CurProgress) * 100) div MaxProgress;
  ProgressPercent.Caption := IntToStr(Percent) + '%';
  ProgressFill.Width := (Int64(ProgressTrack.Width) * Percent) div 100;
  if Percent >= 100 then ProgressStatus.Caption := CustomMessage('PersonalFinalizing')
  else ProgressStatus.Caption := CustomMessage('PersonalCopying');
end;

procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  { Native cancellation preserves rollback, process cleanup and installer logs. }
  if CurPageID = wpFinished then
  begin
    if WizardForm.RunList.Items.Count > 0 then WizardForm.RunList.Checked[0] := False;
  end;
#if MyPreview
  Confirm := False;
#else
  if CurPageID <> wpInstalling then Confirm := False;
#endif
end;

#if MyPreview
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  NeedsRestart := False;
  Result := CustomMessage('PreviewBlocked');
end;
#endif

procedure DeinitializeSetup;
begin
  if ChromeCallback <> 0 then
    RemoveWindowSubclass(WizardForm.Handle, ChromeCallback, 1);
  if CloseActionBitmap <> nil then CloseActionBitmap.Free;
  if MinimizeActionBitmap <> nil then MinimizeActionBitmap.Free;
  if PrimaryBitmap <> nil then PrimaryBitmap.Free;
  if SecondaryBitmap <> nil then SecondaryBitmap.Free;
  if BrowseBitmap <> nil then BrowseBitmap.Free;
  if NoticeBitmap <> nil then NoticeBitmap.Free;
end;



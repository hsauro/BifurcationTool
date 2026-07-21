unit ufSimPlot;

{ Popup for a time-course / phase-plane view of a simulation. Holds the full run (time + every
  species) and lets the user choose the axes:
    X: a single combo -- 'time' or any species
    Y: a checkbox list -- any number of species overlaid
  So 'time' + species = a (multi-)time course; species-on-X + species-on-Y = a phase-plane
  trajectory. Works for any number of species. The eigenvalue readout sits on the right in a
  read-only (selectable, copyable) TMemo.

  The popup can also **re-run** the simulation at the same picked point with a different time span /
  point count, without going back to the main form (so you don't lose track of which point you
  clicked): the Sim time / Sim points boxes + Re-run call back into `FRerun`, a closure the host
  (ufMain.SimulateAtPoint) supplies that re-seeds RoadRunner at that point. `TSimRun` carries a
  whole run (data + title + eigenvalue subtitle); `TSimRerunFunc` produces one for a new span.

  This is a DESIGNED form (ufSimPlot.fmx) -- a CreateNew version broke styled-control rendering
  under the global style (the TMemo wouldn't paint at all). Entry point is ShowSimulation; each
  call creates and shows a fresh modeless popup that frees itself on close. }

interface

uses
  System.Classes, System.UITypes, System.SysUtils, System.Types,
  FMX.Forms, FMX.Types, FMX.Controls, FMX.Graphics, FMX.StdCtrls, FMX.ListBox,
  FMX.Layouts, FMX.Memo, FMX.Memo.Types, FMX.ScrollBox, FMX.Controls.Presentation,
  FMX.EditBox, FMX.NumberBox, SkPlotPaintBox, uPlotSeries, System.Skia,
  uPlotAnnotation, FMX.Skia, FMX.Edit;

type
  { A complete simulation run, ready to display: the trajectory plus the title/eigenvalue text. }
  TSimRun = record
    Ok: Boolean;                        // False => the run failed; the popup keeps its old data
    Title: string;
    SubTitle: string;                   // stability + eigenvalues (the memo readout)
    Times: TArray<Double>;
    Names: TArray<string>;              // species names, parallel to Data
    Data: TArray<TArray<Double>>;       // Data[species][timeIndex]
  end;

  { Re-run the same picked point over a new span/point count. Supplied by the host. }
  TSimRerunFunc = reference to function(TEnd: Double; NPoints: Integer): TSimRun;

  TSimForm = class(TForm)
    Top: TLayout;
    leftPanel: TLayout;                 // holds the X/Y axis pickers (Align=Left)
    lblX: TLabel;
    cbX: TComboBox;                     // X axis: single choice (time or a species)
    lblY: TLabel;
    lbY: TListBox;                      // Y axis: checkbox list of species
    rightPanel: TLayout;                // holds the re-run controls (Align=Right)
    lblSimT: TLabel;
    nbSimTime: TNumberBox;              // re-run: end time
    lblSimP: TLabel;
    nbSimPts: TNumberBox;               // re-run: number of points
    btnRerun: TButton;
    memInfo: TMemo;                     // eigenvalue / stability readout (read-only, copyable)
    plot: TSkPlotPaintBox;
    procedure FormCreate(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure ReplotEvent(Sender: TObject);
    procedure btnRerunClick(Sender: TObject);
  private
    FTimes: TArray<Double>;
    FNames: TArray<string>;
    FData: TArray<TArray<Double>>;
    FRerun: TSimRerunFunc;
    procedure PopulatePickers;
    procedure Replot;
  public
    procedure LoadRun(const Run: TSimRun; ATEnd: Double; ANPoints: Integer;
      const ARerun: TSimRerunFunc);
  end;

procedure ShowSimulation(const Run: TSimRun; ATEnd: Double; ANPoints: Integer;
  const Rerun: TSimRerunFunc);

var
  SimForm: TSimForm;   // designer link only; ShowSimulation creates its own instances

implementation

{$R *.fmx}

const
  Palette: array[0..6] of TAlphaColor = (
    TAlphaColors.Royalblue, TAlphaColors.Crimson,   TAlphaColors.Seagreen,
    TAlphaColors.Darkorange, TAlphaColors.Purple,   TAlphaColors.Teal,
    TAlphaColors.Sienna);

procedure TSimForm.FormCreate(Sender: TObject);
begin
  // A designed form without its own StyleBook falls back to the global TStyleManager style, which
  // is enough for correct rendering. Borrowing the main form's book too is belt-and-suspenders so
  // this popup always matches the rest of the app.
  if Assigned(Application.MainForm) then
    StyleBook := TForm(Application.MainForm).StyleBook;
end;

procedure TSimForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := TCloseAction.caFree;   // don't let popups accumulate until app exit
end;

procedure TSimForm.LoadRun(const Run: TSimRun; ATEnd: Double; ANPoints: Integer;
  const ARerun: TSimRerunFunc);
begin
  FRerun := ARerun;
  FTimes := Run.Times; FNames := Run.Names; FData := Run.Data;

  Caption := Run.Title;
  memInfo.Text := Run.SubTitle;
  nbSimTime.Value := ATEnd;
  nbSimPts.Value := ANPoints;
  btnRerun.Enabled := Assigned(FRerun);

  PopulatePickers;
  Replot;
end;

procedure TSimForm.PopulatePickers;
var
  I: Integer;
begin
  // X: 'time' (index 0) then each species (index I+1).
  cbX.Items.BeginUpdate;
  try
    cbX.Clear;
    cbX.Items.Add('time');
    for I := 0 to High(FNames) do cbX.Items.Add(FNames[I]);
  finally
    cbX.Items.EndUpdate;
  end;
  cbX.ItemIndex := 0;

  // Y: every species, all ticked by default.
  lbY.Clear;
  for I := 0 to High(FNames) do
  begin
    var It := TListBoxItem.Create(lbY);
    It.Parent := lbY;
    It.Text := FNames[I];
    It.Height := 20;
    It.IsChecked := True;
  end;
end;

procedure TSimForm.btnRerunClick(Sender: TObject);
var
  Run: TSimRun;
  NPoints: Integer;
begin
  if not Assigned(FRerun) then Exit;
  NPoints := Round(nbSimPts.Value);
  if NPoints < 2 then NPoints := 2;
  if nbSimTime.Value <= 0 then Exit;

  Run := FRerun(nbSimTime.Value, NPoints);
  if not Run.Ok then Exit;   // re-run failed: keep the current plot

  // Re-running is at the SAME point, so the species set is unchanged -- keep the user's current
  // X/Y axis selections and just swap in the new trajectory. Only repopulate if it somehow differs.
  FTimes := Run.Times; FNames := Run.Names; FData := Run.Data;
  Caption := Run.Title;
  memInfo.Text := Run.SubTitle;
  if (cbX.Count <> Length(FNames) + 1) or (lbY.Count <> Length(FNames)) then
    PopulatePickers;
  Replot;
end;

procedure TSimForm.ReplotEvent(Sender: TObject);
begin
  Replot;
end;

procedure TSimForm.Replot;
var
  Xi, K, Si, Ci: Integer;
  XData: TArray<Double>;
  S: TPlotSeries;
begin
  Xi := cbX.ItemIndex;
  if Xi <= 0 then XData := FTimes                        // 'time'
  else if (Xi - 1) <= High(FData) then XData := FData[Xi - 1]
  else XData := FTimes;

  plot.ClearSeries;
  Ci := 0;
  for Si := 0 to lbY.Count - 1 do
    if (Si <= High(FData)) and lbY.ListItems[Si].IsChecked then
    begin
      S := TPlotSeries.Create(FNames[Si], Palette[Ci mod Length(Palette)], False);
      S.LineVisible := True;
      S.LineWidth := 2;
      for K := 0 to High(FTimes) do
        S.AddXY(XData[K], FData[Si][K]);
      plot.AddSeries(S);
      Inc(Ci);
    end;

  if (Xi >= 0) and (Xi < cbX.Items.Count) then
  begin
    plot.XAxisTitle.Text := cbX.Items[Xi];
    plot.ChartTitle.Text := 'vs ' + cbX.Items[Xi];
  end;
  plot.YAxisTitle.Text := 'value';
  plot.AutoXScaling := True;
  plot.AutoYScaling := True;
  plot.Redraw;
end;

procedure ShowSimulation(const Run: TSimRun; ATEnd: Double; ANPoints: Integer;
  const Rerun: TSimRerunFunc);
var
  Frm: TSimForm;
begin
  Frm := TSimForm.Create(Application);   // loads the .fmx; frees itself on close (FormClose)
  Frm.LoadRun(Run, ATEnd, ANPoints, Rerun);
  Frm.Show;   // modeless, so the user can keep picking points
end;

end.

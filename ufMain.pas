unit ufMain;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  System.IOUtils, System.Threading, System.Diagnostics, System.StrUtils,
  System.Math, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, System.Skia,
  FMX.Controls.Presentation, FMX.StdCtrls, FMX.Edit, FMX.Memo, FMX.Memo.Types,
  FMX.ScrollBox, FMX.ListBox, FMX.Layouts,
  FMX.Styles,
  SkPlotPaintBox, FMX.Skia, uJuliaEngine, uJuliaPaths, uBifResult, uBifPlot,
  uPlotAnnotation, uPlotSeries, uAntimonyAPI, uCommonTypes, uModelConfig,
  uRoadRunner, uRoadRunner.API, uRR2DSimpleMatrix, ufSimPlot, FMX.EditBox,
  FMX.NumberBox;

type
  TfrmMain = class(TForm)
    Layout1: TLayout;
    SkPlotPaintBox1: TSkPlotPaintBox;
    Splitter1: TSplitter;
    Layout2: TLayout;
    memAntimony: TMemo;
    Layout3: TLayout;
    btnOpen: TButton;
    btnSave: TButton;
    lblExamples: TLabel;
    cboExamples: TComboBox;
    Layout4: TLayout;
    pnlBottom: TPanel;
    Label1: TLabel;
    grpTimeCourse: TGroupBox;
    lblTimeStart: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    nbTimeStart: TNumberBox;
    nbTimeEnd: TNumberBox;
    nbNumPoints: TNumberBox;
    btnSimulate: TButton;
    cboXAxis: TComboBox;
    lblTimeCoureSpecies: TListBox;
    GroupBox1: TGroupBox;
    lblParameter: TLabel;
    edParameter: TEdit;
    lblPMin: TLabel;
    edPMin: TEdit;
    edPMax: TEdit;
    lblPMax: TLabel;
    lblSpecies: TLabel;
    lbSpecies: TListBox;
    lblYMin: TLabel;
    edYMin: TEdit;
    edYMax: TEdit;
    lblYMax: TLabel;
    lblLabelCurve: TLabel;
    cbLabelCurve: TComboBox;
    lblStart: TLabel;
    edStart: TEdit;
    edDs: TEdit;
    lblDs: TLabel;
    lblDsMax: TLabel;
    edDsMax: TEdit;
    edMaxSteps: TEdit;
    lblMaxSteps: TLabel;
    lblSimTime: TLabel;
    edSimTime: TEdit;
    edPerturb: TEdit;
    lblPerturb: TLabel;
    lblSimPoints: TLabel;
    edSimPoints: TEdit;
    chkOverlay: TCheckBox;
    lblStatus: TLabel;
    btnCompute: TButton;
    btnSteadyState: TButton;
    SkLabel1: TSkLabel;
    StyleBook1: TStyleBook;
    btnAbout: TButton;
    btnClear: TButton;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure btnComputeClick(Sender: TObject);
    procedure btnSteadyStateClick(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure lbSpeciesChangeCheck(Sender: TObject);
    procedure edYLimitChange(Sender: TObject);
    procedure cbLabelCurveChange(Sender: TObject);
    procedure SkPlotPaintBox1ReportCoordinates(mousex, mousey, Worldx,
      Worldy: Single);
    procedure SkPlotPaintBox1PointPicked(Sender: TObject; Series: TPlotSeries;
      Index: Integer; DataX, DataY: Double);
    procedure lblTimeCoureSpeciesChangeCheck(Sender: TObject);
    procedure cboXAxisChange(Sender: TObject);
    procedure btnSimulateClick(Sender: TObject);
    procedure cboExamplesChange(Sender: TObject);
    procedure btnAboutClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
  private
    FEngine: TJuliaEngine;
    FResults: TList<TBifResult>;   // accumulated branches (>1 only in overlay mode)
    FBusy: Boolean;
    // A steady-state seed found by the "Find steady state" button. Used to seed the next
    // Compute (deterministic branch selection), but only while the model text + parameter it
    // was computed for still match, so an edited model doesn't reuse a stale seed.
    FSeedState: TArray<Double>;
    FSeedPValue: Double;
    FSeedModel, FSeedParam: string;
    FHasSeed: Boolean;
    // Records that the last "Find steady state" for these exact inputs failed to converge, so
    // Compute refuses (with a message) instead of silently auto-scanning. Cleared on a
    // successful steady state, on model load, or as soon as the inputs change.
    FSteadyFailed: Boolean;
    FSteadyFailedKey: string;
    // Native RoadRunner, used for steady state and (later) simulation -- no Julia round-trip.
    // FSimRR holds the model FSimSbml currently loaded; reloaded only when the SBML changes.
    FSimRR: TRoadRunner;
    FSimSbml: string;
    FRRReady: Boolean;
    FUpdatingSpecies: Boolean;   // suppress the check-changed redraw while repopulating lbSpecies
    // Last time-course run (Time Course groupbox). Held so the X/Y axis pickers can replot
    // without re-simulating. FSimData[species][timeIndex], parallel to FSimNames; FSimTimes is
    // column 0 of the run.
    FTCTimes: TArray<Double>;
    FTCNames: TArray<string>;
    FTCData: TArray<TArray<Double>>;
    FTCHasData: Boolean;
    // Signature of the [bifurcation] settings block last copied into the edit boxes. Used to
    // detect when a pasted/edited block differs from the fields (so we load it) vs. is unchanged
    // (so manual box edits win). See SyncBlockToFields.
    FLastAppliedBlock: string;
    procedure PopulateTimeCourseAxes(const Names: TArray<string>);
    procedure PlotTimeCourse;
    procedure LoadExample(const AText, AParam, APMin, APMax, AStart, ADs, ADsMax,
      AMaxSteps, ALabel: string);
    procedure CheckOnlySpecies(const Name: string);
    function EnsureSimModel(const Sbml: string): Boolean;
    function RunPointSim(const Br: TBifResult; SrcIdx: Integer;
      TEnd, Perturb: Double; NPoints: Integer): TSimRun;
    procedure SimulateAtPoint(const Br: TBifResult; SrcIdx: Integer);
    procedure SetStatus(const Msg: string);
    // Show a startup diagnostic AFTER the form is up. Never call ShowMessage directly from
    // FormCreate: a modal FMX dialog raised while the form is still being constructed access-
    // violates and kills the process silently (seen on a clean machine 2026-07-21, where the
    // "Julia not found"/version dialogs fired and took the app down instead of reporting).
    procedure QueueStartupMessage(const AMsg: string);
    procedure SetBusy(Value: Boolean);
    function BuildRequest: TBifRequest;
    function ModelSbml: string;
    function CurrentInputKey: string;
    procedure ApplyConfigToFields(Cfg: TModelConfig);
    procedure ExtractFieldsToConfig(Cfg: TModelConfig);
    function BifBlockSignature(Cfg: TModelConfig; out AnyPresent: Boolean): string;
    procedure SyncBlockToFields;
    procedure ApplyResult(const Res: TBifResult; WarmMs, SolveMs: Int64);
    procedure RedrawAll;
    procedure RunSelfTest;
  public
    { Append a line to <exedir>\startup.log. Diagnostic for install problems that only appear on a
      clean machine, where no debugger is available and a failure can kill the app before any UI
      exists. Never raises -- logging must not be able to break startup. }
    class procedure StartupLog(const S: string); static;
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.fmx}

const
  { Schloegl-style cubic: dX/dt = B - a3*X + a2*X^2 - a1*X^3. Folds at X=2.423 (B=24.39) and
    X=3.577 (B=23.61) -> hysteresis over B in [23,25]. }
  SchloeglModel =
    'J1: -> X;  B;'#13#10 +
    'J2: X -> ; a3*X;'#13#10 +
    'J3: -> X;  a2*X^2;'#13#10 +
    'J4: X -> ; a1*X^3;'#13#10#13#10 +
    'X = 1.7;'#13#10 + 'B = 23.0;'#13#10 +
    'a1 = 1.0;'#13#10 + 'a2 = 9.0;'#13#10 + 'a3 = 26.0;';

  { Brusselator: Hopf at B = 1 + A^2; with A=1, at B=2 (X=1, Y=2), no folds. }
  BrusselatorModel =
    'J1: -> X;   A;'#13#10 +
    'J2: X -> Y; B*X;'#13#10 +
    'J3: Y -> X; X^2*Y;'#13#10 +
    'J4: X -> ;  X;'#13#10#13#10 +
    'A = 1.0;'#13#10 + 'B = 1.0;'#13#10 + 'X = 1.0;'#13#10 + 'Y = 1.0;';

  { oscill8 FitzHugh-Nagumo-like model, ODEs written as one synthesis reaction per variable
    (SBML allows negative rates). Continue in a over [-1.5,1.5]: 2 folds + 1 Hopf. }
  Oscill8Model =
    'J1: -> x; x*(1-x)*(1+x) - y;'#13#10 +
    'J2: -> y; (x-a)*(b-y) - c;'#13#10#13#10 +
    'a = -0.5;'#13#10 + 'b = 0.5;'#13#10 + 'c = 0.1;'#13#10 +
    'x = 0;'#13#10 + 'y = 0;';

  { Tyson-Novak cell-cycle oscillator (from oscill8), ODEs as one reaction per variable.
    Stiff; continue in m over [-10,10]: 4 folds + 3 Hopfs. Needs the raised step defaults. }
  TysonModel =
    'R1: -> a; k5p + k5pp*(m*x)^n/(J5^n + (m*x)^n) - k6*a;'#13#10 +
    'R2: -> x; k1 - (k2p + k2pp*y)*x;'#13#10 +
    'R3: -> y; (k3p + k3pp*a)*(1 - y)/(J3 + 1 - y) - k4*m*x*y/(J4 + y);'#13#10#13#10 +
    'J3 = 0.04;'#13#10 + 'J4 = 0.04;'#13#10 + 'J5 = 0.3;'#13#10 +
    'k1 = 0.04;'#13#10 + 'k2p = 0.04;'#13#10 + 'k2pp = 1;'#13#10 +
    'k3p = 1;'#13#10 + 'k3pp = 10;'#13#10 + 'k4 = 35;'#13#10 +
    'k5p = 0.005;'#13#10 + 'k5pp = 0.2;'#13#10 + 'k6 = 0.1;'#13#10 +
    'm = 1;'#13#10 + 'n = 4;'#13#10 +
    'a = 1;'#13#10 + 'x = 1;'#13#10 + 'y = 1;';

  { Same Tyson model but initial conditions on the OTHER (high-x, low-y) steady state, so a
    continuation seeded here traces the upper branch. Used to demo overlay of both branches. }
  TysonHiModel =
    'R1: -> a; k5p + k5pp*(m*x)^n/(J5^n + (m*x)^n) - k6*a;'#13#10 +
    'R2: -> x; k1 - (k2p + k2pp*y)*x;'#13#10 +
    'R3: -> y; (k3p + k3pp*a)*(1 - y)/(J3 + 1 - y) - k4*m*x*y/(J4 + y);'#13#10#13#10 +
    'J3 = 0.04;'#13#10 + 'J4 = 0.04;'#13#10 + 'J5 = 0.3;'#13#10 +
    'k1 = 0.04;'#13#10 + 'k2p = 0.04;'#13#10 + 'k2pp = 1;'#13#10 +
    'k3p = 1;'#13#10 + 'k3pp = 10;'#13#10 + 'k4 = 35;'#13#10 +
    'k5p = 0.005;'#13#10 + 'k5pp = 0.2;'#13#10 + 'k6 = 0.1;'#13#10 +
    'm = 1;'#13#10 + 'n = 4;'#13#10 +
    'a = 2;'#13#10 + 'x = 1;'#13#10 + 'y = 0.02;';

  { Gray-Scott (one synthesis reaction per variable). Continue in F at k=0.04: the trivial state
    U=1,V=0 exists for all F, while the nontrivial states form a closed ISOLA over F in [0.01,0.16],
    disconnected from V=0 -- so it needs the overlay feature to show both. The ICs sit on the isola
    (near the F=0.08 nontrivial equilibrium), so a plain Compute traces the loop. A closed isola is
    maxSteps-limited (continuation just laps the loop, re-flagging specials) -> maxSteps=220, not the
    fold default 100000. To overlay the trivial branch: tick Overlay, set U=1;V=0, Compute again. }
  GrayScottModel =
    'J1: -> U;  F*(1 - U) - U*V^2;'#13#10 +
    'J2: -> V;  U*V^2 - (F + k)*V;'#13#10#13#10 +
    'F = 0.08;'#13#10 + 'k = 0.04;'#13#10 +
    'U = 0.3;'#13#10 + 'V = 0.5;';

  { Genuine Schlogl bistable reaction NETWORK: mass-action rates that match stoichiometry (the
    cubic term is a real trimolecular step 3X->..., not a first-order reaction with an X^3 rate).
    $A is chemostatted. Continue in kin over [20,28]: 2 folds (hysteresis) at ~23.6 and ~24.4. }
  SchloglNetModel =
    'R1: $A + 2 X -> 3 X;   k1*A*X^2;'#13#10 +
    'R2: 3 X -> $A + 2 X;   k2*X^3;'#13#10 +
    'R3: -> X;              kin;'#13#10 +
    'R4: X -> ;             k4*X;'#13#10#13#10 +
    'A = 9;'#13#10 + 'k1 = 1; k2 = 1; k4 = 26;'#13#10 + 'kin = 24;'#13#10 + 'X = 1;';

  { Edelstein bistable enzyme model: bimolecular autocatalysis (A+X<->2X, A the control parameter)
    plus enzyme sequestration (X+E<->C->E+B). E+C conserved. A small basal influx keeps the low
    state at X>0. Continue in A over [0,12]: 2 folds at ~0.84 and ~11.7. }
  EdelsteinModel =
    'R0: -> X;        kb;'#13#10 +
    'R1: X -> 2 X;    k1*A*X;'#13#10 +
    'R2: 2 X -> X;    km1*X^2;'#13#10 +
    'R3: X + E -> C;  k2*X*E;'#13#10 +
    'R4: C -> X + E;  km2*C;'#13#10 +
    'R5: C -> E;      k3*C;'#13#10#13#10 +
    'X = 0.2; E = 1; C = 0;'#13#10 +
    'A = 4; k1 = 1; km1 = 0.2; k2 = 50'#13#10 +
    'km2 = 1; k3 = 1; kb = 0.1;';

  { Covalent-modification cycle with positive feedback (Goldbeter-Koshland + feedback). R<->Rp,
    the kinase activated by its own product Rp; both steps Michaelis-Menten; R+Rp conserved.
    Continue in the basal signal k0 over [0,1.2]: 2 folds at ~0.26 and ~0.76. }
  CovalentModel =
    'J1: R -> Rp;  (k0 + kf*Rp)*R/(Km + R);'#13#10 +
    'J2: Rp -> R;  Vp*Rp/(Km + Rp);'#13#10#13#10 +
    'R = 1; Rp = 0;'#13#10 +
    'k0 = 0.5; kf = 1; Km = 0.02; Vp = 1;';

procedure TfrmMain.FormCreate(Sender: TObject);
var
  IsGrayScott: Boolean;
begin
  StartupLog('FormCreate: entry');
  TStyleManager.SetStyle(frmMain.StyleBook1);
  StartupLog('FormCreate: style set');

  IsGrayScott := False;
  if FindCmdLineSwitch('tyson', ['-', '/'], True) then
  begin
    memAntimony.Lines.Text := TysonModel;
    edParameter.Text := 'm'; edPMin.Text := '-10'; edPMax.Text := '10';
  end
  else if FindCmdLineSwitch('osc', ['-', '/'], True) then
  begin
    memAntimony.Lines.Text := Oscill8Model;
    edParameter.Text := 'a'; edPMin.Text := '-1.5'; edPMax.Text := '1.5';
  end
  else if FindCmdLineSwitch('hopf', ['-', '/'], True) then
  begin
    memAntimony.Lines.Text := BrusselatorModel;
    edParameter.Text := 'B'; edPMin.Text := '1.0'; edPMax.Text := '3.0';
  end
  else if FindCmdLineSwitch('grayscott', ['-', '/'], True) then
  begin
    memAntimony.Lines.Text := GrayScottModel;
    edParameter.Text := 'F'; edPMin.Text := '0'; edPMax.Text := '0.25';
    IsGrayScott := True;
  end
  else
  begin
    memAntimony.Lines.Text := SchloeglModel;
    edParameter.Text := 'B'; edPMin.Text := '0.1'; edPMax.Text := '45.0';
  end;

  // Continuation-parameter fields. Blank start = auto-scan. The step defaults match the
  // worker's (see uBifResult); shown here so the user can see and tune them.
  edStart.Text := '';
  edDs.Text := '0.001';
  edDsMax.Text := '0.005';
  edMaxSteps.Text := '100000';
  edSimTime.Text := '20';
  edPerturb.Text := '2';
  edSimPoints.Text := '500';

  // Gray-Scott's isola needs a seed on the loop and a step cap so the continuation doesn't just
  // lap it (see GrayScottModel); override the generic defaults above.
  if IsGrayScott then
  begin
    edStart.Text := '0.08'; edDs.Text := '0.0005'; edDsMax.Text := '0.002';
    edMaxSteps.Text := '220';
  end;

  // Example library (discoverable, vs the -switch demos). Order must match cboExamplesChange.
  cboExamples.Items.Clear;
  cboExamples.Items.AddStrings(['Schlogl (bistable network)', 'Gray-Scott (isola)',
    'Edelstein (bistable enzyme)', 'Covalent switch (+ feedback)', 'Brusselator (Hopf)',
    'Oscill8 (folds + Hopf)', 'Tyson-Novak (cell cycle)']);
  cboExamples.ItemIndex := -1;   // nothing preselected; the startup model stands until one is picked

  // Bring up the embedded Julia engine now, in the background. Its worker thread runs jl_init
  // + warm-up (~0.8 s with the sysimage) while the user reads the model, so the form is
  // responsive immediately and the first Compute is ~120 ms.
  FResults := TList<TBifResult>.Create;

  // Load libantimony in-process: the host converts Antimony->SBML and sends SBML to the worker,
  // so the Julia side never needs its own libantimony. Non-fatal here -- ModelSbml re-checks
  // DLLLoaded and reports per request if this failed.
  // Both native libraries live in julia\RoadRunner\src alongside their own dependencies (the MSVC
  // runtimes + zlib). A plain LoadLibrary resolves a module's dependencies against the EXE dir, not
  // against the loaded DLL's folder, so without this they'd be invisible on a machine with no
  // system-wide VC++ redistributable (error 126). Adding that folder to the search path keeps ONE
  // copy of each runtime in the install instead of duplicating them beside the exe.
  // (uJuliaEngine later calls SetDllDirectory again for the Julia bin; by then both are loaded.)
  StartupLog('FormCreate: before SetNativeDllSearchDir');
  SetNativeDllSearchDir(ExtractFilePath(ParamStr(0)) + 'julia\RoadRunner\src');
  StartupLog('FormCreate: dll search dir set');

  // Load libantimony from julia\RoadRunner\src -- ONE copy of the DLL in the install. RoadRunner.jl's
  // __init__ dlopens libantimony.dll from that same folder (BIFRR_LIBDIR) unconditionally, so the
  // file has to live there regardless; loading the host's copy from there too avoids shipping a
  // second, separately-versioned duplicate beside the exe. Same relative form as roadrunner_c_api.
  var AntErr := '';
  setAntimonyLibraryName('julia\RoadRunner\src\libantimony.dll');
  if not loadAntimonyLibrary(AntErr) then
    SetStatus('Antimony library failed to load: ' + AntErr);
  StartupLog('FormCreate: antimony load returned, err="' + AntErr + '"');

  // Load native libRoadRunner for steady state and simulation (no Julia round-trip). Point it
  // at the same DLL Julia uses (beside the exe, in julia\RoadRunner\src) so there's one module.
  TRoadRunnerAPI.SetLibraryName('julia\RoadRunner\src\roadrunner_c_api.dll');
  var RRErr: AnsiString := '';
  StartupLog('FormCreate: before loadRoadRunner');
  FRRReady := loadRoadRunner(RRErr);
  StartupLog('FormCreate: loadRoadRunner=' + BoolToStr(FRRReady, True) + ' err="' + string(RRErr) + '"');
  if not FRRReady then
  begin
    // Keep the reason visible: the status line gets overwritten by the engine-warm message a
    // moment later, which previously hid why simulation/steady-state were disabled.
    SetStatus('RoadRunner library failed to load: ' + string(RRErr));
    QueueStartupMessage('RoadRunner library failed to load from "' + TRoadRunnerAPI.LibName + '"' +
      sLineBreak + string(RRErr));
  end;

  try
    StartupLog('FormCreate: before ResolveJuliaPaths');
    var Paths := ResolveJuliaPaths;
    StartupLog(Format('FormCreate: paths bin="%s" proj="%s" sysimg="%s" req=%s det=%s depot="%s"',
      [Paths.BinDir, Paths.ProjectDir, Paths.SysImage, Paths.RequiredJulia, Paths.DetectedJulia,
       Paths.BundledDepot]));

    // Version gate: the sysimage (bifsys.dll) is locked to the Julia version it was built with.
    // Loading it under a different Julia can abort the whole process, so if the installed version
    // doesn't match, tell the user how to fix it and don't start the engine (the app still opens
    // for editing; Compute/Steady-state guard against a nil engine).
    if JuliaVersionMismatch(Paths) then
    begin
      var Msg := Format(
        'This build needs Julia %s, but the installed default is %s.' + sLineBreak + sLineBreak +
        'Install the matching version:' + sLineBreak +
        '    juliaup add %0:s' + sLineBreak +
        '    juliaup default %0:s' + sLineBreak + sLineBreak +
        'See README.md for the full setup. Bifurcation computation is disabled until then.',
        [Paths.RequiredJulia, Paths.DetectedJulia]);
      QueueStartupMessage(Msg);
      SetStatus(Format('Julia %s required, %s installed -- computation disabled (see README).',
        [Paths.RequiredJulia, Paths.DetectedJulia]));
      Exit;
    end;

    StartupLog('FormCreate: before TJuliaEngine.Create');
    FEngine := TJuliaEngine.Create(Paths.BinDir, Paths.ProjectDir, Paths.SysImage, {warmup=} True);
    StartupLog('FormCreate: engine created');
  except
    on E: EJuliaPaths do
    begin
      // Julia not found at all (no juliaup install / no julia\ beside the exe).
      QueueStartupMessage('Julia was not found.' + sLineBreak + sLineBreak + E.Message + sLineBreak +
        sLineBreak + 'See README.md to install Julia. Bifurcation computation is disabled until then.');
      SetStatus('Julia not found -- computation disabled (see README).');
      Exit;   // FEngine stays nil; Compute/Steady-state guard against it
    end;
    on E: Exception do
    begin
      StartupLog('FormCreate: engine EXCEPTION ' + E.ClassName + ': ' + E.Message);
      SetStatus('Cannot start Julia: ' + E.Message);
      Exit;   // FEngine stays nil; Compute/Steady-state guard against it
    end;
  end;

  StartupLog('FormCreate: starting warmup task');
  SetStatus('Starting embedded Julia in the background...');
  TTask.Run(
    procedure
    var
      Err: string;
    begin
      Err := '';
      StartupLog('warmup: WaitUntilReady begin');
      try
        FEngine.WaitUntilReady;
      except
        on E: Exception do Err := E.ClassName + ': ' + E.Message;
      end;
      StartupLog('warmup: WaitUntilReady end, err="' + Err + '"');
      TThread.Queue(nil,
        procedure
        begin
          if Err <> '' then
            SetStatus('Engine failed to start: ' + Err)
          else
            SetStatus(Format('Engine warm in %.1f s. Press Compute.', [FEngine.ReadySeconds]));
        end);
    end);
  StartupLog('FormCreate: exit');
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  FSimRR.Free;
  FEngine.Free;   // stops the worker thread, jl_atexit_hook on that thread
  FResults.Free;
end;

procedure TfrmMain.FormShow(Sender: TObject);
begin
  if FindCmdLineSwitch('selftest', ['-', '/'], True) then
    RunSelfTest;
end;

var
  GLogLock: TObject = nil;      // guards the log file (main thread + warmup task both write)
  GLogStarted: Boolean = False; // first write truncates, so the file is always one run

{ Where the startup log goes: %LOCALAPPDATA%\BifurcationTool\startup.log.

  NOT beside the exe -- a user who installs under Program Files gets a read-only folder there, so
  the log would silently never appear, exactly when it is most needed. LOCALAPPDATA is always
  writable and is the conventional spot. Falls back to %TEMP% if LOCALAPPDATA is somehow unset. }
function StartupLogFile: string;
var
  Dir: string;
begin
  Dir := GetEnvironmentVariable('LOCALAPPDATA');
  if Dir = '' then Dir := TPath.GetTempPath;
  Dir := TPath.Combine(Dir, 'BifurcationTool');
  if not TDirectory.Exists(Dir) then TDirectory.CreateDirectory(Dir);
  Result := TPath.Combine(Dir, 'startup.log');
end;

class procedure TfrmMain.StartupLog(const S: string);
var
  Line: string;
begin
  try
    Line := FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + S + sLineBreak;
    // Serialise: the warmup task logs from a worker thread while the main thread is still in
    // FormCreate. Without the lock, interleaved writes lost a line (seen 2026-07-21).
    TMonitor.Enter(GLogLock);
    try
      if not GLogStarted then
      begin
        GLogStarted := True;
        TFile.WriteAllText(StartupLogFile, '');   // one run per file, not an ever-growing log
      end;
      TFile.AppendAllText(StartupLogFile, Line);
    finally
      TMonitor.Exit(GLogLock);
    end;
  except
    // swallow: a diagnostic must never be able to break startup
  end;
end;

procedure TfrmMain.SetStatus(const Msg: string);
begin
  lblStatus.Text := Msg;
  lblStatus.Repaint;
end;

// Defer a startup diagnostic until the message loop is running and the form actually exists.
// ForceQueue always posts (never runs inline, even on the main thread), so this returns immediately
// during FormCreate and the dialog appears once the form is up. Calling ShowMessage directly from
// FormCreate access-violates -- it killed the app silently on a clean machine, turning a helpful
// "Julia was not found" message into an unexplained crash.
procedure TfrmMain.QueueStartupMessage(const AMsg: string);
begin
  TThread.ForceQueue(nil,
    procedure
    begin
      ShowMessage(AMsg);
    end);
end;

// Run a time-course simulation seeded from a picked branch point, natively (libRoadRunner, no
// Julia), and show it in a popup. Br.Species/Pt.U are the independent-species state; setting
// them + the parameter and simulating reproduces the dynamics at that point on the diagram.
// The actual RoadRunner work for one point: seed FSimRR at the equilibrium, read eigenvalues,
// nudge, integrate. Parameterized by TEnd/Perturb/NPoints so the same code serves the first show
// AND the popup's Re-run. Returns Ok=False (not an exception) on any failure.
function TfrmMain.RunPointSim(const Br: TBifResult; SrcIdx: Integer;
  TEnd, Perturb: Double; NPoints: Integer): TSimRun;
var
  M, EV: T2DMatrix;
  I, J, R, C: Integer;
  MaxRe, Re, Im: Double;
  HasComplex: Boolean;
  Stab, EigStr: string;
begin
  Result := Default(TSimRun);
  if not FRRReady then begin SetStatus('RoadRunner not available for simulation.'); Exit; end;
  var Pt := Br.Branch[SrcIdx];
  try
    if not EnsureSimModel(ModelSbml) then
    begin SetStatus('Could not load the model for simulation.'); Exit; end;

    FSimRR.reset;   // back to the model's initial conditions (and their conservation totals)
    FSimRR.setValue(AnsiString(Br.Parameter), Pt.P);
    for I := 0 to High(Pt.U) do
      if I <= High(Br.Species) then
        FSimRR.setValue(AnsiString(Br.Species[I]), Pt.U[I]);

    // Eigenvalues of the reduced Jacobian AT the equilibrium: they say what the nudged
    // trajectory will do -- max real part < 0 => relaxes back (stable), > 0 => runs away
    // (unstable); a non-zero imaginary part => it does so with oscillation.
    MaxRe := -1e300; HasComplex := False; EigStr := '';
    EV := FSimRR.getEigenvalues;
    try
      for I := 0 to EV.r - 1 do
      begin
        Re := EV[I, 0];
        if EV.c > 1 then Im := EV[I, 1] else Im := 0;
        if Re > MaxRe then MaxRe := Re;
        if Abs(Im) > 1e-9 then HasComplex := True;
        if I > 0 then EigStr := EigStr + ',   ';
        // Build the sign by hand: Delphi's Format has no '+' flag (that's C printf), and
        // '%+.4g' silently drops the whole argument -- which hid the imaginary part entirely.
        if Abs(Im) < 1e-9 then EigStr := EigStr + Format('%.4g', [Re])
        else if Im >= 0 then EigStr := EigStr + Format('%.4g + %.4gi', [Re, Im])
        else EigStr := EigStr + Format('%.4g - %.4gi', [Re, Abs(Im)]);
      end;
    finally
      EV.Free;
    end;
    if MaxRe < 0 then Stab := 'stable' else Stab := 'unstable';
    if HasComplex then Stab := Stab + ', oscillatory';

    // Nudge every species off the equilibrium. Without this an exact equilibrium just sits
    // still (a flat line) no matter its stability; with it, the stability above becomes visible.
    for I := 0 to High(Pt.U) do
      if I <= High(Br.Species) then
        FSimRR.setValue(AnsiString(Br.Species[I]), Pt.U[I] * (1 + Perturb));

    M := FSimRR.simulateEx(0, TEnd, NPoints);   // column 0 = time, 1.. = species
    try
      R := M.r; C := M.c;
      SetLength(Result.Times, R);
      for I := 0 to R - 1 do Result.Times[I] := M[I, 0];

      SetLength(Result.Names, C - 1);
      SetLength(Result.Data, C - 1);
      for J := 1 to C - 1 do
      begin
        if J < M.columnHeader.Count then Result.Names[J - 1] := M.columnHeader[J]
        else Result.Names[J - 1] := 'S' + IntToStr(J);
        SetLength(Result.Data[J - 1], R);
        for I := 0 to R - 1 do Result.Data[J - 1][I] := M[I, J];
      end;
    finally
      M.Free;
    end;

    Result.Title := Format('Simulation at %s = %.5g  (%s, +%g%% nudge)',
      [Br.Parameter, Pt.P, Stab, Perturb * 100]);
    Result.SubTitle := Format('%s  —  eigenvalues: %s', [Stab, EigStr]);
    Result.Ok := True;
  except
    on E: Exception do SetStatus('Simulation failed: ' + E.Message);
  end;
end;

procedure TfrmMain.SimulateAtPoint(const Br: TBifResult; SrcIdx: Integer);
var
  TEnd, Perturb: Double;
  NPoints: Integer;
begin
  if not FRRReady then begin SetStatus('RoadRunner not available for simulation.'); Exit; end;
  // Sim time span, perturbation and point count come from the form; fall back to sane defaults.
  // TEnd/NPoints are just the STARTING values -- the popup can re-run with its own.
  if not TryStrToFloat(edSimTime.Text.Trim, TEnd, TFormatSettings.Invariant) or (TEnd <= 0) then
    TEnd := 20.0;
  if not TryStrToFloat(edPerturb.Text.Trim, Perturb, TFormatSettings.Invariant) or (Perturb < 0) then
    Perturb := 2.0;
  Perturb := Perturb / 100.0;   // field is a percent
  if not TryStrToInt(edSimPoints.Text.Trim, NPoints) or (NPoints < 2) then
    NPoints := 500;

  // Capture the point + perturbation so the popup can re-run at the SAME point over a new span,
  // without the user going back to the main form (and losing which point they clicked).
  var LBr := Br; var LIdx := SrcIdx; var LPerturb := Perturb;
  var Rerun: TSimRerunFunc :=
    function(ATEnd: Double; ANPoints: Integer): TSimRun
    begin
      Result := RunPointSim(LBr, LIdx, ATEnd, LPerturb, ANPoints);
    end;

  var First := Rerun(TEnd, NPoints);
  if not First.Ok then Exit;   // RunPointSim already reported why
  ShowSimulation(First, TEnd, NPoints, Rerun);
  SetStatus('Simulation shown — adjust Sim time / Points in the popup and Re-run.');
end;

procedure TfrmMain.SkPlotPaintBox1PointPicked(Sender: TObject;
  Series: TPlotSeries; Index: Integer; DataX, DataY: Double);
var
  SrcIdx: Integer;
  ParamName: string;
begin
  // Always read out the clicked point's coordinates first. DataX/DataY are the on-curve DATA
  // values (the pick snaps to a plotted point), so this is the *precise* position of that
  // bifurcation-diagram point: the parameter value on X, the picked species' value on Y. This
  // used to be skipped for real branch points because the handler returned early to simulate.
  if (Series.Tag >= 0) and (Series.Tag < FResults.Count) then
    ParamName := FResults[Series.Tag].Parameter
  else
    ParamName := 'x';
  label1.Text := Format('%s = %.6g,   %s = %.6g', [ParamName, DataX, Series.Name, DataY]);

  // A pick that lands on a real branch point also seeds a simulation there.
  SrcIdx := Series.SourceTag(Index);
  if (SrcIdx >= 0) and (Series.Tag >= 0) and (Series.Tag < FResults.Count) then
  begin
    var Br := FResults[Series.Tag];
    if SrcIdx <= High(Br.Branch) then
      SimulateAtPoint(Br, SrcIdx);
  end;
end;

procedure TfrmMain.SkPlotPaintBox1ReportCoordinates(mousex, mousey, Worldx,
  Worldy: Single);
begin
  //label1.text := floattostr (Worldx) + ', ' + floattostr (Worldy);
end;

procedure TfrmMain.SetBusy(Value: Boolean);
begin
  FBusy := Value;
  btnSteadyState.Enabled := not Value;
  if not Value then
  begin
    btnCompute.Enabled := True;
    btnCompute.Text := 'Compute';
  end
  // While a solve runs, the Compute button doubles as Cancel (if the worker supports interrupting);
  // a second click stops the continuation. Older workers can't cancel, so it just disables.
  else if Assigned(FEngine) and FEngine.CanCancel then
  begin
    btnCompute.Enabled := True;
    btnCompute.Text := 'Cancel';
  end
  else
  begin
    btnCompute.Enabled := False;
    btnCompute.Text := 'Working...';
  end;
end;

function TfrmMain.ModelSbml: string;
// Convert the Antimony in memAntimony to SBML using the in-process libantimony, so the Julia
// worker only ever sees SBML (its own bundled libantimony is x86_64-only and no longer needed).
// Raises on conversion failure so callers surface the message the same way as other bad input.
var
  MES: TModelErrorState;
begin
  if not DLLLoaded then
    raise Exception.Create('Antimony library not loaded; cannot convert the model to SBML.');
  MES := getSBMLFromAntimony(AnsiString(memAntimony.Lines.Text));
  if not MES.ok then
    raise Exception.Create('Antimony error: ' + string(MES.errMsg));
  Result := string(MES.sbmlStr);
end;

// A signature of the inputs a run depends on. Used to tell whether a recorded steady-state
// failure still applies (same model + parameter + start) or is stale because the user changed
// something.
function TfrmMain.CurrentInputKey: string;
begin
  Result := memAntimony.Lines.Text + #1 + edParameter.Text.Trim + #1 + edStart.Text.Trim;
end;

function TfrmMain.BuildRequest: TBifRequest;
var
  FS: TFormatSettings;
  PMin, PMax, D: Double;
  I: Integer;
begin
  FS := TFormatSettings.Invariant;
  // Validate the cheap, host-side things first, with messages a modeler can act on, before
  // touching libantimony or Julia.
  if Trim(memAntimony.Lines.Text) = '' then
    raise Exception.Create('The model is empty — enter or open a model first.');
  if edParameter.Text.Trim = '' then
    raise Exception.Create('Enter the parameter to vary (the Parameter field is empty).');
  if not TryStrToFloat(edPMin.Text, PMin, FS) then
    raise Exception.Create('Range start is not a number: ' + edPMin.Text);
  if not TryStrToFloat(edPMax.Text, PMax, FS) then
    raise Exception.Create('Range end is not a number: ' + edPMax.Text);
  if PMin >= PMax then
    raise Exception.CreateFmt('Range start (%s) must be less than range end (%s).',
      [edPMin.Text.Trim, edPMax.Text.Trim]);

  Result := TBifRequest.Create(ModelSbml, edParameter.Text.Trim, PMin, PMax);

  // Optional overrides. Each keeps the TBifRequest.Create default if its field is blank or
  // not a valid number, so a half-filled form still runs.
  if edStart.Text.Trim <> '' then
  begin
    if not TryStrToFloat(edStart.Text, D, FS) then
      raise Exception.Create('Start value is not a number: ' + edStart.Text);
    if (D < PMin) or (D > PMax) then
      raise Exception.CreateFmt('Start value (%s) must lie within the range [%s, %s].',
        [edStart.Text.Trim, edPMin.Text.Trim, edPMax.Text.Trim]);
    Result.PStart := D;
    Result.HasPStart := True;
  end;
  if TryStrToFloat(edDs.Text, D, FS) then Result.Ds := D;
  if TryStrToFloat(edDsMax.Text, D, FS) then Result.DsMax := D;
  if TryStrToInt(edMaxSteps.Text, I) then Result.MaxSteps := I;

  // If the "Find steady state" button produced a seed for THIS model+parameter, use it: seed
  // the continuation directly from that steady state (deterministic branch selection) at the
  // value it was computed for. Only when the user left Start blank (an explicit Start value wins)
  // AND the seed's parameter value is inside the current range -- otherwise the seed is stale
  // (e.g. found at the model's default, then the range was changed) and would force an
  // out-of-range pStart that the worker rejects.
  if FHasSeed and (FSeedModel = memAntimony.Lines.Text) and
     SameText(FSeedParam, edParameter.Text.Trim) and (Length(FSeedState) > 0) and
     (edStart.Text.Trim = '') and (FSeedPValue >= PMin) and (FSeedPValue <= PMax) then
  begin
    Result.StartState := FSeedState;
    Result.HasStartState := True;
    Result.PStart := FSeedPValue;
    Result.HasPStart := True;
  end;
end;

procedure TfrmMain.ApplyResult(const Res: TBifResult; WarmMs, SolveMs: Int64);
var
  I, Sel: Integer;
  Prev: string;
begin
  if not Res.Ok then
  begin
    // A failed run neither clears the accumulated branches nor the plot -- so a bad request
    // after some good ones doesn't wipe your diagram. Just report it.
    SetStatus('Failed: ' + Res.Error);
    Exit;
  end;

  // Overlay off => this replaces the diagram; on => it adds another branch.
  if not chkOverlay.IsChecked then
    FResults.Clear;
  FResults.Add(Res);

  // Repopulate the checkable species list, preserving which species were ticked. On the first
  // result nothing is ticked yet, so default to just the first species.
  var PrevChecked := TStringList.Create;
  FUpdatingSpecies := True;
  try
    var HadAny := lbSpecies.Count > 0;
    for I := 0 to lbSpecies.Count - 1 do
      if lbSpecies.ListItems[I].IsChecked then PrevChecked.Add(lbSpecies.ListItems[I].Text);

    lbSpecies.Clear;
    for I := 0 to High(Res.Species) do
    begin
      var It := TListBoxItem.Create(lbSpecies);
      It.Parent := lbSpecies;
      It.Text := Res.Species[I];
      It.Height := 22;
      if HadAny then It.IsChecked := PrevChecked.IndexOf(Res.Species[I]) >= 0
      else It.IsChecked := (I = 0);
    end;

    var AnyChecked := False;
    for I := 0 to lbSpecies.Count - 1 do
      if lbSpecies.ListItems[I].IsChecked then AnyChecked := True;
    if (not AnyChecked) and (lbSpecies.Count > 0) then
      lbSpecies.ListItems[0].IsChecked := True;
  finally
    PrevChecked.Free;
    FUpdatingSpecies := False;
  end;

  // Populate the "labels on" selector: (none), (all), then each species. Keep the choice if it
  // still exists, else default to the first species (one labelled curve, as before).
  FUpdatingSpecies := True;
  try
    var PrevLabel := '';
    if cbLabelCurve.ItemIndex >= 0 then PrevLabel := cbLabelCurve.Items[cbLabelCurve.ItemIndex];
    cbLabelCurve.Items.BeginUpdate;
    try
      cbLabelCurve.Clear;
      cbLabelCurve.Items.Add('(none)');
      cbLabelCurve.Items.Add('(all)');
      for I := 0 to High(Res.Species) do
        cbLabelCurve.Items.Add(Res.Species[I]);
    finally
      cbLabelCurve.Items.EndUpdate;
    end;
    var Li := cbLabelCurve.Items.IndexOf(PrevLabel);
    if (Li < 0) and (Length(Res.Species) > 0) then
      Li := cbLabelCurve.Items.IndexOf(Res.Species[0]);
    if Li < 0 then Li := 0;
    cbLabelCurve.ItemIndex := Li;
  finally
    FUpdatingSpecies := False;
  end;

  RedrawAll;

  var Prefix := '';
  if Res.Cancelled then Prefix := 'Cancelled — partial branch. ';
  SetStatus(Format('%s%d points, %d fold(s), %d Hopf(s). solve %d ms  (%d branch(es) shown)',
    [Prefix, Length(Res.Branch), Length(Res.Folds), Length(Res.Hopfs), SolveMs, FResults.Count]));
end;

const
  // One colour per plotted species; stability is shown by line style (solid/dashed).
  SpeciesPalette: array[0..6] of TAlphaColor = (
    TAlphaColors.Royalblue, TAlphaColors.Crimson,  TAlphaColors.Seagreen,
    TAlphaColors.Darkorange, TAlphaColors.Purple,  TAlphaColors.Teal,
    TAlphaColors.Sienna);

procedure TfrmMain.RedrawAll;
{ Replay every accumulated branch onto the (cleared) plot for each TICKED species. Each species
  gets its own colour; overlay branches get a b<N>: label prefix. Special points (LP/H) are
  drawn once (for the first ticked species) so overlays don't stack duplicate markers/labels. }
var
  I, Idx, Ci: Integer;
  Prefix: string;
begin
  SkPlotPaintBox1.ClearSeries;
  SkPlotPaintBox1.ClearAnnotations;

  if FResults.Count = 0 then
  begin
    SkPlotPaintBox1.Redraw;
    Exit;
  end;

  // Which curve(s) carry the LP/H text labels, from the combo: (all), (none), or a species name.
  var LabelSel := '';
  if cbLabelCurve.ItemIndex >= 0 then LabelSel := cbLabelCurve.Items[cbLabelCurve.ItemIndex];

  Ci := 0;
  for var Sp := 0 to lbSpecies.Count - 1 do
  begin
    if not lbSpecies.ListItems[Sp].IsChecked then Continue;
    var SN := lbSpecies.ListItems[Sp].Text;
    var Col := SpeciesPalette[Ci mod Length(SpeciesPalette)];
    var ShowLbl := (LabelSel = '(all)') or SameText(SN, LabelSel);   // '(none)'/'' => False
    for I := 0 to FResults.Count - 1 do
    begin
      Idx := FResults[I].IndexOfSpecies(SN);
      if Idx < 0 then Continue;
      if FResults.Count > 1 then Prefix := Format('b%d:', [I + 1]) else Prefix := '';
      AddBifurcationSeries(SkPlotPaintBox1, FResults[I], Idx, {ShowLegend=} I = 0, Prefix,
                           {ABranchTag=} I, Col, {AShowSpecial=} ShowLbl, {AFirstSpecies=} Ci = 0);
    end;
    Inc(Ci);
  end;

  // Manual Y limits: either field on its own pins that side (the other stays auto, passed to the
  // plot as NaN); both filled must have min < max or they're ignored. Done AFTER the loop because
  // AddBifurcationSeries turns AutoYScaling back on for each series it adds.
  var YMin, YMax: Double;
  var HasMin := TryStrToFloat(edYMin.Text.Trim, YMin, TFormatSettings.Invariant);
  var HasMax := TryStrToFloat(edYMax.Text.Trim, YMax, TFormatSettings.Invariant);
  if HasMin and HasMax and (YMin >= YMax) then begin HasMin := False; HasMax := False; end;
  if HasMin or HasMax then
  begin
    SkPlotPaintBox1.AutoYScaling := False;
    if HasMin then SkPlotPaintBox1.AxisLimits.MinY := YMin else SkPlotPaintBox1.AxisLimits.MinY := NaN;
    if HasMax then SkPlotPaintBox1.AxisLimits.MaxY := YMax else SkPlotPaintBox1.AxisLimits.MaxY := NaN;
  end
  else
    SkPlotPaintBox1.AutoYScaling := True;

  SkPlotPaintBox1.Redraw;
end;

procedure TfrmMain.btnAboutClick(Sender: TObject);
begin
  showmessage ('BifurcationTool: Version 1 (July, 2026). Supported by the Center for Reproducible Biomedical Modeling. Calculations done by Julia BifurcationKit.jl, Running libroadrunner: ' + TRoadRunner.getVersionStr);
end;

procedure TfrmMain.btnClearClick(Sender: TObject);
begin
  // Blank slate: wipe the model text and the plot, and drop every bit of cached state that could
  // otherwise linger (bifurcation branches, the time-course trajectory, the steady-state seed).
  memAntimony.Lines.Clear;

  // Bifurcation diagram: branches + species/label pickers, then repaint the (now empty) plot.
  FResults.Clear;
  FUpdatingSpecies := True;
  try
    lbSpecies.Clear;
    cbLabelCurve.Clear;
    cboXAxis.Clear;
    lblTimeCoureSpecies.Clear;
  finally
    FUpdatingSpecies := False;
  end;

  // Time-course cache so a stray picker event can't replot the old run.
  FTCHasData := False;
  FTCTimes := nil;
  FTCNames := nil;
  FTCData := nil;

  RedrawAll;   // FResults empty => clears series/annotations and paints a blank plot

  // Seeds/flags: nothing to reuse now that the model is gone.
  FHasSeed := False;
  FSteadyFailed := False;
  FLastAppliedBlock := '';

  SetStatus('Cleared.');
end;

procedure TfrmMain.btnComputeClick(Sender: TObject);
var
  Req: TBifRequest;
begin
  if FBusy then
  begin
    // Second click during a solve = Cancel. The running task returns a partial branch and
    // "cancelled":true; SetBusy(False) restores the button when it lands.
    if Assigned(FEngine) then FEngine.Cancel;
    btnCompute.Enabled := False;          // guard against a double-cancel until the task finishes
    btnCompute.Text := 'Cancelling...';
    SetStatus('Cancelling the continuation...');
    Exit;
  end;
  if not Assigned(FEngine) then begin SetStatus('Julia engine not available.'); Exit; end;

  // Honour a pasted/edited settings block: copy it into the fields first if it changed. Otherwise
  // a model pasted into the editor would compute with the previous model's box values.
  SyncBlockToFields;

  // If the last steady-state search for these exact inputs failed, don't quietly auto-scan --
  // tell the user, so they fix the start/initial conditions rather than get a puzzling result.
  // Any change to the model, parameter or Start value clears this (the key stops matching).
  if FSteadyFailed and (FSteadyFailedKey = CurrentInputKey) then
  begin
    SetStatus('No steady state was found for "' + edParameter.Text.Trim +
      '" at these settings. Adjust the Start value or the model''s initial conditions and run ' +
      '"Find steady state" again before computing (or change a setting to auto-scan).');
    Exit;
  end;

  try
    Req := BuildRequest;
  except
    on E: Exception do begin SetStatus('Failed: ' + E.Message); Exit; end;
  end;

  SetBusy(True);
  SetStatus('Solving...');

  // Off the UI thread: RunBifurcationSync blocks the caller (it marshals onto the engine's
  // Julia thread and waits). The first call may also wait for warm-up to finish.
  TTask.Run(
    procedure
    var
      Res: TBifResult;
      Err: string;
      SWWarm, SWSolve: TStopwatch;
      Json: string;
    begin
      Err := '';
      Res := Default(TBifResult);
      SWWarm := TStopwatch.StartNew;
      FEngine.WaitUntilReady;               // returns instantly once warm
      SWWarm.Stop;
      SWSolve := TStopwatch.StartNew;
      try
        Json := FEngine.RunBifurcationSync(Req.ToJson);
        Res := ParseBifResult(Json);
      except
        on E: Exception do Err := E.Message;
      end;
      SWSolve.Stop;

      TThread.Queue(nil,
        procedure
        begin
          SetBusy(False);
          if Err <> '' then
            SetStatus('Failed: ' + Err)
          else
            ApplyResult(Res, SWWarm.ElapsedMilliseconds, SWSolve.ElapsedMilliseconds);
        end);
    end);
end;

function TfrmMain.EnsureSimModel(const Sbml: string): Boolean;
// Load Sbml into the persistent native RoadRunner, reusing the instance and skipping the load
// when the SBML is unchanged -- loading is the costly step; setValue/steadyState/simulate aren't.
begin
  Result := False;
  if not FRRReady then Exit;
  if (FSimRR <> nil) and (FSimSbml = Sbml) then Exit(True);
  if FSimRR = nil then FSimRR := TRoadRunner.Create;
  if not FSimRR.loadSBMLFromString(Sbml) then
    raise Exception.Create('RoadRunner could not load the model: ' + FSimRR.getLastError);
  // Conserved-moiety reduction, matching the continuation, so a seed produced here is a valid
  // equilibrium of the same reduced system BifurcationKit continues.
  FSimRR.setComputeAndAssignConservationLaws(True);
  FSimSbml := Sbml;
  Result := True;
end;

procedure TfrmMain.btnSteadyStateClick(Sender: TObject);
{ Compute the steady state natively (libRoadRunner, no Julia) at the Start value (or the model's
  own parameter value if Start is blank). Show it, and -- if it converged -- keep it as the seed
  for the next Compute so the continuation starts from a known branch. }
var
  Sbml, Param, Desc: string;
  Pval, Resid, D: Double;
  FS: TFormatSettings;
  Sids, Params: TStringList;
  Rates: TArray<Double>;
  State: TArray<Double>;
  Solved: Boolean;
  K: Integer;
begin
  if FBusy then Exit;
  if not FRRReady then begin SetStatus('RoadRunner not available.'); Exit; end;
  FS := TFormatSettings.Invariant;
  Param := edParameter.Text.Trim;
  if Param = '' then begin SetStatus('Enter the parameter to vary.'); Exit; end;

  var SubmittedKey := CurrentInputKey;
  SetStatus('Finding steady state...');
  try
    Sbml := ModelSbml;                        // native Antimony->SBML
    if not EnsureSimModel(Sbml) then
    begin SetStatus('Could not load the model into RoadRunner.'); Exit; end;

    Params := FSimRR.getGlobalParameterIds;
    try
      if Params.IndexOf(Param) < 0 then
      begin
        FSteadyFailed := True; FSteadyFailedKey := SubmittedKey;
        SetStatus(Format('"%s" is not a parameter of this model. Available: %s',
          [Param, Params.CommaText]));
        Exit;
      end;
    finally
      Params.Free;
    end;

    if edStart.Text.Trim <> '' then
    begin
      if not TryStrToFloat(edStart.Text, D, FS) then
      begin SetStatus('Start value is not a number: ' + edStart.Text); Exit; end;
      Pval := D;
    end
    else
      Pval := FSimRR.getValue(AnsiString(Param));
    FSimRR.setValue(AnsiString(Param), Pval);

    Solved := True;
    try
      FSimRR.steadyState;
    except
      Solved := False;   // report it; state is left at the solver's best effort
    end;

    Sids := FSimRR.getFloatingSpeciesIds;   // full floating-species vector, seed order
    try
      SetLength(State, Sids.Count);
      Desc := '';
      for K := 0 to Sids.Count - 1 do
      begin
        State[K] := FSimRR.getValue(AnsiString(Sids[K]));
        if K > 0 then Desc := Desc + ', ';
        Desc := Desc + Format('%s=%.4g', [Sids[K], State[K]]);
      end;
    finally
      Sids.Free;
    end;

    Rates := FSimRR.getRatesOfChange;
    Resid := 0;
    for K := 0 to High(Rates) do Resid := Resid + Rates[K] * Rates[K];
    Resid := Sqrt(Resid);

    if Solved and (Resid < 1e-6) then
    begin
      FSeedState := State;
      FSeedPValue := Pval;
      FSeedModel := memAntimony.Lines.Text;
      FSeedParam := Param;
      FHasSeed := True;
      FSteadyFailed := False;
      SetStatus(Format('Steady state at %s=%.4g:  %s  (r=%.1e). Seed set — press Compute.',
        [Param, Pval, Desc, Resid]));
    end
    else
    begin
      FHasSeed := False;
      FSteadyFailed := True; FSteadyFailedKey := SubmittedKey;
      SetStatus(Format('Steady state at %s=%.4g did NOT converge:  %s  (r=%.1e). ' +
        'Adjust the initial conditions or Start value.', [Param, Pval, Desc, Resid]));
    end;
  except
    on E: Exception do
    begin
      FSteadyFailed := True; FSteadyFailedKey := SubmittedKey;
      SetStatus('Steady state failed: ' + E.Message);
    end;
  end;
end;

// Map the [bifurcation] section <-> the edit fields. Uses each field's current text as the
// default, so a model file that omits a key just leaves that field unchanged. Values are kept
// as raw text (SetStr), so the modeler's exact input and any notes are preserved on save.
procedure TfrmMain.ApplyConfigToFields(Cfg: TModelConfig);
const S = 'bifurcation';
begin
  edParameter.Text := Cfg.GetStr(S, 'parameter', edParameter.Text);
  edPMin.Text      := Cfg.GetStr(S, 'min',       edPMin.Text);
  edPMax.Text      := Cfg.GetStr(S, 'max',       edPMax.Text);
  edStart.Text     := Cfg.GetStr(S, 'start',     edStart.Text);
  edDs.Text        := Cfg.GetStr(S, 'ds',        edDs.Text);
  edDsMax.Text     := Cfg.GetStr(S, 'dsMax',     edDsMax.Text);
  edMaxSteps.Text  := Cfg.GetStr(S, 'maxSteps',  edMaxSteps.Text);
  // Y limits fall back to BLANK (auto-scale), not the current field, so loading a model that
  // doesn't specify them clears any limits left over from the previous model.
  edYMin.Text      := Cfg.GetStr(S, 'ymin',      '');
  edYMax.Text      := Cfg.GetStr(S, 'ymax',      '');
end;

procedure TfrmMain.ExtractFieldsToConfig(Cfg: TModelConfig);
const S = 'bifurcation';
begin
  Cfg.SetStr(S, 'parameter', edParameter.Text.Trim);
  Cfg.SetStr(S, 'min',       edPMin.Text.Trim);
  Cfg.SetStr(S, 'max',       edPMax.Text.Trim);
  Cfg.SetStr(S, 'start',     edStart.Text.Trim);
  Cfg.SetStr(S, 'ds',        edDs.Text.Trim);
  Cfg.SetStr(S, 'dsMax',     edDsMax.Text.Trim);
  Cfg.SetStr(S, 'maxSteps',  edMaxSteps.Text.Trim);
  Cfg.SetStr(S, 'ymin',      edYMin.Text.Trim);
  Cfg.SetStr(S, 'ymax',      edYMax.Text.Trim);
end;

// A stable fingerprint of the [bifurcation] block's values. AnyPresent is False when the text has
// no such keys at all (a plain model with no settings block) -- in that case there is nothing to
// sync, so we leave the boxes alone. A sentinel default distinguishes "key absent" from "key blank".
function TfrmMain.BifBlockSignature(Cfg: TModelConfig; out AnyPresent: Boolean): string;
const
  SENT = #1;
  KEYS: array[0..8] of string =
    ('parameter', 'min', 'max', 'start', 'ds', 'dsMax', 'maxSteps', 'ymin', 'ymax');
var
  K, V: string;
begin
  Result := '';
  AnyPresent := False;
  for K in KEYS do
  begin
    V := Cfg.GetStr('bifurcation', K, SENT);
    if V <> SENT then AnyPresent := True;
    Result := Result + K + '=' + V + #10;
  end;
end;

// If the model text carries a [bifurcation] block that DIFFERS from the one we last applied (i.e.
// the user pasted or hand-edited a new spec), copy it into the edit boxes before we act on them.
// Gated on "changed since last applied" so manual box tweaks aren't clobbered when the block is
// unchanged. This is what makes a pasted model's settings actually take effect on Compute AND
// survive a Save round-trip, instead of the stale boxes silently overwriting them.
procedure TfrmMain.SyncBlockToFields;
var
  Cfg: TModelConfig;
  Sig: string;
  AnyPresent: Boolean;
begin
  Cfg := ParseModelConfig(memAntimony.Lines.Text);
  try
    Sig := BifBlockSignature(Cfg, AnyPresent);
    if not AnyPresent then Exit;            // no block in the text -> leave the boxes as they are
    if Sig = FLastAppliedBlock then Exit;   // block unchanged since last applied -> boxes win
    ApplyConfigToFields(Cfg);
    FLastAppliedBlock := Sig;
    SetStatus('Loaded bifurcation settings from the model text.');
  finally
    Cfg.Free;
  end;
end;

procedure TfrmMain.btnOpenClick(Sender: TObject);
var
  Dlg: TOpenDialog;
  Cfg: TModelConfig;
begin
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Filter := 'Model files (*.txt;*.ant)|*.txt;*.ant|All files (*.*)|*.*';
    if not Dlg.Execute then Exit;
    try
      memAntimony.Lines.Text := TFile.ReadAllText(Dlg.FileName);
    except
      on E: Exception do begin SetStatus('Open failed: ' + E.Message); Exit; end;
    end;

    // A freshly loaded model gets a clean slate: drop the previous diagram and species list so
    // nothing stale lingers until the user computes the new model.
    FResults.Clear;
    FUpdatingSpecies := True;
    try lbSpecies.Clear; cbLabelCurve.Clear; finally FUpdatingSpecies := False; end;
    RedrawAll;

    Cfg := ParseModelConfig(memAntimony.Lines.Text);
    try
      ApplyConfigToFields(Cfg);
      // Baseline the block signature so the just-loaded settings aren't re-applied on first Compute.
      var Ignore: Boolean;
      FLastAppliedBlock := BifBlockSignature(Cfg, Ignore);
      // Surface typos (e.g. a mistyped [section]) instead of silently loading nothing.
      if Cfg.Warnings.Count > 0 then
        SetStatus('Loaded ' + Dlg.FileName + ' -- ' + Cfg.Warnings.Text.Replace(sLineBreak, ' '))
      else
        SetStatus('Loaded ' + Dlg.FileName);
    finally
      Cfg.Free;
    end;
    FHasSeed := False;       // a freshly loaded model must not reuse the previous model's seed
    FSteadyFailed := False;  // nor carry a stale "no steady state" block
  finally
    Dlg.Free;
  end;
end;

procedure TfrmMain.btnSaveClick(Sender: TObject);
var
  Dlg: TSaveDialog;
  Cfg: TModelConfig;
  Text: string;
begin
  Dlg := TSaveDialog.Create(nil);
  try
    Dlg.Filter := 'Model files (*.txt;*.ant)|*.txt;*.ant|All files (*.*)|*.*';
    Dlg.DefaultExt := 'txt';
    if not Dlg.Execute then Exit;
    // Honour a pasted/edited block first: without this, saving right after pasting a model would
    // overwrite its (correct) block with the stale edit boxes -- silently destroying the settings.
    SyncBlockToFields;
    // Re-parse the current text (so hand-edits to the block/notes are respected), overwrite the
    // values from the fields, render back. Notes, prose and ordering survive.
    Cfg := ParseModelConfig(memAntimony.Lines.Text);
    try
      ExtractFieldsToConfig(Cfg);
      // The block now equals the fields; refresh the baseline so a later Compute doesn't think the
      // block changed (which would re-apply it and flash a spurious "loaded settings" message).
      var Ignore: Boolean;
      FLastAppliedBlock := BifBlockSignature(Cfg, Ignore);
      Text := Cfg.ToAntimony;
    finally
      Cfg.Free;
    end;
    memAntimony.Lines.Text := Text;   // reflect the updated settings block back to the modeler
    try
      TFile.WriteAllText(Dlg.FileName, Text);
      SetStatus('Saved ' + Dlg.FileName);
    except
      on E: Exception do SetStatus('Save failed: ' + E.Message);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TfrmMain.btnSimulateClick(Sender: TObject);
{ Run a time course from the model's initial conditions (Time Course groupbox). reset() restores
  every species/parameter to its t=0 state, then simulateEx integrates over the requested span.
  The result is cached in FTC* so the X/Y pickers can replot without re-simulating. }
var
  M: T2DMatrix;
  I, J, R, C, NPoints: Integer;
  TStart, TEnd: Double;
begin
  if not FRRReady then begin SetStatus('RoadRunner not available for simulation.'); Exit; end;

  TStart := nbTimeStart.Value;
  TEnd   := nbTimeEnd.Value;
  NPoints := Round(nbNumPoints.Value);
  if NPoints < 2 then NPoints := 2;
  if TEnd <= TStart then
  begin SetStatus('Time End must be greater than Time Start.'); Exit; end;

  try
    if not EnsureSimModel(ModelSbml) then
    begin SetStatus('Could not load the model for simulation.'); Exit; end;

    FSimRR.reset;   // initial conditions (and conservation totals) back to their t=0 state
    M := FSimRR.simulateEx(TStart, TEnd, NPoints);   // column 0 = time, 1.. = species
    try
      R := M.r; C := M.c;
      SetLength(FTCTimes, R);
      for I := 0 to R - 1 do FTCTimes[I] := M[I, 0];

      SetLength(FTCNames, C - 1);
      SetLength(FTCData, C - 1);
      for J := 1 to C - 1 do
      begin
        if J < M.columnHeader.Count then FTCNames[J - 1] := M.columnHeader[J]
        else FTCNames[J - 1] := 'S' + IntToStr(J);
        SetLength(FTCData[J - 1], R);
        for I := 0 to R - 1 do FTCData[J - 1][I] := M[I, J];
      end;
    finally
      M.Free;
    end;

    FTCHasData := True;
    PopulateTimeCourseAxes(FTCNames);   // fill/refresh the pickers, keeping any prior selection
    PlotTimeCourse;
    SetStatus(Format('Time course t=%.4g..%.4g, %d points, %d species.',
      [TStart, TEnd, NPoints, Length(FTCNames)]));
  except
    on E: Exception do SetStatus('Simulation failed: ' + E.Message);
  end;
end;

procedure TfrmMain.PopulateTimeCourseAxes(const Names: TArray<string>);
{ X combo = 'time' + species; Y checkbox list = species. Any prior selection is preserved; on the
  first run X defaults to 'time' and every species is ticked. Repopulation is fenced with
  FUpdatingSpecies so the OnChange/OnChangeCheck handlers don't replot mid-rebuild. }
var
  I: Integer;
  PrevX: string;
  PrevChecked: TStringList;
begin
  PrevX := '';
  if cboXAxis.ItemIndex >= 0 then PrevX := cboXAxis.Items[cboXAxis.ItemIndex];

  PrevChecked := TStringList.Create;
  FUpdatingSpecies := True;
  try
    for I := 0 to lblTimeCoureSpecies.Count - 1 do
      if lblTimeCoureSpecies.ListItems[I].IsChecked then
        PrevChecked.Add(lblTimeCoureSpecies.ListItems[I].Text);
    var HadPrev := lblTimeCoureSpecies.Count > 0;

    cboXAxis.Items.BeginUpdate;
    try
      cboXAxis.Clear;
      cboXAxis.Items.Add('time');
      for I := 0 to High(Names) do cboXAxis.Items.Add(Names[I]);
    finally
      cboXAxis.Items.EndUpdate;
    end;
    var Xi := cboXAxis.Items.IndexOf(PrevX);
    if Xi < 0 then Xi := 0;   // default: time
    cboXAxis.ItemIndex := Xi;

    lblTimeCoureSpecies.Clear;
    for I := 0 to High(Names) do
    begin
      var It := TListBoxItem.Create(lblTimeCoureSpecies);
      It.Parent := lblTimeCoureSpecies;
      It.Text := Names[I];
      It.Height := 22;
      if HadPrev then It.IsChecked := PrevChecked.IndexOf(Names[I]) >= 0
      else It.IsChecked := True;   // first run: plot every species
    end;
  finally
    FUpdatingSpecies := False;
    PrevChecked.Free;
  end;
end;

procedure TfrmMain.PlotTimeCourse;
{ Draw the cached run onto the main plot: one coloured line per ticked Y species against the chosen
  X (time or a species -> phase plane). Reuses the bifurcation plot's colour palette. }
var
  Xi, Si, K, Ci: Integer;
  XData: TArray<Double>;
  XName: string;
  S: TPlotSeries;
begin
  if not FTCHasData then Exit;

  Xi := cboXAxis.ItemIndex;
  if (Xi > 0) and ((Xi - 1) <= High(FTCData)) then
  begin
    XData := FTCData[Xi - 1];
    XName := FTCNames[Xi - 1];
  end
  else
  begin
    XData := FTCTimes;   // index 0 (or out of range) = time
    XName := 'time';
  end;

  SkPlotPaintBox1.ClearSeries;
  SkPlotPaintBox1.ClearAnnotations;

  Ci := 0;
  for Si := 0 to lblTimeCoureSpecies.Count - 1 do
    if (Si <= High(FTCData)) and lblTimeCoureSpecies.ListItems[Si].IsChecked then
    begin
      S := TPlotSeries.Create(FTCNames[Si], SpeciesPalette[Ci mod Length(SpeciesPalette)], False);
      S.LineVisible := True;
      S.LineWidth := 2;
      for K := 0 to High(FTCTimes) do
        S.AddXY(XData[K], FTCData[Si][K]);
      SkPlotPaintBox1.AddSeries(S);
      Inc(Ci);
    end;

  SkPlotPaintBox1.XAxisTitle.Text := XName;
  SkPlotPaintBox1.YAxisTitle.Text := 'concentration';
  SkPlotPaintBox1.ChartTitle.Text := 'Time course';
  SkPlotPaintBox1.AutoXScaling := True;
  SkPlotPaintBox1.AutoYScaling := True;
  SkPlotPaintBox1.Redraw;
end;

procedure TfrmMain.CheckOnlySpecies(const Name: string);
var
  I: Integer;
begin
  FUpdatingSpecies := True;
  try
    for I := 0 to lbSpecies.Count - 1 do
      lbSpecies.ListItems[I].IsChecked := SameText(lbSpecies.ListItems[I].Text, Name);
  finally
    FUpdatingSpecies := False;
  end;
end;

procedure TfrmMain.lblTimeCoureSpeciesChangeCheck(Sender: TObject);
begin
  // Y-axis species (re)ticked -> replot the cached run; ignore ticks made while repopulating.
  if FUpdatingSpecies then Exit;
  PlotTimeCourse;
end;

procedure TfrmMain.lbSpeciesChangeCheck(Sender: TObject);
begin
  if FUpdatingSpecies then Exit;
  if FResults.Count > 0 then
    RedrawAll;
end;

procedure TfrmMain.edYLimitChange(Sender: TObject);
begin
  // Re-apply the axis on each edit; blank/invalid falls back to auto-scale (handled in RedrawAll).
  if FResults.Count > 0 then
    RedrawAll;
end;

procedure TfrmMain.cbLabelCurveChange(Sender: TObject);
begin
  if FUpdatingSpecies then Exit;   // ignore programmatic repopulation in ApplyResult
  if FResults.Count > 0 then
    RedrawAll;
end;

procedure TfrmMain.cboXAxisChange(Sender: TObject);
begin
  // X-axis choice changed (time / a species) -> replot; ignore changes made while repopulating.
  if FUpdatingSpecies then Exit;
  PlotTimeCourse;
end;

// Load one built-in example into the editor + parameter fields, then clear the diagram so the old
// model's curves don't linger until Compute. AStart/ADs/ADsMax/AMaxSteps blank => keep the generic
// defaults. ALabel goes to the status line. The model text has no /* settings block */ (these are
// code constants), so SyncBlockToFields won't override the fields we set here on the next Compute.
procedure TfrmMain.LoadExample(const AText, AParam, APMin, APMax, AStart, ADs, ADsMax,
  AMaxSteps, ALabel: string);
begin
  memAntimony.Lines.Text := AText;
  edParameter.Text := AParam;
  edPMin.Text := APMin;
  edPMax.Text := APMax;
  edStart.Text := AStart;
  if ADs <> '' then edDs.Text := ADs;
  if ADsMax <> '' then edDsMax.Text := ADsMax;
  if AMaxSteps <> '' then edMaxSteps.Text := AMaxSteps;
  edYMin.Text := '';
  edYMax.Text := '';

  // Fresh model = clean slate, same as Open: drop the diagram + species lists and the stale seed.
  FResults.Clear;
  FUpdatingSpecies := True;
  try lbSpecies.Clear; cbLabelCurve.Clear; finally FUpdatingSpecies := False; end;
  RedrawAll;
  FHasSeed := False;
  FSteadyFailed := False;
  FLastAppliedBlock := '';   // no block in these constants; a later pasted block still syncs

  SetStatus('Loaded example: ' + ALabel + '. Press Compute.');
end;

procedure TfrmMain.cboExamplesChange(Sender: TObject);
begin
  // Order must match the Items added in FormCreate.
  case cboExamples.ItemIndex of
    0: LoadExample(SchloglNetModel, 'kin', '20', '28', '', '0.001', '0.02', '20000',
         'Schlogl (bistable network)');
    1: LoadExample(GrayScottModel, 'F', '0', '0.25', '0.08', '0.0005', '0.002', '220',
         'Gray-Scott (isola -- tick Overlay + reseed U=1;V=0 for the trivial branch)');
    2: LoadExample(EdelsteinModel, 'A', '0', '12', '', '0.001', '0.05', '40000',
         'Edelstein (bistable enzyme)');
    3: LoadExample(CovalentModel, 'k0', '0', '1.2', '', '0.001', '0.02', '20000',
         'Covalent switch (positive feedback)');
    4: LoadExample(BrusselatorModel, 'B', '1.0', '3.0', '', '0.001', '0.005', '100000',
         'Brusselator (Hopf)');
    5: LoadExample(Oscill8Model, 'a', '-1.5', '1.5', '', '0.001', '0.005', '100000',
         'Oscill8 (2 folds + Hopf)');
    6: LoadExample(TysonModel, 'm', '-10', '10', '', '0.001', '0.005', '100000',
         'Tyson-Novak (cell cycle: 4 folds + 3 Hopfs)');
  end;
end;

procedure TfrmMain.RunSelfTest;
{ Headless check of the whole embedded path: solve the current model, render each species
  through the REAL paint path (MakeScreenshot, not ExportToPng which uses a fresh canvas and
  would hide a stale-cache bug), write PNGs + a report, quit. }
var
  Res: TBifResult;
  SWWarm, SWSolve: TStopwatch;
  Rpt: TStringList;
  Shot: TBitmap;
  Json, Base: string;
  I: Integer;
begin
  if not Assigned(FEngine) then begin SetStatus('Julia engine not available.'); Exit; end;
  Base := ExtractFilePath(ParamStr(0));
  Rpt := TStringList.Create;
  try
    try
      SWWarm := TStopwatch.StartNew;
      FEngine.WaitUntilReady;
      SWWarm.Stop;

      // Steady-state seed demo: compute the SS on the high-x branch, then Compute -- the seed
      // must drive the continuation onto the high branch (maxX ~ 0.9). Exercises the whole
      // Find-steady-state -> seed -> Compute path headlessly.
      if FindCmdLineSwitch('ss', ['-', '/'], True) then
      begin
        edPMin.Text := '-10';  edPMax.Text := '10';  edParameter.Text := 'm';  edStart.Text := '8';
        memAntimony.Lines.Text := TysonHiModel;
        btnSteadyStateClick(nil);
        while FBusy do begin Application.ProcessMessages; Sleep(10); end;   // wait for SS task
        Rpt.Add('after Find steady state: ' + lblStatus.Text);
        Rpt.Add('seed set = ' + BoolToStr(FHasSeed, True));

        Res := ParseBifResult(FEngine.RunBifurcationSync(BuildRequest.ToJson));
        if Res.Ok then
        begin
          var xi := Res.IndexOfSpecies('x');
          var maxx := -1.0;
          for var q := 0 to High(Res.Branch) do
            if (xi >= 0) and (xi <= High(Res.Branch[q].U)) and (Res.Branch[q].U[xi] > maxx) then
              maxx := Res.Branch[q].U[xi];
          Rpt.Add(Format('seeded compute: nPts=%d maxX=%.3f (>0.8 => high branch reached)',
            [Length(Res.Branch), maxx]));
        end
        else
          Rpt.Add('seeded compute FAILED: ' + Res.Error);
        Rpt.Add('SELFTEST OK');
        Rpt.SaveToFile(Base + 'embed_selftest.txt');
        Application.Terminate;
        Exit;
      end;

      // Overlay demo: trace both branches of the bistable Tyson model and overlay them,
      // reproducing oscill8's two-branch picture. Exercises the overlay code path headlessly.
      if FindCmdLineSwitch('overlay', ['-', '/'], True) then
      begin
        edStart.Text := '';  edPMin.Text := '-10';  edPMax.Text := '10';  edParameter.Text := 'm';
        chkOverlay.IsChecked := False;                 // branch 1 replaces
        memAntimony.Lines.Text := TysonModel;          // low-x branch (ICs a=x=y=1)
        Res := ParseBifResult(FEngine.RunBifurcationSync(BuildRequest.ToJson));
        ApplyResult(Res, 0, 0);
        Rpt.Add(Format('branch1 ok=%s folds=%d hopfs=%d',
          [BoolToStr(Res.Ok, True), Length(Res.Folds), Length(Res.Hopfs)]));

        chkOverlay.IsChecked := True;                  // branch 2 overlays
        memAntimony.Lines.Text := TysonHiModel;        // high-x branch (ICs a=2,x=1,y=0.02)
        // Explicit start needed: from the high-x ICs, the auto-scan's steady-state solve still
        // drifts to the low branch. Seeding at m=8 keeps it on the high-x branch's basin.
        edStart.Text := '8';
        Res := ParseBifResult(FEngine.RunBifurcationSync(BuildRequest.ToJson));
        ApplyResult(Res, 0, 0);
        Rpt.Add(Format('branch2 ok=%s folds=%d hopfs=%d',
          [BoolToStr(Res.Ok, True), Length(Res.Folds), Length(Res.Hopfs)]));

        CheckOnlySpecies('x');
        RedrawAll;
        Application.ProcessMessages;
        Shot := SkPlotPaintBox1.MakeScreenshot;
        try
          Shot.SaveToFile(Base + 'embed_overlay_x.png');
          Rpt.Add(Format('overlay image x %dx%d, branches=%d', [Shot.Width, Shot.Height, FResults.Count]));
        finally
          Shot.Free;
        end;
        Rpt.Add('SELFTEST OK');
        Rpt.SaveToFile(Base + 'embed_selftest.txt');
        Application.Terminate;
        Exit;
      end;

      SWSolve := TStopwatch.StartNew;
      Json := FEngine.RunBifurcationSync(BuildRequest.ToJson);
      Res := ParseBifResult(Json);
      SWSolve.Stop;

      if not Res.Ok then
        Rpt.Add('SELFTEST FAIL: ' + Res.Error)
      else
      begin
        ApplyResult(Res, SWWarm.ElapsedMilliseconds, SWSolve.ElapsedMilliseconds);
        Application.ProcessMessages;
        Rpt.Add(Format('warm_ms=%d solve_ms=%d points=%d folds=%d hopfs=%d',
          [SWWarm.ElapsedMilliseconds, SWSolve.ElapsedMilliseconds,
           Length(Res.Branch), Length(Res.Folds), Length(Res.Hopfs)]));
        Rpt.Add('species=' + string.Join(',', Res.Species));

        for I := 0 to High(Res.Species) do
        begin
          PlotBifurcation(SkPlotPaintBox1, Res, I);
          Application.ProcessMessages;
          Shot := SkPlotPaintBox1.MakeScreenshot;
          try
            Shot.SaveToFile(Base + 'embed_' + Res.Species[I] + '.png');
            Rpt.Add(Format('image species=%s %dx%d', [Res.Species[I], Shot.Width, Shot.Height]));
          finally
            Shot.Free;
          end;
        end;

        for I := 0 to High(Res.Folds) do
          Rpt.Add(Format('fold p=%.9f', [Res.Folds[I].P], TFormatSettings.Invariant));
        for I := 0 to High(Res.Hopfs) do
          Rpt.Add(Format('hopf p=%.9f', [Res.Hopfs[I].P], TFormatSettings.Invariant));
        Rpt.Add('SELFTEST OK');
      end;
    except
      on E: Exception do Rpt.Add('SELFTEST FAIL: ' + E.Message);
    end;
    Rpt.SaveToFile(Base + 'embed_selftest.txt');
  finally
    Rpt.Free;
  end;
  Application.Terminate;
end;

initialization
  // Created here, not lazily: StartupLog runs from two threads and the .dpr calls it before any
  // form exists, so the lock must already be in place.
  GLogLock := TObject.Create;

finalization
  GLogLock.Free;

end.

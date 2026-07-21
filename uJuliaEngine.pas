unit uJuliaEngine;

{ Embeds the Julia runtime (libjulia.dll) in-process and exposes the bifurcation solver as a
  single string-in / string-out call.

  Why a dedicated thread. Embedded Julia must be called from the thread that ran jl_init (the
  GC and codegen are tied to it); calling from an arbitrary FMX thread pool worker is undefined.
  So TJuliaEngine owns ONE long-lived worker thread: it runs jl_init there, loads BifWorkerCore,
  warms up, and every later solve runs on that same thread. Callers hand work to it through a
  simple serialised handoff and block until the result comes back.

  Why string-in/string-out. The worker calls BifWorkerCore.run_bifurcation_json(json)::String,
  so the Delphi side reuses the exact JSON the socket route used, and never marshals a Julia
  struct across the C ABI. run_bifurcation_json never throws (bad input comes back as an
  ok:false JSON object), so no Julia exception ever crosses the boundary.

  jl_init may be called only once per process, so there must be at most ONE TJuliaEngine. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs;

type
  EJuliaEngine = class(Exception);

  TJuliaEngine = class
  private
    // configuration
    FJuliaBin: string;       // ...\julia-1.12.x\bin  (holds libjulia.dll + sys.dll)
    FProjectDir: string;     // Julia env with BifWorkerCore dev-dep'd in
    FSysImage: string;       // custom sysimage (bifsys.dll); '' => plain jl_init
    FWarmup: Boolean;

    // worker thread + serialised handoff
    FThread: TThread;
    FCallGate: TCriticalSection;  // serialises RunBifurcationSync callers
    FWorkReady: TEvent;           // caller -> worker: a request is waiting
    FDoneReady: TEvent;           // worker -> caller: response is ready
    FStop: Boolean;
    FRequest: UTF8String;
    FResponse: string;
    FCallError: string;

    // startup signalling
    FReady: TEvent;
    FInitError: string;
    FReadyElapsed: Double;

    // resolved Julia entry points (module-rooted; only touched on the worker thread)
    FJuliaFn: Pointer;            // BifWorkerCore.run_bifurcation_json
    FJuliaSS: Pointer;            // BifWorkerCore.steady_state_json
    FJuliaWarm: Pointer;          // BifWorkerCore.warmup_json (accepts Antimony; internal only)
    FPendingFn: Pointer;          // which of the above this request targets
    FCancelFlag: PInteger;        // address of BifWorkerCore.CANCEL[1]; nil if unavailable

    procedure WorkerLoop;
    procedure InitOnWorker;
    function CallOnWorker(Fn: Pointer; const ReqUtf8: UTF8String): string;
    function SubmitSync(Fn: Pointer; const RequestJson: string; TimeoutMs: Integer): string;
  public
    constructor Create(const AJuliaBin, AProjectDir, ASysImage: string;
                       AWarmup: Boolean = True);
    destructor Destroy; override;

    { Block until the runtime is up (and warmed, if requested). Returns True when ready,
      False on timeout. Raises EJuliaEngine if startup failed. }
    function WaitUntilReady(TimeoutMs: Integer = 180000): Boolean;

    { Run one continuation. Thread-safe and serialised. Blocks the calling thread until the
      worker returns the JSON, so call it from a background task, never the UI thread.
      Raises EJuliaEngine on timeout or a marshalling failure; a *solver* failure is not an
      exception here -- it comes back inside the JSON as an ok:false object. }
    function RunBifurcationSync(const RequestJson: string;
                               TimeoutMs: Integer = 600000): string;

    { Compute a steady state (JSON in / JSON out), same threading contract as above. }
    function SteadyStateSync(const RequestJson: string;
                             TimeoutMs: Integer = 120000): string;

    { Request that the currently-running continuation stop at its next step. Safe to call from any
      thread (it's a plain memory write to a flag the Julia worker polls) -- in particular from the
      UI thread while a RunBifurcationSync is blocking a background task. The interrupted run
      returns normally with a partial branch and "cancelled":true. No-op if the worker predates the
      cancel support. }
    procedure Cancel;

    { True once the cancel flag address was resolved (i.e. Cancel will actually do something). }
    function CanCancel: Boolean;

    property InitError: string read FInitError;
    property ReadySeconds: Double read FReadyElapsed;
  end;

implementation

uses
  Winapi.Windows, System.Diagnostics, uJuliaPaths;

// ---------------------------------------------------------------- libjulia bindings
type
  jl_value_t = Pointer;

  Tjl_init                  = procedure(); cdecl;
  Tjl_init_with_image_file  = procedure(const bindir, image: PAnsiChar); cdecl;
  Tjl_eval_string           = function(const str: PAnsiChar): jl_value_t; cdecl;
  Tjl_cstr_to_string        = function(const str: PAnsiChar): jl_value_t; cdecl;
  Tjl_string_ptr            = function(s: jl_value_t): PAnsiChar; cdecl;
  Tjl_call1                 = function(f, a: jl_value_t): jl_value_t; cdecl;
  Tjl_exception_occurred    = function(): jl_value_t; cdecl;
  Tjl_typeof_str            = function(v: jl_value_t): PAnsiChar; cdecl;
  Tjl_atexit_hook           = procedure(status: Integer); cdecl;

var
  hJulia: HMODULE = 0;
  jl_init                 : Tjl_init;
  jl_init_with_image_file : Tjl_init_with_image_file;
  jl_eval_string          : Tjl_eval_string;
  jl_cstr_to_string       : Tjl_cstr_to_string;
  jl_string_ptr           : Tjl_string_ptr;
  jl_call1                : Tjl_call1;
  jl_exception_occurred   : Tjl_exception_occurred;
  jl_typeof_str           : Tjl_typeof_str;
  jl_atexit_hook          : Tjl_atexit_hook;

function Bind(name: PAnsiChar): Pointer;
begin
  Result := GetProcAddress(hJulia, name);
  if Result = nil then
    raise EJuliaEngine.CreateFmt('libjulia.dll has no symbol "%s"', [string(AnsiString(name))]);
end;

procedure LoadLibJulia(const JuliaBin: string);
begin
  if hJulia <> 0 then Exit;
  // Make the Julia bin dir the primary search path so libjulia's siblings
  // (libjulia-internal, libjulia-codegen, openlibm, ...) resolve.
  SetDllDirectory(PChar(JuliaBin));
  hJulia := LoadLibraryEx(PChar(JuliaBin + '\libjulia.dll'), 0,
                          LOAD_WITH_ALTERED_SEARCH_PATH);
  if hJulia = 0 then
    raise EJuliaEngine.CreateFmt('Failed to load libjulia.dll from "%s" (error %d)',
      [JuliaBin, GetLastError]);

  @jl_init                 := Bind('jl_init');
  @jl_init_with_image_file := Bind('jl_init_with_image_file');
  @jl_eval_string          := Bind('jl_eval_string');
  @jl_cstr_to_string       := Bind('jl_cstr_to_string');
  @jl_string_ptr           := Bind('jl_string_ptr');
  @jl_call1                := Bind('jl_call1');
  @jl_exception_occurred   := Bind('jl_exception_occurred');
  @jl_typeof_str           := Bind('jl_typeof_str');
  @jl_atexit_hook          := Bind('jl_atexit_hook');
end;

procedure CheckJuliaError(const where: string);
var
  ex: jl_value_t;
begin
  ex := jl_exception_occurred();
  if ex <> nil then
    raise EJuliaEngine.CreateFmt('Julia error during %s: %s',
      [where, string(AnsiString(jl_typeof_str(ex)))]);
end;

function EvalChecked(const src: AnsiString; const where: string): jl_value_t;
begin
  Result := jl_eval_string(PAnsiChar(src));
  CheckJuliaError(where);
end;

// ---------------------------------------------------------------- TJuliaEngine

constructor TJuliaEngine.Create(const AJuliaBin, AProjectDir, ASysImage: string;
                                AWarmup: Boolean);
begin
  inherited Create;
  FJuliaBin := ExcludeTrailingPathDelimiter(AJuliaBin);
  FProjectDir := ExcludeTrailingPathDelimiter(AProjectDir);
  FSysImage := ASysImage;
  FWarmup := AWarmup;

  FCallGate := TCriticalSection.Create;
  FWorkReady := TEvent.Create(nil, False, False, '');  // auto-reset
  FDoneReady := TEvent.Create(nil, False, False, '');  // auto-reset
  FReady := TEvent.Create(nil, True, False, '');        // manual-reset

  FThread := TThread.CreateAnonymousThread(WorkerLoop);
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

destructor TJuliaEngine.Destroy;
begin
  if Assigned(FThread) then
  begin
    FStop := True;
    FWorkReady.SetEvent;      // wake the loop so it can see FStop and exit
    FThread.WaitFor;
    FThread.Free;
  end;
  FReady.Free;
  FDoneReady.Free;
  FWorkReady.Free;
  FCallGate.Free;
  inherited;
end;

// Runs ON the worker thread: bring up the runtime, load the package, warm up.
procedure TJuliaEngine.InitOnWorker;
var
  usingSysImage: Boolean;
begin
  usingSysImage := (FSysImage <> '') and FileExists(FSysImage);

  LoadLibJulia(FJuliaBin);

  // Set the active project BEFORE jl_init, the embedded equivalent of `julia --project=DIR`.
  // A runtime `Pkg.activate` instead would trigger a manifest/staleness rescan that reloads
  // BifWorkerCore from the depot pkgimage rather than the copy baked into the sysimage --
  // ~3 s wasted, and it can even force a recompile. JULIA_PROJECT is read during jl_init.
  SetEnvironmentVariable('JULIA_PROJECT', PChar(FProjectDir));

  // Tell RoadRunner.jl where its native DLLs are, resolved at RUNTIME on THIS machine. Without
  // this it would fall back to the path baked into the sysimage at build time, which is wrong
  // on any relocated/deployed install. See RoadRunner.jl __init__ (reads BIFRR_LIBDIR).
  SetEnvironmentVariable('BIFRR_LIBDIR',
    PChar(IncludeTrailingPathDelimiter(FProjectDir) + 'RoadRunner\src'));

  // If we ship a depot (deployed install), make Julia search it too, so the handful of native
  // artifacts the baked-in JLLs need -- Arpack_jll, OpenSpecFun_jll -- resolve without the user
  // ever running Pkg.instantiate(). The user's own depot stays FIRST so Julia's writes (logs,
  // compile cache) go somewhere writable; artifact lookup scans every entry, so ours is still
  // found. In dev BundledDepot is '' and we leave JULIA_DEPOT_PATH untouched.
  var DepotPath := BuildDepotPath(FProjectDir);
  if DepotPath <> '' then
    SetEnvironmentVariable('JULIA_DEPOT_PATH', PChar(DepotPath));

  // Boot the runtime. With a custom sysimage the baked-in packages load at image speed
  // (~0.5 s total to ready+warm); without one we fall back to plain init + the pkgimage cache
  // (~4 s, dominated by `using` scanning dependency staleness).
  if usingSysImage then
    jl_init_with_image_file(PAnsiChar(AnsiString(FJuliaBin)),
                            PAnsiChar(AnsiString(FSysImage)))
  else
    jl_init();
  CheckJuliaError('jl_init');

  // When BifWorkerCore is baked into the sysimage it is already loaded AND already bound in
  // Main, so `using` is unnecessary -- and a runtime `using` here would cost ~3 s scanning
  // dependency staleness. Only the plain-init path (no sysimage) actually needs it.
  if not usingSysImage then
    EvalChecked('using BifWorkerCore', 'load BifWorkerCore');

  FJuliaFn := EvalChecked('BifWorkerCore.run_bifurcation_json', 'resolve entry point');
  if FJuliaFn = nil then
    raise EJuliaEngine.Create('run_bifurcation_json resolved to null');
  FJuliaSS := EvalChecked('BifWorkerCore.steady_state_json', 'resolve steady-state entry');
  if FJuliaSS = nil then
    raise EJuliaEngine.Create('steady_state_json resolved to null');
  FJuliaWarm := EvalChecked('BifWorkerCore.warmup_json', 'resolve warmup entry');
  if FJuliaWarm = nil then
    raise EJuliaEngine.Create('warmup_json resolved to null');

  // Resolve the fixed address of the cooperative-cancel flag (BifWorkerCore.CANCEL). We ask Julia
  // to stringify the pointer and parse it here -- no extra C bindings, and it's read once on this
  // (the jl_init) thread. Non-fatal: an older worker without CANCEL just leaves Cancel a no-op.
  FCancelFlag := nil;
  try
    var AddrVal := jl_eval_string(PAnsiChar(AnsiString('string(UInt(pointer(BifWorkerCore.CANCEL)))')));
    if (jl_exception_occurred() = nil) and (AddrVal <> nil) then
    begin
      var AddrStr := Trim(string(UTF8String(jl_string_ptr(AddrVal))));
      var Addr: UInt64;
      if TryStrToUInt64(AddrStr, Addr) and (Addr <> 0) then
        FCancelFlag := PInteger(Addr);
    end;
  except
    FCancelFlag := nil;   // never let cancel-wiring break startup
  end;

  // Warm up: JIT everything the first real solve would otherwise pay for. Cheap with a
  // sysimage (~0.16 s), several seconds without. Uses warmup_json (not the SBML-only request
  // path) so the fixed fixture can stay written as Antimony and be converted worker-side.
  if FWarmup then
    CallOnWorker(FJuliaWarm, UTF8String(
      '{"antimony":"J1: -> X; B; J2: X -> ; a3*X; J3: -> X; a2*X^2; J4: X -> ; a1*X^3;' +
      ' X=1.7; B=23; a1=1; a2=9; a3=26;","parameter":"B","pMin":23.0,"pMax":25.0,' +
      '"pStart":23.0,"ds":0.001,"dsMax":0.005}'));
end;

// Runs ON the worker thread: one string-in/string-out call into the given Julia function.
function TJuliaEngine.CallOnWorker(Fn: Pointer; const ReqUtf8: UTF8String): string;
var
  argVal, resVal: jl_value_t;
  resPtr: PAnsiChar;
begin
  // jl_cstr_to_string copies the bytes into a Julia String; argVal is passed straight to
  // jl_call1 with no allocation in between, so it needs no separate GC root.
  argVal := jl_cstr_to_string(PAnsiChar(ReqUtf8));
  CheckJuliaError('box request');

  resVal := jl_call1(Fn, argVal);
  CheckJuliaError('julia call');
  if resVal = nil then
    raise EJuliaEngine.Create('julia call returned null');

  // Read the Julia String immediately -- no Julia call between jl_call1 and here, so no GC
  // can run and the pointer is valid. Copy straight into a Delphi UTF-8 string.
  resPtr := jl_string_ptr(resVal);
  Result := string(UTF8String(resPtr));
end;

procedure TJuliaEngine.WorkerLoop;
var
  sw: TStopwatch;
begin
  // --- startup on this thread ---
  try
    sw := TStopwatch.StartNew;
    InitOnWorker;
    sw.Stop;
    FReadyElapsed := sw.Elapsed.TotalSeconds;
  except
    on E: Exception do
      FInitError := E.Message;
  end;
  FReady.SetEvent;

  if FInitError <> '' then
    Exit;  // never signal work done; RunBifurcationSync will see the init error via WaitUntilReady

  // --- serve requests until stopped ---
  while True do
  begin
    FWorkReady.WaitFor(INFINITE);
    if FStop then
      Break;
    try
      FResponse := CallOnWorker(FPendingFn, FRequest);
      FCallError := '';
    except
      on E: Exception do
      begin
        FResponse := '';
        FCallError := E.Message;
      end;
    end;
    FDoneReady.SetEvent;
  end;

  // --- shutdown: must be the last Julia call, on this thread ---
  if hJulia <> 0 then
    jl_atexit_hook(0);
end;

function TJuliaEngine.WaitUntilReady(TimeoutMs: Integer): Boolean;
begin
  Result := FReady.WaitFor(TimeoutMs) = wrSignaled;
  if Result and (FInitError <> '') then
    raise EJuliaEngine.Create('Julia engine failed to start: ' + FInitError);
end;

// Marshal one JSON call onto the worker thread and block for the result. Serialised across all
// callers, so run and steady-state requests never overlap on the single Julia thread.
function TJuliaEngine.SubmitSync(Fn: Pointer; const RequestJson: string;
                                 TimeoutMs: Integer): string;
begin
  if not WaitUntilReady then
    raise EJuliaEngine.Create('Julia engine not ready');

  FCallGate.Enter;
  try
    FPendingFn := Fn;
    FRequest := UTF8String(RequestJson);
    FWorkReady.SetEvent;
    if FDoneReady.WaitFor(TimeoutMs) <> wrSignaled then
      raise EJuliaEngine.Create('Julia call timed out');
    if FCallError <> '' then
      raise EJuliaEngine.Create(FCallError);
    Result := FResponse;
  finally
    FCallGate.Leave;
  end;
end;

function TJuliaEngine.RunBifurcationSync(const RequestJson: string;
                                         TimeoutMs: Integer): string;
begin
  Result := SubmitSync(FJuliaFn, RequestJson, TimeoutMs);
end;

function TJuliaEngine.SteadyStateSync(const RequestJson: string;
                                      TimeoutMs: Integer): string;
begin
  Result := SubmitSync(FJuliaSS, RequestJson, TimeoutMs);
end;

procedure TJuliaEngine.Cancel;
begin
  // Plain store to the flag the worker's per-step callback polls. No Julia call, so it's safe even
  // while the worker thread is deep inside a continuation. The worker resets it to 0 at each run's
  // start, so a stray Cancel between runs doesn't leak into the next one.
  if FCancelFlag <> nil then
    FCancelFlag^ := 1;
end;

function TJuliaEngine.CanCancel: Boolean;
begin
  Result := FCancelFlag <> nil;
end;

end.

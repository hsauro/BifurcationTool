program BifEmbedTest;

{ Console de-risk driver for the embedded Julia route.

  Brings up TJuliaEngine (embedded libjulia + BifWorkerCore), runs the Schloegl bistable model
  through run_bifurcation_json, and checks the result matches what the socket route produced:
  two folds at B = 23.6151 / 24.3849. Proves string-in/string-out embedding end to end before
  any FMX code depends on it.

  Optional arg --sysimage uses the custom bifsys.dll (fast); default is plain jl_init. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.JSON, System.Diagnostics,
  uJuliaEngine in 'uJuliaEngine.pas',
  uJuliaPaths in 'uJuliaPaths.pas';

const
  REQUEST =
    '{"antimony":"J1: -> X; B; J2: X -> ; a3*X; J3: -> X; a2*X^2; J4: X -> ; a1*X^3;' +
    ' X=1.7; B=23; a1=1; a2=9; a3=26;","parameter":"B","pMin":23.0,"pMax":25.0,' +
    '"pStart":23.0,"ds":0.001,"dsMax":0.005}';

var
  eng: TJuliaEngine;
  useImage: Boolean;
  img, jsonOut: string;
  root: TJSONObject;
  folds: TJSONArray;
  sw: TStopwatch;
  i: Integer;
  paths: TJuliaPaths;
begin
  try
    paths := ResolveJuliaPaths;
    useImage := FindCmdLineSwitch('sysimage', ['-', '/'], True) and (paths.SysImage <> '');
    if useImage then img := paths.SysImage else img := '';

    Writeln('Bringing up embedded Julia');
    Writeln('  julia bin: ', paths.BinDir);
    Writeln('  project  : ', paths.ProjectDir);
    Writeln('  sysimage : ', BoolToStr(useImage, True));

    sw := TStopwatch.StartNew;
    eng := TJuliaEngine.Create(paths.BinDir, paths.ProjectDir, img, {warmup=} True);
    try
      if not eng.WaitUntilReady(240000) then
        raise Exception.Create('engine did not become ready in time');
      sw.Stop;
      Writeln(Format('  ready + warm in %.2f s (worker reported %.2f s)',
        [sw.Elapsed.TotalSeconds, eng.ReadySeconds]));

      // First real request after warm-up: should be ~0.1 s.
      sw := TStopwatch.StartNew;
      jsonOut := eng.RunBifurcationSync(REQUEST);
      sw.Stop;
      Writeln(Format('  solve returned %d chars in %d ms',
        [Length(jsonOut), sw.ElapsedMilliseconds]));

      root := TJSONObject(TJSONObject.ParseJSONValue(jsonOut));
      if root = nil then
        raise Exception.Create('result was not JSON');
      try
        Writeln('  ok      = ', root.GetValue<Boolean>('ok', False));
        Writeln('  nPoints = ', root.GetValue<Integer>('nPoints', -1));
        folds := root.GetValue<TJSONArray>('folds', nil);
        if folds <> nil then
        begin
          Writeln('  folds   = ', folds.Count);
          for i := 0 to folds.Count - 1 do
            Writeln(Format('     fold B = %.9f',
              [(folds.Items[i] as TJSONObject).GetValue<Double>('p')]));
          if folds.Count = 2 then
            Writeln('  RESULT: HYSTERESIS-CONFIRMED (matches socket route)')
          else
            Writeln('  RESULT: unexpected fold count');
        end;
      finally
        root.Free;
      end;
    finally
      eng.Free;   // clean jl_atexit_hook on the worker thread
    end;

    Writeln('Done.');
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.

unit uBifResult;

{ Request builder and result parser for the bifurcation JSON protocol.

  Same wire format as the socket route -- the whole point of run_bifurcation_json is that the
  Delphi side is transport-agnostic. TBifRequest builds the request JSON; ParseBifResult turns
  the response JSON into records. }

interface

uses
  System.SysUtils, System.JSON, System.Math;

type
  TBifPoint = record
    P: Double;
    U: TArray<Double>;
    Stable: Boolean;
  end;

  TBifSpecial = record
    P: Double;
    U: TArray<Double>;
  end;

  TBifResult = record
    Ok: Boolean;
    Error: string;
    Parameter: string;
    Species: TArray<string>;    // independent species = the state variables
    Dependent: TArray<string>;  // reconstructed from conservation relations
    Conserved: Boolean;
    Branch: TArray<TBifPoint>;
    Folds: TArray<TBifSpecial>;
    Hopfs: TArray<TBifSpecial>;
    Cancelled: Boolean;   // host stopped the run early; Branch is partial (still valid to plot)
    function IndexOfSpecies(const AName: string): Integer;
  end;

  TBifRequest = record
    Sbml: string;   // model as SBML; the host converts Antimony->SBML with its own libantimony
    Parameter: string;
    PMin, PMax, PStart: Double;
    HasPStart: Boolean;
    Ds, DsMax: Double;
    MaxSteps: Integer;
    ConservedMoieties: Boolean;
    StartState: TArray<Double>;   // explicit seed (full floating-species order); empty = none
    HasStartState: Boolean;
    class function Create(const ASbml, AParameter: string;
                          APMin, APMax: Double): TBifRequest; static;
    function ToJson: string;
  end;

  // Result of a "Find steady state" call.
  TSteadyResult = record
    Ok: Boolean;
    Error: string;
    Parameter: string;
    PValue: Double;
    Species: TArray<string>;
    State: TArray<Double>;
    Residual: Double;
    Converged: Boolean;
  end;

function ParseBifResult(const Body: string): TBifResult;
function ParseSteadyResult(const Body: string): TSteadyResult;

implementation

// ---------------------------------------------------------------- helpers

function JsonToDoubleArray(A: TJSONArray): TArray<Double>;
var
  I: Integer;
begin
  if A = nil then Exit(nil);
  SetLength(Result, A.Count);
  for I := 0 to A.Count - 1 do
    Result[I] := (A.Items[I] as TJSONNumber).AsDouble;
end;

function JsonToStringArray(A: TJSONArray): TArray<string>;
var
  I: Integer;
begin
  if A = nil then Exit(nil);
  SetLength(Result, A.Count);
  for I := 0 to A.Count - 1 do
    Result[I] := A.Items[I].Value;
end;

function ParseSpecials(Arr: TJSONArray): TArray<TBifSpecial>;
var
  I: Integer;
  Item: TJSONObject;
begin
  if Arr = nil then Exit(nil);
  SetLength(Result, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    Item := Arr.Items[I] as TJSONObject;
    Result[I].P := Item.GetValue<Double>('p');
    Result[I].U := JsonToDoubleArray(Item.GetValue<TJSONArray>('u', nil));
  end;
end;

// ---------------------------------------------------------------- TBifResult

function TBifResult.IndexOfSpecies(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Species) do
    if SameText(Species[I], AName) then Exit(I);
  Result := -1;
end;

// ---------------------------------------------------------------- TBifRequest

class function TBifRequest.Create(const ASbml, AParameter: string;
                                  APMin, APMax: Double): TBifRequest;
begin
  Result := Default(TBifRequest);
  Result.Sbml := ASbml;
  Result.Parameter := AParameter;
  Result.PMin := APMin;
  Result.PMax := APMax;
  Result.HasPStart := False;
  // Fine enough to RESOLVE sharp folds (a coarse dsMax makes the continuation take one giant
  // step across a sharp turn, which then renders as a spurious near-vertical line -- confirmed
  // against BifurcationKit's own plots on the Tyson model). dsMax=0.005 traces such folds as
  // smooth curves; maxSteps is raised so the finer steps still cover the whole range. Costs
  // more points/time; raise dsMax for speed on well-behaved models. The worker falls back to
  // its own defaults if these aren't sent, but the app always sends them.
  Result.Ds := 0.001;
  Result.DsMax := 0.005;
  Result.MaxSteps := 100000;
  Result.ConservedMoieties := True;
end;

function TBifRequest.ToJson: string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.AddPair('sbml', Sbml);
    O.AddPair('parameter', Parameter);
    O.AddPair('pMin', TJSONNumber.Create(PMin));
    O.AddPair('pMax', TJSONNumber.Create(PMax));
    if HasPStart then
      O.AddPair('pStart', TJSONNumber.Create(PStart));
    O.AddPair('ds', TJSONNumber.Create(Ds));
    O.AddPair('dsMax', TJSONNumber.Create(DsMax));
    O.AddPair('maxSteps', TJSONNumber.Create(MaxSteps));
    O.AddPair('conservedMoieties', TJSONBool.Create(ConservedMoieties));
    if HasStartState and (Length(StartState) > 0) then
    begin
      var Arr := TJSONArray.Create;
      for var K := 0 to High(StartState) do
        Arr.Add(StartState[K]);
      O.AddPair('startState', Arr);
    end;
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function ParseSteadyResult(const Body: string): TSteadyResult;
var
  Root: TJSONObject;
  V: TJSONValue;
begin
  Result := Default(TSteadyResult);
  V := TJSONObject.ParseJSONValue(Body);
  if not (V is TJSONObject) then
  begin
    V.Free;
    Result.Ok := False;
    Result.Error := 'Response was not a JSON object: ' + Copy(Body, 1, 200);
    Exit;
  end;
  Root := TJSONObject(V);
  try
    Result.Ok := Root.GetValue<Boolean>('ok', False);
    if not Result.Ok then
    begin
      Result.Error := Root.GetValue<string>('error', 'unknown error');
      Exit;
    end;
    Result.Parameter := Root.GetValue<string>('parameter', '');
    Result.PValue    := Root.GetValue<Double>('pValue', 0);
    Result.Residual  := Root.GetValue<Double>('residual', NaN);
    Result.Converged := Root.GetValue<Boolean>('converged', False);
    Result.Species   := JsonToStringArray(Root.GetValue<TJSONArray>('species', nil));
    Result.State     := JsonToDoubleArray(Root.GetValue<TJSONArray>('state', nil));
  finally
    Root.Free;
  end;
end;

// ---------------------------------------------------------------- ParseBifResult

function ParseBifResult(const Body: string): TBifResult;
var
  Root: TJSONObject;
  Arr: TJSONArray;
  Item: TJSONObject;
  I: Integer;
  V: TJSONValue;
begin
  Result := Default(TBifResult);

  V := TJSONObject.ParseJSONValue(Body);
  if not (V is TJSONObject) then
  begin
    V.Free;
    Result.Ok := False;
    Result.Error := 'Response was not a JSON object: ' + Copy(Body, 1, 200);
    Exit;
  end;

  Root := TJSONObject(V);
  try
    Result.Ok := Root.GetValue<Boolean>('ok', False);
    if not Result.Ok then
    begin
      Result.Error := Root.GetValue<string>('error', 'unknown error');
      Exit;
    end;

    Result.Parameter := Root.GetValue<string>('parameter', '');
    Result.Conserved := Root.GetValue<Boolean>('conserved', False);
    Result.Species   := JsonToStringArray(Root.GetValue<TJSONArray>('species', nil));
    Result.Dependent := JsonToStringArray(Root.GetValue<TJSONArray>('dependent', nil));

    Arr := Root.GetValue<TJSONArray>('branch', nil);
    if Arr <> nil then
    begin
      SetLength(Result.Branch, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        Item := Arr.Items[I] as TJSONObject;
        Result.Branch[I].P := Item.GetValue<Double>('p');
        Result.Branch[I].Stable := Item.GetValue<Boolean>('stable', False);
        Result.Branch[I].U := JsonToDoubleArray(Item.GetValue<TJSONArray>('u', nil));
      end;
    end;

    Result.Folds := ParseSpecials(Root.GetValue<TJSONArray>('folds', nil));
    Result.Hopfs := ParseSpecials(Root.GetValue<TJSONArray>('hopfs', nil));
    Result.Cancelled := Root.GetValue<Boolean>('cancelled', False);
  finally
    Root.Free;
  end;
end;

end.

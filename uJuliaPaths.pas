unit uJuliaPaths;

{ Runtime resolution of the paths TJuliaEngine needs, so nothing is hardcoded.

  The Julia project dir and its sysimage ship beside the executable -- exe and julia\ are
  siblings, the SAME layout in development and in a deployed install (dev builds run against a
  junction so there is only ever one real julia\ folder; see the build-output junction). So the
  project dir is located as:
    1. the JULIA_PROJECT_DIR environment variable (explicit override, any layout), if it holds a
       Project.toml;
    2. <exe dir>\julia  -- julia\ beside the .exe. Deterministic, and identical in dev and
       deployment.

  The Julia binary dir (libjulia.dll + sys.dll) is an EXTERNAL juliaup install, so it can't be
  app-relative. It is discovered, in order:
    1. the JULIA_BINDIR environment variable (explicit override), if it holds libjulia.dll;
    2. juliaup's *default channel*, read from <depot>\juliaup\juliaup.json;
    3. the newest installed julia-* under <depot>\juliaup that contains libjulia.dll.
  The depot is JULIA_DEPOT_PATH (first entry) if set, else %USERPROFILE%\.julia. }

interface

uses
  System.SysUtils;

type
  EJuliaPaths = class(Exception);

  TJuliaPaths = record
    BinDir: string;         // ...\julia-1.12.x\bin  (libjulia.dll + sys.dll live here)
    ProjectDir: string;     // this app's julia\ env (Project.toml + Manifest.toml)
    SysImage: string;       // ProjectDir\bifsys.dll, or '' if it hasn't been built yet
    RequiredJulia: string;  // julia_version from Manifest.toml (what the sysimage was built with)
    DetectedJulia: string;  // version parsed from BinDir's folder name, or '' if undeterminable
    BundledDepot: string;   // ProjectDir\depot if we ship one, else '' (see JULIA_DEPOT_PATH below)
  end;

{ Resolve all paths. Raises EJuliaPaths if the project dir or the Julia bin can't be located. }
function ResolveJuliaPaths: TJuliaPaths;

{ True when both versions are known and differ -- the installed Julia won't match the sysimage.
  Returns False (no complaint) when DetectedJulia is '' (e.g. a JULIA_BINDIR override with no
  version in its folder name), since we can't be sure of a mismatch. }
function JuliaVersionMismatch(const Paths: TJuliaPaths): Boolean;

{ The user's Julia depot: JULIA_DEPOT_PATH's first entry if set, else %USERPROFILE%\.julia. }
function DepotDir: string;

{ Add a directory to the process DLL search path (Win32 SetDllDirectory).

  Needed because the native DLLs in julia\RoadRunner\src (roadrunner_c_api, libantimony) sit beside
  their own dependencies -- the MSVC runtimes and zlib -- but a plain LoadLibrary resolves a
  module's dependencies against the EXE directory, never against the loaded DLL's own folder. On a
  machine without a system-wide VC++ redistributable that fails with error 126. Julia's dlopen uses
  LOAD_WITH_ALTERED_SEARCH_PATH and does search that folder, which is why only the host needs this.
  Call BEFORE loading those libraries. Returns False if the call failed. }
function SetNativeDllSearchDir(const ADir: string): Boolean;

{ The value to put in JULIA_DEPOT_PATH for a project dir: the user's depot FIRST (Julia writes
  caches/logs to entry 1, and the app folder may be read-only), then <AProjectDir>\depot so
  artifact lookup -- which scans every entry -- finds the libraries we ship. Returns '' when no
  bundled depot exists (dev), in which case the caller should leave JULIA_DEPOT_PATH alone. }
function BuildDepotPath(const AProjectDir: string): string;

implementation

uses
  System.IOUtils, System.JSON, System.Generics.Collections, Winapi.Windows;

function SetNativeDllSearchDir(const ADir: string): Boolean;
begin
  Result := (ADir <> '') and TDirectory.Exists(ADir) and
            SetDllDirectory(PChar(ExcludeTrailingPathDelimiter(ADir)));
end;

// -------------------------------------------------------------- small JSON helpers
// Use Values[] (exact-name lookup) rather than the generic GetValue<T>, whose dotted-path
// parsing would choke on version keys like "1.12.6+0.x64.w64.mingw32".

function JObj(Parent: TJSONObject; const Name: string): TJSONObject;
var
  V: TJSONValue;
begin
  Result := nil;
  if Parent = nil then Exit;
  V := Parent.Values[Name];
  if V is TJSONObject then Result := TJSONObject(V);
end;

function JStr(Obj: TJSONObject; const Name: string): string;
var
  V: TJSONValue;
begin
  Result := '';
  if Obj = nil then Exit;
  V := Obj.Values[Name];
  if V <> nil then Result := V.Value;
end;

// -------------------------------------------------------------- project dir (app-relative)

function IsProjectDir(const Dir: string): Boolean;
begin
  Result := (Dir <> '') and TFile.Exists(TPath.Combine(Dir, 'Project.toml'));
end;

function FindProjectDir: string;
var
  ExeDir, Override_, Beside: string;
begin
  // 1) explicit override -- works for any layout.
  Override_ := ExcludeTrailingPathDelimiter(GetEnvironmentVariable('JULIA_PROJECT_DIR'));
  if IsProjectDir(Override_) then Exit(Override_);

  // 2) julia\ beside the exe -- the shipped layout, identical in dev (via junction) and install.
  ExeDir := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  Beside := TPath.Combine(ExeDir, 'julia');
  if IsProjectDir(Beside) then Exit(Beside);

  raise EJuliaPaths.CreateFmt(
    'Could not locate the julia\ project dir. Expected it beside the executable ' +
    '("%s"), or set JULIA_PROJECT_DIR to its location.', [Beside]);
end;

// -------------------------------------------------------------- Julia bin (discovered)

function HasLibJulia(const BinDir: string): Boolean;
begin
  Result := (BinDir <> '') and TFile.Exists(TPath.Combine(BinDir, 'libjulia.dll'));
end;

function DepotDir: string;
var
  D: string;
  P: Integer;
begin
  D := GetEnvironmentVariable('JULIA_DEPOT_PATH');
  if D <> '' then
  begin
    P := Pos(PathSep, D);                 // a depot list is ';'-separated; take the first
    if P > 0 then D := Copy(D, 1, P - 1);
    Exit(ExcludeTrailingPathDelimiter(D));
  end;
  Result := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.julia');
end;

// juliaup's currently selected default: Default -> InstalledChannels[Default].Version
//   -> InstalledVersions[Version].Path (relative to the juliaup dir).
function BinFromJuliaUpDefault(const JuliaUp: string): string;
var
  JsonPath, DefName, Ver, RelPath, Cand: string;
  Root: TJSONObject;
begin
  Result := '';
  JsonPath := TPath.Combine(JuliaUp, 'juliaup.json');
  if not TFile.Exists(JsonPath) then Exit;

  Root := TJSONObject(TJSONObject.ParseJSONValue(TFile.ReadAllText(JsonPath)));
  if Root = nil then Exit;
  try
    DefName := JStr(Root, 'Default');
    Ver     := JStr(JObj(JObj(Root, 'InstalledChannels'), DefName), 'Version');
    RelPath := JStr(JObj(JObj(Root, 'InstalledVersions'), Ver), 'Path');
    if RelPath = '' then Exit;
    // Path is relative to the juliaup dir, e.g. ".\julia-1.12.6+0.x64.w64.mingw32".
    Cand := TPath.GetFullPath(TPath.Combine(TPath.Combine(JuliaUp, RelPath), 'bin'));
    if HasLibJulia(Cand) then Result := Cand;
  finally
    Root.Free;
  end;
end;

// Last resort: newest julia-* dir under the juliaup folder holding libjulia.dll.
function NewestJuliaUpBin(const JuliaUp: string): string;
var
  Dirs: TArray<string>;
  Bin: string;
  I: Integer;
begin
  Result := '';
  if not TDirectory.Exists(JuliaUp) then Exit;
  Dirs := TDirectory.GetDirectories(JuliaUp, 'julia-*', TSearchOption.soTopDirectoryOnly);
  TArray.Sort<string>(Dirs);                 // lexical; newest-ish sorts last
  for I := High(Dirs) downto 0 do
  begin
    Bin := TPath.Combine(Dirs[I], 'bin');
    if HasLibJulia(Bin) then Exit(Bin);
  end;
end;

function DiscoverBinDir: string;
var
  Override_, JuliaUp: string;
begin
  Override_ := ExcludeTrailingPathDelimiter(GetEnvironmentVariable('JULIA_BINDIR'));
  if HasLibJulia(Override_) then Exit(Override_);

  JuliaUp := TPath.Combine(DepotDir, 'juliaup');

  Result := BinFromJuliaUpDefault(JuliaUp);
  if HasLibJulia(Result) then Exit;

  Result := NewestJuliaUpBin(JuliaUp);
  if HasLibJulia(Result) then Exit;

  raise EJuliaPaths.CreateFmt(
    'Could not find a Julia install. Set JULIA_BINDIR to the bin dir holding libjulia.dll, ' +
    'or install Julia via juliaup (looked under "%s").', [JuliaUp]);
end;

// -------------------------------------------------------------- version detection

// The sysimage is locked to the Julia version it was built with; the Manifest records it as
// julia_version = "1.12.6". Read it so the required version tracks a rebuild automatically.
function ReadRequiredJulia(const ProjectDir: string): string;
var
  ManifestPath, Line, V: string;
  P: Integer;
begin
  Result := '';
  ManifestPath := TPath.Combine(ProjectDir, 'Manifest.toml');
  if not TFile.Exists(ManifestPath) then Exit;
  for Line in TFile.ReadAllLines(ManifestPath) do
  begin
    V := Line.Trim;
    if V.StartsWith('julia_version') then
    begin
      P := Pos('"', V);
      if P > 0 then
      begin
        V := Copy(V, P + 1, MaxInt);
        P := Pos('"', V);
        if P > 0 then Result := Copy(V, 1, P - 1);
      end;
      Exit;
    end;
  end;
end;

// BinDir is ...\julia-1.12.6+0.x64.w64.mingw32\bin; pull "1.12.6" out of the parent folder name.
function ParseJuliaFromBin(const BinDir: string): string;
var
  Folder, V: string;
  I: Integer;
begin
  Result := '';
  Folder := TPath.GetFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(
              ExcludeTrailingPathDelimiter(BinDir))));   // the julia-* dir (parent of bin)
  if not Folder.StartsWith('julia-') then Exit;
  V := Copy(Folder, Length('julia-') + 1, MaxInt);       // "1.12.6+0.x64..."
  // keep the leading digits-and-dots version, stop at the first '+' / non-version char
  for I := 1 to Length(V) do
    if not CharInSet(V[I], ['0'..'9', '.']) then
    begin
      Result := Copy(V, 1, I - 1);
      Exit;
    end;
  Result := V;
end;

function JuliaVersionMismatch(const Paths: TJuliaPaths): Boolean;
begin
  Result := (Paths.RequiredJulia <> '') and (Paths.DetectedJulia <> '') and
            (Paths.RequiredJulia <> Paths.DetectedJulia);
end;

function BuildDepotPath(const AProjectDir: string): string;
var
  Bundled: string;
begin
  Result := '';
  Bundled := TPath.Combine(AProjectDir, 'depot');
  if not TDirectory.Exists(Bundled) then Exit;
  Result := DepotDir + PathSep + Bundled;
end;

// -------------------------------------------------------------- entry point

function ResolveJuliaPaths: TJuliaPaths;
begin
  Result.ProjectDir := FindProjectDir;
  Result.SysImage   := TPath.Combine(Result.ProjectDir, 'bifsys.dll');
  if not TFile.Exists(Result.SysImage) then
    Result.SysImage := '';           // no sysimage yet -> engine falls back to plain jl_init
  Result.BinDir := DiscoverBinDir;
  Result.RequiredJulia := ReadRequiredJulia(Result.ProjectDir);
  Result.DetectedJulia := ParseJuliaFromBin(Result.BinDir);

  // A shipped depot holding the few native artifacts the sysimage's JLLs need (Arpack_jll,
  // OpenSpecFun_jll). Present in a deployed install, absent in dev (where the user's own depot
  // already has them) -- so this is optional by design.
  Result.BundledDepot := TPath.Combine(Result.ProjectDir, 'depot');
  if not TDirectory.Exists(Result.BundledDepot) then Result.BundledDepot := '';
end;

end.

unit uModelConfig;

{ Analysis settings embedded in an Antimony model as a sentinel /* ... */ comment block.

  Format (INI-style, modeler-friendly):

    /* === Analysis settings - edit the value; text after ; is a note ===
    [bifurcation]
    parameter: B
    max: 45            ; wide range to catch both folds
    maxSteps: 100000   ; large number for the sharp fold
    [simulation]
    end: 100
    plot: S1, S2
    color: #FF56A034
    */
    <the Antimony model follows>

  The value is the text after ':' up to the first ';'; anything after ';' is a free note.
  libantimony strips the comment, so the host parses it from the RAW Antimony text and only
  SBML goes to Julia. On save the block is regenerated from the parsed entries, so notes,
  section order and key order are preserved -- only values change. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

const
  // Known analysis sections. The settings block is identified by CONTAINING one of these as a
  // header line -- NOT by any title text -- so a typo in a decorative title can never stop the
  // block being found. Extend this list when a new analysis type is added.
  CFG_SECTIONS: array[0..1] of string = ('bifurcation', 'simulation');

type
  TModelConfig = class
  private
    type
      TKind = (ekSection, ekPair, ekRaw);
      TEntry = record
        Kind: TKind;
        Section: string;   // ekPair: owning section; ekSection: the name
        Key: string;       // ekPair
        Value: string;     // ekPair
        Note: string;      // ekPair, text after ';' (no leading ';')
        Raw: string;       // ekRaw: verbatim line
      end;
    var
      FPre, FPost: string;     // model text before/after the block
      FHasBlock: Boolean;
      FEntries: TList<TEntry>;
      FWarnings: TStringList;  // human-readable problems found while parsing (typos etc.)
    function FindPair(const ASection, AKey: string; out Idx: Integer): Boolean;
    procedure PutStr(const ASection, AKey, AValue: string);
  public
    constructor Create;
    destructor Destroy; override;

    // Non-fatal issues from the last parse (e.g. an unrecognized [section]). Empty = clean.
    function Warnings: TStrings;

    function GetStr(const ASection, AKey, ADefault: string): string;
    function GetFloat(const ASection, AKey: string; ADefault: Double): Double;
    function GetInt(const ASection, AKey: string; ADefault: Integer): Integer;
    function GetBool(const ASection, AKey: string; ADefault: Boolean): Boolean;

    // Empty AValue removes nothing; it just stores a blank value (e.g. start: = auto).
    procedure SetStr(const ASection, AKey, AValue: string);
    procedure SetFloat(const ASection, AKey: string; AValue: Double);
    procedure SetInt(const ASection, AKey: string; AValue: Integer);
    procedure SetBool(const ASection, AKey: string; AValue: Boolean);

    // Full Antimony text with the settings block rendered from current entries.
    function ToAntimony: string;
  end;

function ParseModelConfig(const AntimonyText: string): TModelConfig;
function LoadModelFile(const FileName: string): TModelConfig;
procedure SaveModelFile(const FileName: string; Cfg: TModelConfig);

implementation

uses
  System.StrUtils, System.IOUtils;

var
  FS_INV: TFormatSettings;   // invariant (dot decimal); set in initialization

{ ------------------------------------------------------------------ TModelConfig }

constructor TModelConfig.Create;
begin
  inherited;
  FEntries := TList<TEntry>.Create;
  FWarnings := TStringList.Create;
end;

destructor TModelConfig.Destroy;
begin
  FEntries.Free;
  FWarnings.Free;
  inherited;
end;

function TModelConfig.Warnings: TStrings;
begin
  Result := FWarnings;
end;

function TModelConfig.FindPair(const ASection, AKey: string; out Idx: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to FEntries.Count - 1 do
    if (FEntries[I].Kind = ekPair) and
       SameText(FEntries[I].Section, ASection) and SameText(FEntries[I].Key, AKey) then
    begin
      Idx := I;
      Exit(True);
    end;
  Idx := -1;
  Result := False;
end;

function TModelConfig.GetStr(const ASection, AKey, ADefault: string): string;
var
  I: Integer;
begin
  if FindPair(ASection, AKey, I) then Result := FEntries[I].Value
  else Result := ADefault;
end;

function TModelConfig.GetFloat(const ASection, AKey: string; ADefault: Double): Double;
begin
  if not TryStrToFloat(Trim(GetStr(ASection, AKey, '')), Result, FS_INV) then
    Result := ADefault;
end;

function TModelConfig.GetInt(const ASection, AKey: string; ADefault: Integer): Integer;
begin
  if not TryStrToInt(Trim(GetStr(ASection, AKey, '')), Result) then
    Result := ADefault;
end;

function TModelConfig.GetBool(const ASection, AKey: string; ADefault: Boolean): Boolean;
var
  S: string;
begin
  S := LowerCase(Trim(GetStr(ASection, AKey, '')));
  if (S = 'yes') or (S = 'true') or (S = '1') or (S = 'on') then Result := True
  else if (S = 'no') or (S = 'false') or (S = '0') or (S = 'off') then Result := False
  else Result := ADefault;
end;

procedure TModelConfig.PutStr(const ASection, AKey, AValue: string);
var
  I, InsertAt: Integer;
  E: TEntry;
begin
  if FindPair(ASection, AKey, I) then
  begin
    E := FEntries[I];
    E.Value := AValue;
    FEntries[I] := E;    // note preserved
    Exit;
  end;

  // Not present: insert after the last entry of the section, or start a new section.
  InsertAt := -1;
  for I := 0 to FEntries.Count - 1 do
    if ((FEntries[I].Kind = ekSection) and SameText(FEntries[I].Section, ASection)) or
       ((FEntries[I].Kind = ekPair) and SameText(FEntries[I].Section, ASection)) then
      InsertAt := I;

  if InsertAt < 0 then
  begin
    E := Default(TEntry); E.Kind := ekSection; E.Section := ASection;
    FEntries.Add(E);
    InsertAt := FEntries.Count - 1;
  end;

  E := Default(TEntry);
  E.Kind := ekPair; E.Section := ASection; E.Key := AKey; E.Value := AValue;
  FEntries.Insert(InsertAt + 1, E);
end;

procedure TModelConfig.SetStr(const ASection, AKey, AValue: string);
begin
  PutStr(ASection, AKey, AValue);
end;

procedure TModelConfig.SetFloat(const ASection, AKey: string; AValue: Double);
begin
  PutStr(ASection, AKey, FloatToStr(AValue, FS_INV));
end;

procedure TModelConfig.SetInt(const ASection, AKey: string; AValue: Integer);
begin
  PutStr(ASection, AKey, IntToStr(AValue));
end;

procedure TModelConfig.SetBool(const ASection, AKey: string; AValue: Boolean);
begin
  if AValue then PutStr(ASection, AKey, 'yes') else PutStr(ASection, AKey, 'no');
end;

function TModelConfig.ToAntimony: string;
var
  SB: TStringBuilder;
  I: Integer;
  E: TEntry;
  Line: string;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('/*').Append(sLineBreak);
    for I := 0 to FEntries.Count - 1 do
    begin
      E := FEntries[I];
      case E.Kind of
        ekSection: SB.Append('[').Append(E.Section).Append(']').Append(sLineBreak);
        ekPair:
          begin
            Line := E.Key + ': ' + E.Value;
            if E.Note <> '' then Line := Line + '   ; ' + E.Note;
            SB.Append(Line).Append(sLineBreak);
          end;
        ekRaw: SB.Append(E.Raw).Append(sLineBreak);
      end;
    end;
    SB.Append('*/');
    // Block goes at the top; model text follows.
    if FHasBlock then
      Result := FPre + SB.ToString + FPost
    else
      Result := SB.ToString + sLineBreak + FPre;   // FPre holds the whole model when no block
  finally
    SB.Free;
  end;
end;

{ ------------------------------------------------------------------ parsing }

// True if the comment body contains a line that is exactly [<known section>] (trimmed,
// case-insensitive). Requires a bracketed header line, so ordinary prose that merely mentions
// a section name in passing won't be mistaken for a settings block.
function BodyHasKnownSection(const Body: string): Boolean;
var
  L: TStringList;
  I: Integer;
  Ln, S: string;
begin
  Result := False;
  L := TStringList.Create;
  try
    L.Text := Body;
    for I := 0 to L.Count - 1 do
    begin
      Ln := LowerCase(Trim(L[I]));
      for S in CFG_SECTIONS do
        if Ln = '[' + S + ']' then Exit(True);
    end;
  finally
    L.Free;
  end;
end;

function IsKnownSection(const Name: string): Boolean;
var
  S: string;
begin
  for S in CFG_SECTIONS do
    if SameText(S, Name) then Exit(True);
  Result := False;
end;

// The bracketed name of the first line that is exactly [word] in any comment block whose word
// is NOT a known section; '' if none. Lets us warn when a block LOOKS like settings but its
// section is mistyped -- which is why it wasn't detected in the first place.
function FirstUnknownBracketSection(const AntimonyText: string): string;
var
  ScanPos, OpenPos, ClosePos, I: Integer;
  Body, Ln, Nm: string;
  L: TStringList;
begin
  Result := '';
  ScanPos := 1;
  while True do
  begin
    OpenPos := PosEx('/*', AntimonyText, ScanPos);
    if OpenPos = 0 then Exit;
    ClosePos := PosEx('*/', AntimonyText, OpenPos + 2);
    if ClosePos = 0 then Exit;
    Body := Copy(AntimonyText, OpenPos + 2, ClosePos - (OpenPos + 2));
    L := TStringList.Create;
    try
      L.Text := Body;
      for I := 0 to L.Count - 1 do
      begin
        Ln := Trim(L[I]);
        if (Length(Ln) >= 3) and (Ln[1] = '[') and (Ln[Length(Ln)] = ']') then
        begin
          Nm := Trim(Copy(Ln, 2, Length(Ln) - 2));
          if not IsKnownSection(Nm) then Exit(Nm);
        end;
      end;
    finally
      L.Free;
    end;
    ScanPos := ClosePos + 2;
  end;
end;

function ParseModelConfig(const AntimonyText: string): TModelConfig;
var
  OpenPos, ClosePos, ScanPos: Integer;
  Body, CurSection: string;
  Lines: TStringList;
  I, P: Integer;
  Raw, Ln, KeyPart, Rest: string;
  E: TModelConfig.TEntry;
begin
  Result := TModelConfig.Create;

  // Find the first /* ... */ that contains a recognized [section] header line. Detection is by
  // section, not by any title -- so a mistyped title cannot stop the block being found.
  ScanPos := 1;
  OpenPos := 0; ClosePos := 0;
  while True do
  begin
    OpenPos := PosEx('/*', AntimonyText, ScanPos);
    if OpenPos = 0 then Break;
    ClosePos := PosEx('*/', AntimonyText, OpenPos + 2);
    if ClosePos = 0 then Break;   // unterminated block: treat as no block
    Body := Copy(AntimonyText, OpenPos + 2, ClosePos - (OpenPos + 2));
    if BodyHasKnownSection(Body) then
    begin
      Result.FHasBlock := True;
      Break;
    end;
    ScanPos := ClosePos + 2;
  end;

  if not Result.FHasBlock then
  begin
    Result.FPre := AntimonyText;    // whole model; block will be prepended on save
    // If a comment looks like settings (a [word] header) but no section was recognized, the
    // section name is probably mistyped -- say so rather than silently loading nothing.
    var Unknown := FirstUnknownBracketSection(AntimonyText);
    if Unknown <> '' then
      Result.FWarnings.Add(Format('No settings loaded: unrecognized section [%s]. ' +
        'Known sections: %s.', [Unknown, string.Join(', ', CFG_SECTIONS)]));
    Exit;
  end;

  Result.FPre  := Copy(AntimonyText, 1, OpenPos - 1);
  Result.FPost := Copy(AntimonyText, ClosePos + 2, MaxInt);

  // Drop the one structural newline that sits right after "/*" (the block open is always on its
  // own line). Otherwise it parses as an empty leading line, is stored as a blank entry, and
  // gets re-added on every save -- so a blank the user deletes keeps coming back.
  if Body.StartsWith(#13#10) then Delete(Body, 1, 2)
  else if Body.StartsWith(#10) then Delete(Body, 1, 1);

  Lines := TStringList.Create;
  try
    Lines.Text := Body;
    CurSection := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Raw := Lines[I];
      Ln := Trim(Raw);
      // No title to skip: any non-section, non-pair line (a decorative header, blank line, or
      // free note) is kept verbatim as ekRaw and round-trips untouched.
      if (Ln <> '') and (Ln[1] = '[') and (Ln[Length(Ln)] = ']') then
      begin
        CurSection := Trim(Copy(Ln, 2, Length(Ln) - 2));
        if not IsKnownSection(CurSection) then
          Result.FWarnings.Add(Format('Unrecognized section [%s] ignored. Known sections: %s.',
            [CurSection, string.Join(', ', CFG_SECTIONS)]));
        E := Default(TModelConfig.TEntry);
        E.Kind := ekSection; E.Section := CurSection;
        Result.FEntries.Add(E);
        Continue;
      end;
      P := Pos(':', Ln);
      if P > 0 then
      begin
        KeyPart := Trim(Copy(Ln, 1, P - 1));
        Rest := Copy(Ln, P + 1, MaxInt);
        E := Default(TModelConfig.TEntry);
        E.Kind := ekPair; E.Section := CurSection; E.Key := KeyPart;
        P := Pos(';', Rest);
        if P > 0 then
        begin
          E.Value := Trim(Copy(Rest, 1, P - 1));
          E.Note  := Trim(Copy(Rest, P + 1, MaxInt));
        end
        else
          E.Value := Trim(Rest);
        Result.FEntries.Add(E);
      end
      else
      begin
        // blank line or free prose inside the block: keep verbatim
        E := Default(TModelConfig.TEntry);
        E.Kind := ekRaw; E.Raw := Raw;
        Result.FEntries.Add(E);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

function LoadModelFile(const FileName: string): TModelConfig;
begin
  Result := ParseModelConfig(TFile.ReadAllText(FileName));
end;

procedure SaveModelFile(const FileName: string; Cfg: TModelConfig);
begin
  TFile.WriteAllText(FileName, Cfg.ToAntimony);
end;

initialization
  FS_INV := TFormatSettings.Invariant;

end.

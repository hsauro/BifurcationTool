unit uBifPlot;

{ Renders a bifurcation result onto a TSkPlotPaintBox.

  Much simpler than the socket project's version, thanks to the updated component:

  - NaN pen-lifts mean the whole branch is just TWO series -- one solid (stable), one dashed
    (unstable) -- each holding all of its runs, separated by NaN, instead of one series per
    run. Stability still can't change mid-series (a series has a single LineStyle), so two
    series is the minimum; NaN removes the need for more.
  - Single-point marker series now render (the old `Data.Count < 2` guard is gone), so a lone
    Hopf needs no duplicate-point hack.
  - AddAnnotation labels the special points in data coordinates (LP1.., H1..).

  Points go in branch order, never sorted by parameter -- sorting would destroy the S-curve. }

interface

uses
  System.SysUtils, System.Math, System.UITypes,
  SkPlotPaintBox, uPlotSeries, uBifResult;

const
  skBifurcation = skData;   // our SeriesKind tag, so ClearSeriesKind touches only our series

{ Add one bifurcation result's series + annotations to the plot WITHOUT clearing or redrawing.
  Use for overlaying several branches (bistable models etc.): clear once, Add each branch,
  Redraw once. ShowLegend should be True for only the first branch so the legend isn't
  duplicated. LabelPrefix distinguishes special-point labels across branches (e.g. 'b2:'). }
procedure AddBifurcationSeries(APlot: TSkPlotPaintBox; const Res: TBifResult;
                               SpeciesIndex: Integer; ShowLegend: Boolean;
                               const LabelPrefix: string = ''; ABranchTag: Integer = 0;
                               AColor: TAlphaColor = TAlphaColors.Royalblue;
                               AShowSpecial: Boolean = True; AFirstSpecies: Boolean = True);

{ Single-branch convenience: clears, adds, redraws. }
procedure PlotBifurcation(APlot: TSkPlotPaintBox; const Res: TBifResult;
                          SpeciesIndex: Integer);

implementation

const
  ColStable   = TAlphaColors.Royalblue;
  ColUnstable = TAlphaColors.Crimson;
  ColFold     = TAlphaColors.Darkorange;
  ColHopf     = TAlphaColors.Seagreen;
  STABLE_LINE_W   = 2.5;   // thick = stable
  UNSTABLE_LINE_W = 1.0;   // thin  = unstable

function NewLineSeries(const AName: string; AColor: TAlphaColor;
                       AStyle: TLineStyle): TPlotSeries;
begin
  Result := TPlotSeries.Create(AName, AColor, False);
  Result.SeriesKind := skBifurcation;
  Result.LineVisible := True;
  Result.LineWidth := 2.0;
  Result.LineStyle := AStyle;
  Result.MarkerVisible := False;
end;

function NewMarkerSeries(const AName: string; AColor: TAlphaColor;
                         AShape: TMarkerShape): TPlotSeries;
begin
  Result := TPlotSeries.Create(AName, AColor, True);
  Result.SeriesKind := skBifurcation;
  Result.LineVisible := False;
  Result.MarkerVisible := True;
  Result.MarkerShape := AShape;
  Result.MarkerSize := 6.0;
  Result.MarkerFillColor := AColor;
  Result.MarkerStrokeColor := TAlphaColors.Black;
  Result.MarkerStrokeWidth := 1.5;
end;

procedure AddBifurcationSeries(APlot: TSkPlotPaintBox; const Res: TBifResult;
                               SpeciesIndex: Integer; ShowLegend: Boolean;
                               const LabelPrefix: string; ABranchTag: Integer;
                               AColor: TAlphaColor; AShowSpecial: Boolean; AFirstSpecies: Boolean);
var
  Stable, Unstable, Cur, Folds, Hopfs: TPlotSeries;
  I: Integer;
  SpeciesName: string;
  V: Double;

  function ValueAt(const U: TArray<Double>): Double;
  begin
    if (SpeciesIndex >= 0) and (SpeciesIndex <= High(U)) then
      Result := U[SpeciesIndex]
    else
      Result := NaN;
  end;

  function SeriesFor(AStable: Boolean): TPlotSeries;
  begin
    if AStable then Result := Stable else Result := Unstable;
  end;

begin
  if Length(Res.Branch) = 0 then
    Exit;

  if (SpeciesIndex >= 0) and (SpeciesIndex <= High(Res.Species)) then
    SpeciesName := Res.Species[SpeciesIndex]
  else
    SpeciesName := 'u';

  // Colour identifies the SPECIES; line WEIGHT identifies stability (thick = stable, thin =
  // unstable). Both solid: the component draws dashed lines segment-by-segment and resets the
  // dash each segment, so dense curves render as broken/near-solid -- weight is reliable, dashes
  // aren't. One legend entry per species (the thick stable line); the thin unstable shares it.
  Stable   := NewLineSeries(SpeciesName,                 AColor, ltSolid);
  Unstable := NewLineSeries(SpeciesName + ' (unstable)', AColor, ltSolid);
  Stable.LineWidth   := STABLE_LINE_W;
  Unstable.LineWidth := UNSTABLE_LINE_W;
  Stable.ShowInLegend := ShowLegend;
  Unstable.ShowInLegend := False;
  // Both series belong to this branch; each plotted point below is tagged with its index in
  // Res.Branch so a pick can recover the full state (Res.Branch[tag].U) and parameter value.
  Stable.Tag := ABranchTag;
  Unstable.Tag := ABranchTag;

  // Draw the branch exactly as the continuation returns it: one point per continuation step,
  // connected in order. No jump/seam heuristics -- BifurcationKit's own plot connects the same
  // points, and every "seam" we chased turned out to be a REAL segment (a sharp fold) traced
  // with too coarse a step. If a fold looks like a straight vertical, lower "Max step size" to
  // resolve it. The only breaks are stability changes: stable and unstable are separate series
  // (each has one LineStyle/colour), so we extend the current run to the shared boundary point
  // and pen-lift (NaN) between a series' separate runs.
  Cur := SeriesFor(Res.Branch[0].Stable);
  Cur.AddXY(Res.Branch[0].P, ValueAt(Res.Branch[0].U), 0);

  for I := 1 to High(Res.Branch) do
  begin
    V := ValueAt(Res.Branch[I].U);
    if Res.Branch[I].Stable <> Res.Branch[I - 1].Stable then
    begin
      Cur.AddXY(Res.Branch[I].P, V, I);       // extend current run to the transition point
      Cur := SeriesFor(Res.Branch[I].Stable);
      if Cur.Data.Count > 0 then Cur.AddXY(NaN, NaN);   // pen-lift, untagged
    end;
    Cur.AddXY(Res.Branch[I].P, V, I);
  end;

  APlot.AddSeries(Stable);
  APlot.AddSeries(Unstable);

  // Special points as marker series + data-anchored labels. MARKERS are drawn for every species
  // (each at its own Y value), so all overlaid curves get their fold/Hopf dots. The text LABELS
  // (LP1, H1) are drawn per species according to AShowSpecial (the host's "which curve is
  // labelled" choice). The single 'fold'/'Hopf' legend entry is emitted once, for the first
  // plotted species (AFirstSpecies), regardless of the label choice.
  if Length(Res.Folds) > 0 then
  begin
    Folds := NewMarkerSeries('fold', ColFold, symCircle);
    Folds.ShowInLegend := ShowLegend and AFirstSpecies;
    for I := 0 to High(Res.Folds) do
    begin
      Folds.AddXY(Res.Folds[I].P, ValueAt(Res.Folds[I].U));
      if AShowSpecial then
        APlot.AddAnnotation(Format('%sLP%d', [LabelPrefix, I + 1]),
                            Res.Folds[I].P, ValueAt(Res.Folds[I].U));
    end;
    APlot.AddSeries(Folds);
  end;

  if Length(Res.Hopfs) > 0 then
  begin
    Hopfs := NewMarkerSeries('Hopf', ColHopf, symDiamond);
    Hopfs.ShowInLegend := ShowLegend and AFirstSpecies;
    for I := 0 to High(Res.Hopfs) do
    begin
      Hopfs.AddXY(Res.Hopfs[I].P, ValueAt(Res.Hopfs[I].U));
      if AShowSpecial then
        APlot.AddAnnotation(Format('%sH%d', [LabelPrefix, I + 1]),
                            Res.Hopfs[I].P, ValueAt(Res.Hopfs[I].U));
    end;
    APlot.AddSeries(Hopfs);
  end;

  // Titles/axis are per-plot, not per-branch; harmless to set on each Add (last wins). Kept
  // species-agnostic since several species may be overlaid -- the legend names them.
  APlot.ChartTitle.Text := 'Bifurcation diagram vs ' + Res.Parameter;
  APlot.XAxisTitle.Text := Res.Parameter;
  APlot.YAxisTitle.Text := '';
  APlot.AutoXScaling := True;
  APlot.AutoYScaling := True;
end;

procedure PlotBifurcation(APlot: TSkPlotPaintBox; const Res: TBifResult;
                          SpeciesIndex: Integer);
begin
  APlot.ClearSeries;
  APlot.ClearAnnotations;
  AddBifurcationSeries(APlot, Res, SpeciesIndex, {ShowLegend=} True);
  APlot.Redraw;   // Redraw, not Repaint: TSkPaintBox caches its surface (see socket project)
end;

end.

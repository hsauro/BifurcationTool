# BifurcationTool — project guide for Claude Code

A Delphi **FMX** desktop app for bifurcation analysis of biochemical/ODE models. The user edits a
model in **Antimony**, computes a bifurcation diagram (continuation), and can click points to run
time-course / phase-plane simulations. Author/user: Herbert Sauro (systems biologist; owns the
RoadRunner / Antimony / Delphi stack). Prefer practical, low-maintenance solutions over
"correct-but-heavy" ones, and keep answers concise.

## Build

Delphi 13 = RAD Studio / BDS **37.0** (`C:\Program Files (x86)\Embarcadero\Studio\37.0\`). Source
`rsvars.bat` before msbuild, wrapped in `cmd /c` so its env survives:

```
cmd /c '"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild BifurcationTool.dproj /t:Build /p:Config=Debug /p:Platform=Win64'
```

- **Project is `BifurcationTool.dproj`** (renamed 2026-07-19 from `BifEmbedGUI.dpr`; the old
  `BifEmbedGUI.dpr` / `BifEmbedTest.dpr` were deleted — the rename was the only practical way to get
  a program icon). Everything else is identical.
- Output: `Win64\Debug\BifurcationTool.exe`. The exe is often left running while testing — kill it
  (`Get-Process BifurcationTool | Stop-Process -Force`) before rebuilding or the link step fails with
  "could not create output file".
- The running app locks the exe; always stop it before building.

## Deployment (Windows zip, no installer)
See **`DEPLOYMENT.md`** (developer: what to ship + prune list + pre-release checklist) and
**`README.md`** (end-user: juliaup install + one-time `Pkg.instantiate()`). Key facts:
- Ship the exe + a **pruned** `julia\` (drop `.rsm`/`.dcu`/old exes, the
  `.dylib`/`.so` in `RoadRunner\src`, and the build scripts; keep `bifsys.dll` ~414 MB, the tomls,
  `BifWorkerCore\`, `RoadRunner\`). `libjulia.dll` is NOT bundled — the user installs Julia.
- **Version lock:** `bifsys.dll` is a sysimage baked against one exact Julia version
  (`Manifest.toml` `julia_version`, currently **1.12.6**). A mismatched Julia can abort the process.
- **Startup check** (`uJuliaPaths` `RequiredJulia`/`DetectedJulia` + `JuliaVersionMismatch`; dialogs
  in `ufMain.FormCreate`): warns + disables Compute (app still opens) on version mismatch or Julia
  not found. `RequiredJulia` is read from the Manifest, so it auto-tracks a sysimage rebuild.
- **Bundled depot (settled 2026-07-20, measured):** exactly TWO `_jll`s resolve into the user depot
  at runtime — `Arpack_jll` and `OpenSpecFun_jll` (1.4 MB total). All other JLLs come from the Julia
  install; the ~50 others in `Manifest.toml` are `Plots`-only and never load. So we **ship those two
  artifacts** as `julia\depot\artifacts\<hash>\` and `uJuliaEngine` sets `JULIA_DEPOT_PATH` =
  `<user depot>;<projectdir>\depot` (user's first so Julia's writes go somewhere writable; artifact
  lookup scans all entries). **Users no longer run `Pkg.instantiate()`.** `BundledDepot` is `''` in
  the dev tree, so dev is unaffected. Re-run the `DEPLOYMENT.md` §6 probe after any sysimage rebuild
  — artifact hashes can change. RoadRunner's own DLLs use `BIFRR_LIBDIR`, not depot artifacts.

## Architecture — who does what

- **Julia is used ONLY for the continuation** (the `BifurcationKit` package). Everything else is
  native Delphi. This split was reached deliberately over the project's life.
- **Embedded Julia**: `uJuliaEngine.pas` loads `libjulia.dll` in-process (bound via `GetProcAddress`),
  runs `jl_init` on ONE long-lived worker thread (jl_init is once-per-process and all Julia calls
  must be on that thread), loads the **`BifWorkerCore`** Julia package, and calls its JSON entry
  point `run_bifurcation_json(json)::String` (string-in/string-out, never throws — solver failure
  comes back as `{"ok":false,...}`). A custom **sysimage** `bifsys.dll` makes startup ~0.5 s.
  - The old HTTP/socket worker mode was **removed** — embedded route only.
  - The worker request path is **SBML-only**; the host converts Antimony→SBML (see below).
  - **Cancelling a running solve** (cooperative — you can't kill the worker thread, and you can't
    call into busy Julia): `BifWorkerCore.CANCEL = Cint[0]` sits at a fixed address; the host reads
    that address once at init (`FCancelFlag`, via `string(UInt(pointer(...)))` eval) and, on the UI
    thread, writes 1 to it (`TJuliaEngine.Cancel`) — a plain memory store, no Julia call. The
    continuation's `finalise_solution` callback polls `CANCEL[1]` each step and returns `false` to
    stop, so the run returns a **partial** branch with `"cancelled":true` (`TBifResult.Cancelled`).
    While busy the **Compute button becomes Cancel** (`SetBusy` + `FEngine.CanCancel`); a second
    click interrupts. `CANCEL` resets to 0 at each run's start. **Changing this needs a sysimage
    rebuild** (`BifWorkerCore` is baked into `bifsys.dll`).
    - Testing gotcha: a plain `CANCEL[1]` read *does* see a cross-thread store (verified) — no
      atomic needed, because the host's store comes from an independent OS thread. But a Julia-only
      test using `Threads.@spawn` + `sleep` to set the flag will look like it fails: the busy
      continuation on thread 1 starves libuv's timer so the `sleep` fires late. Make the test
      canceller **busy-wait**, not sleep. (Confirmed: cancel stops the 200k-point isola at ~940
      points in ~1 s.)
- **Native RoadRunner** (`..\CommonCode\libRoadRunner`, on the dproj search path): steady state and
  simulation run natively via `TRoadRunner` (`uRoadRunner`), no Julia round-trip. `ufMain` keeps a
  persistent `FSimRR: TRoadRunner` cached by SBML (`EnsureSimModel`), reloaded only when the model
  changes.
  - The app points the binding at Julia's DLL so there's ONE `roadrunner_c_api.dll` module:
    `TRoadRunnerAPI.SetLibraryName('julia\RoadRunner\src\roadrunner_c_api.dll')` then
    `loadRoadRunner` in `FormCreate`.
- **Antimony→SBML**: `uAntimonyAPI.getSBMLFromAntimony` (libantimony, loaded in `FormCreate`).
  There is **ONE** `libantimony.dll` in the install, at `julia\RoadRunner\src\` (v3.1.3) — none
  beside the exe. `RoadRunner.jl.__init__` dlopens it from that folder (`BIFRR_LIBDIR`)
  unconditionally, so it must live there; `ufMain` calls
  `setAntimonyLibraryName('julia\RoadRunner\src\libantimony.dll')` (RELATIVE path — see
  [[roadrunner-dll-path-must-stay-relative]]) so the host uses the same file. The
  host always sends SBML to the worker. `uCommonTypes.pas` is a minimal local copy (just
  `TModelErrorState`) so `uAntimonyAPI` links without dragging in extra units.

### Julia tree location
The one real `julia\` folder lives at **`Win64\Debug\julia`** (beside the exe — it's runtime
payload: native DLLs + `bifsys.dll` sysimage + the `BifWorkerCore` and `RoadRunner` packages). No
root copy, no junction. `uJuliaPaths.pas` resolves `<exedir>\julia` at runtime; juliaup supplies
`libjulia.dll` (discovered via `JULIA_BINDIR` / juliaup depot).
- `RoadRunner` is a normal path-dependency at `julia\RoadRunner` (flattened out of the old
  `vendor\RoadRunner`). Its native DLLs live in `RoadRunner\src`.
- **`RoadRunner.jl __init__` resolves its DLL dir from env var `BIFRR_LIBDIR`** (the host sets it to
  `<ProjectDir>\RoadRunner\src`), falling back to `@__DIR__`. This replaced a baked `@__DIR__` path
  that broke on any relocate/deploy. Made durable as `setup.jl` patch 4.
- Rebuild the sysimage after moving the tree or changing baked packages:
  `julia --project=. build_sysimage.jl` (several minutes). **`build_sysimage.jl` must keep
  `cpu_target = PackageCompiler.default_app_cpu_target()`** — PackageCompiler defaults to `"native"`,
  which bakes this box's skylake-avx512 instructions in and makes the image abort on older CPUs.
  Embedded, that abort kills the process with no dialog/exception (`startup.log` just stops at
  `warmup: WaitUntilReady begin`). Verify with `julia -Jbifsys.dll -e "println(:ok)"` on an old machine. Dev test harness: `julia --project=.
  test_worker.jl` (drives the embedded entry points in-process).

## Delphi units
- **`ufMain.pas` / `.fmx`** — the form. Model memo, continuation params, species multi-select,
  Compute / Find steady state / Open / Save, the plot, and the simulation logic.
- **`uBifResult.pas`** — `TBifRequest.ToJson` builds the request; `ParseBifResult` /
  `ParseSteadyResult` parse replies into records. `TBifResult.Branch[i]` has `P`, `U` (independent
  species state), `Stable`.
- **`uBifPlot.pas`** — `AddBifurcationSeries` turns a result into plot series (see plotting below).
- **`uModelConfig.pas`** — model-file settings block parser (see below).
- **`ufSimPlot.pas` / `.fmx`** — the point-simulation popup (time-course / phase-plane). A designed
  form; see the note under Simulation.
- Plotting component: `..\FMX\RhodyComponents\PlottingComponent\Source` (`SkPlotPaintBox`,
  `uPlotSeries`, `uPlotAnnotation`). Skia-based; `GlobalUseSkia := True` in the `.dpr`.

## Model files & the settings block
A model is one Antimony file. Analysis settings live in an **INI-style `/* ... */` comment block**
at the top (libantimony strips it; the host parses the raw text). Open/Save on the form read/write it.
```
/*
[bifurcation]
parameter: B
min: 0.1
max: 45
start:              ; blank = auto-scan for a starting equilibrium
ds: 0.001
dsMax: 0.005
maxSteps: 100000
ymin:               ; blank = auto-scale the Y axis
ymax:
*/
<the Antimony model>
```
- Detected by a recognized **`[section]`** header (`CFG_SECTIONS` = bifurcation/simulation), NOT a
  title — a mistyped/unknown `[section]` is warned about on load (`Cfg.Warnings`).
- `;` ends a value and starts a free note; notes/prose/order are preserved on save (surgical render).
- Colours would use `#RRGGBB`; `;` is the note delimiter.
- Field-load fallbacks: most keys keep the current field if absent, but `ymin`/`ymax` fall back to
  BLANK so loading a model that doesn't specify them clears leftover Y limits.

### Block ↔ edit-box sync (`SyncBlockToFields`)
The edit boxes are the working source of truth; the block is persistence. To stop a **pasted** model
from being ignored (Compute used stale boxes) or silently corrupted (Save wrote stale boxes over the
pasted block — the file then round-tripped the settings out of existence), a shared `SyncBlockToFields`
runs at the top of **Compute** and **Save**:
- It parses the text's `[bifurcation]` block and applies it to the boxes **only if the block changed
  since last applied** — `FLastAppliedBlock` is a signature (`BifBlockSignature`, sentinel default
  distinguishes absent vs blank) baselined on Open and refreshed after Save. So a pasted/hand-edited
  block loads once; manual box tweaks win when the block is unchanged; a plain model with no block
  leaves the boxes alone. Applying shows "Loaded bifurcation settings from the model text."
- **Deliberately NOT live on paste/keystroke** — the boxes update only when you press Compute or Save
  (user-confirmed 2026-07-20), to avoid mid-typing jumpiness.

## Simulation (native, no Julia)
Two independent paths, both native `libRoadRunner` on `FSimRR`:

**1. Point simulation (popup).** Click a branch point → `SimulateAtPoint`. The RoadRunner work lives
in **`RunPointSim(Br, SrcIdx, TEnd, Perturb, NPoints): TSimRun`**: seed the cached `FSimRR` at the
point (`setValue` parameter + species from `Pt.U`), read **eigenvalues** (`getEigenvalues`, 2 cols:
real, imag) to label stable/unstable/oscillatory, **nudge** the state (a branch point is an
equilibrium, so it'd sit still otherwise), `simulateEx(0, tEnd, nPoints)`, and pack the trajectory +
title + eigenvalue subtitle into a `TSimRun` (Ok=False on failure, no exception). `SimulateAtPoint`
reads the main form's **Sim time / Perturb % / Sim points** as STARTING values, builds a closure
`TSimRerunFunc` that captures the point + perturbation, runs it once, and hands both the run and the
closure to `ShowSimulation`.
- The popup can **Re-run at the same point** over a new time/points (its own `nbSimTime`/`nbSimPts` +
  Re-run button call the closure), so the user needn't dismiss it and lose which point they clicked.
  Re-run keeps the current X/Y selections (species set is unchanged).
- Delphi `Format` has **no `+` flag** — build eigenvalue signs by hand (`%+.4g` silently drops the
  argument; this hid imaginary parts once).

**2. Time Course groupbox (main plot).** `btnSimulateClick`: `FSimRR.reset` (initial conditions
back to t=0) → `simulateEx(tStart, tEnd, nPoints)` from `nbTimeStart`/`nbTimeEnd`/`nbNumPoints`. The
run is cached in `FTC*` fields and drawn onto the **main** `SkPlotPaintBox1` (overwriting any
bifurcation diagram). `cboXAxis` (time + species) and `lblTimeCoureSpecies` (checkbox list of
species) are the X/Y pickers; their change events (`cboXAxisChange`,
`lblTimeCoureSpeciesChangeCheck`) replot the cached run without re-simulating.
`PopulateTimeCourseAxes` fills the pickers from the sim's column headers (fenced with
`FUpdatingSpecies` to avoid replot-during-rebuild); `PlotTimeCourse` does the drawing.

### `ufSimPlot` is a designed form (`ufSimPlot.fmx`)
`TSimForm` is a normal designed form. `Top` strip (Align=Top) holds three parts: `leftPanel`
(Align=Left) with `lblX`/`cbX`, `lblY`/`lbY`; `rightPanel` (Align=Right) with `nbSimTime`/`nbSimPts`
+ `btnRerun`; and `memInfo` (Align=Client, the read-only eigenvalue memo) filling the middle. `plot:
TSkPlotPaintBox` is Align=Client on the form. Entry point stays `ShowSimulation` → `TSimForm.Create`
→ `LoadRun(Run, ATEnd, ANPoints, Rerun)` → `Show` (modeless). `FormCreate` borrows the main form's
StyleBook (belt-and-suspenders); `FormClose` sets `caFree` so popups don't accumulate.
- It was **originally built in code via `CreateNew`**, which broke styled-control rendering under
  the global style — the top strip painted as a blank dark block and a `TStyledMemo` refused to
  paint its text at all. Converting to a designed `.fmx` fixed both, so the readout is a real
  read-only `TMemo` again with native select-and-copy.
- **Lay the top strip out with Align (Left/Right/Client panels), NOT absolute positions.** Absolute
  x/y assumed a 760-wide form and fell apart under DPI scaling (at 150% the client is ~505 logical,
  so right-edge controls fell off / the memo overlapped them). Align adapts to any width/DPI.
- `LoadRun` (not `SetData` — that hides a virtual `TFmxObject` method) fills `cbX`/`lbY`, the memo
  and the number boxes, then `Replot`. `cbX.OnChange`/`lbY.OnChangeCheck` → `ReplotEvent` → `Replot`;
  `btnRerun` → the host closure → swap in the new run.
- Registered in the dproj with `<Form>SimForm</Form>`/`<FormType>fmx</FormType>`; not auto-created
  in the `.dpr` (each `ShowSimulation` makes its own instance).

## Plotting conventions
- **Colour = species, line WEIGHT = stability**: thick solid (`STABLE_LINE_W = 2.5`) = stable, thin
  solid (`UNSTABLE_LINE_W = 1.0`) = unstable. (Dashed was abandoned — see below.)
- Fold/Hopf **markers** are drawn on every plotted species (each at its own value); the **text
  labels** (LP1/H1) are governed by the "Show LP/H labels on" combo (a species / `(all)` / `(none)`);
  the fold/Hopf legend entry appears once.
- `TPlotSeries.Draw` builds a **single Skia path** per line (moveTo/lineTo, break on NaN/log-excluded
  points). It used to draw segment-by-segment, which reset dash patterns per segment and doubled a
  round cap at every vertex (fuzzy lines) — fixed 2026-07.
- Pick→data mapping: `TPlotSeries.Tag` = branch index, `AddXY(x,y,tag)` / `SourceTag(i)` = per-point
  `Res.Branch` index, so a click recovers `Pt.P`/`Pt.U`. `AutoYScaling`/`AxisLimits.MinY/MaxY` set
  the Y window (`RedrawAll` applies them after adding series, since each series re-enables auto-Y).
- **`chkOverlay` ("Overlay branches") is deliberately KEPT** (was questioned as dead weight 2026-07-20).
  A single continuation traces one connected component, so it's the only way to show **disconnected**
  branches together — e.g. an **isola** floating above the trivial branch. Reference model: Gray–Scott
  (`dU=F(1-U)-U*V²`, `dV=U*V²-(F+k)V`), continue in `F` at `k=0.04` → nontrivial states form a closed
  isola over `F∈[0.01,0.16]`, disconnected from `V=0`. Overlay = run the isola, tick Overlay, reseed
  ICs to `U=1,V=0`, Compute again. **A closed isola is `maxSteps`-limited** (continuation loops the
  loop, re-flagging specials each lap — set `maxSteps≈220`, not the fold default 100000).

## Example library (`cboExamples`)
Discoverable dropdown, top-right of the `Layout3` strip (anchored `akTop,akRight`). Each entry calls
`LoadExample(text, param, pMin, pMax, start, ds, dsMax, maxSteps, label)`, which loads the model +
fields and does a clean-slate reset (like Open). The model constants have **no `/* [bifurcation] */`
block**, so `LoadExample` sets the fields directly and clears `FLastAppliedBlock` (a later *pasted*
block still syncs). Entries & their verified settings (all headless-checked before wiring in):
- **Schlogl (bistable network)** `SchloglNetModel`, `kin∈[20,28]` → 2 folds (~23.6/~24.4). The
  *genuine* reaction-network form: the cubic is a real trimolecular step `3X->…` (rate `X^3`), not a
  first-order reaction carrying an `X^3` rate. `$A` chemostatted.
- **Gray-Scott (isola)** `GrayScottModel`, `F∈[0,0.25]`, start 0.08, `maxSteps=220` (isola caveat above).
- **Edelstein (bistable enzyme)** `EdelsteinModel`, `A∈[0,12]` → 2 folds (~0.84/~11.7). Bimolecular
  autocatalysis + enzyme sequestration (`E+C` conserved); small basal influx `kb` keeps the low state
  at `X>0` so the S-curve is connected and the auto-scan finds it.
- **Covalent switch (+ feedback)** `CovalentModel`, `k0∈[0,1.2]` → 2 folds (~0.26/~0.76).
  Goldbeter–Koshland MM cycle, kinase activated by its own product (`R+Rp` conserved).
- **Brusselator (Hopf)** / **Oscill8 (folds+Hopf)** / **Tyson-Novak** — the older demos.
- Verifying a new example: drive `BifWorkerCore.run_bifurcation` headlessly and count `folds`
  (2 = bistable); a `-Jbifsys.dll` julia session does this in ~seconds. Don't trust hand-tuned
  params without this — most parameter sets are NOT bistable.

**Equilibrium-only continuation (a real limitation, not a bug).** The worker continues *equilibria*,
never periodic orbits. So a **Hopf shows up only as a stability change** on the equilibrium branch
(stable→unstable), with no limit-cycle amplitude branch drawn. Example: the Brusselator equilibrium
is `X=A=1` for all `B` (flat line) with a Hopf at `B=2`; the branch is fully computed `B∈[1,3]` (thick
to 2, thin after) — it does NOT stop at the Hopf; the thin unstable line is just easy to miss, and
plotting `Y` (slopes 1→3) reads clearer than `X` (flat). To *see* the oscillation, **click the thin
unstable branch**: `SimulateAtPoint` nudges off the equilibrium and the trajectory spirals out to the
limit cycle (needs enough Perturb %/Sim time — the popup's Re-run box tunes this). This is kept as a
teaching aid; Oscill8 is the better Hopf showcase (Hopf on a curvy S-branch with folds).

## Coordinate readout on pick (`SkPlotPaintBox1PointPicked`)
`Label1` shows the clicked point's precise on-curve coordinates — `"<param> = <x>,  <species> = <y>"`
(the pick snaps to a plotted data point, so it's exact). Runs **first, unconditionally**; a pick that
also lands on a real branch point additionally seeds a simulation (`SimulateAtPoint`). The old code
returned early to simulate and so never set the label — that's why the readout "stopped working".

## Gotchas
- Build `BifurcationTool.dproj`, not the old `BifEmbedGUI`.
- Kill the running exe before building.
- The `FindCmdLineSwitch(...,['-','/'])` demo switches (`-tyson`/`-osc`/`-hopf`/`-grayscott`) match a
  SINGLE leading char — use `-tyson`, not `--tyson`. These predate the Examples dropdown (which is the
  discoverable, GUI way in); the switches remain for headless/self-test startup.
- Continuation defaults tuned for sharp folds: ds=0.001, dsMax=0.005, maxSteps=100000.

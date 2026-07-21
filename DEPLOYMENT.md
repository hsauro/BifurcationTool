# DEPLOYMENT.md — packaging BifurcationTool for Windows

Developer notes for building a distributable zip. End-user setup lives in `README.md`; this file is
about *what to ship* and *why*. No installer — a plain zip plus the README.

---

## 1. What the app needs at runtime

| Piece | Where it comes from | Ships in zip? |
|-------|--------------------|:-------------:|
| `BifurcationTool.exe` | `Win64\<Config>\` build output | ✅ |
| **`sk4d.dll`** (Skia) | beside the exe — the IDE puts it there when Skia is enabled | ✅ **required** |
| MSVC runtimes + `zlib.dll` | `julia\RoadRunner\src\` — one copy (14.44.35211.0) | ✅ |
| `libantimony.dll` | `julia\RoadRunner\src\` — **one copy**, shared (see §4.5) | ✅ |
| `julia\` payload | `Win64\Debug\julia\` (sysimage + packages + `depot\`) | ✅ (pruned) |
| `libjulia.dll` + Julia base libs | the **user's** juliaup install (Julia 1.12.6) | ❌ user installs |

> **`sk4d.dll` must be shipped beside the exe.** On Windows, Skia is *not* statically linked — the
> IDE generates the DLL and copies it into the exe folder when Skia is enabled for the project.
> (macOS differs.) It is easy to miss because the dev machine finds it via the Delphi `bin64` on
> PATH. Omitting it fails on a clean machine with Delphi **runtime error 217** — an unhandled
> exception during *unit initialization*, which happens before `FormCreate`, so none of the app's
> own DLL handling or error dialogs ever run. Confirmed on a clean machine 2026-07-21.

The Julia runtime (`libjulia.dll` and friends) is an **external** juliaup install and is
deliberately *not* bundled — see the version lock below.

---

## 2a. Sysimage CPU target (must stay portable)

`build_sysimage.jl` passes **`cpu_target = PackageCompiler.default_app_cpu_target()`**
(`generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)`). **Do not remove it.**

PackageCompiler defaults to `cpu_target = "native"`, which bakes the *build* machine's instruction
set into `bifsys.dll`. This dev box is skylake-avx512, so the default image was rejected on an older
test machine with:

```
ERROR: Unable to find compatible target in cached code image.
Target 0 (skylake-avx512): Rejecting this target due to use of runtime-disabled features
```

From the Julia CLI that's a readable error. **Embedded, it is not:** `jl_init_with_image_file`
aborts the process, so the app window simply vanished with no dialog, no Delphi exception, and (in
one run) no Windows error event. It cost a long debugging session on 2026-07-21 — it looks
identical to a dozen other install faults.

Symptom signature: `startup.log` ends at `warmup: WaitUntilReady begin` with no `FATAL` line.

Confirm on the target machine, with the Delphi app out of the picture. **Set the same two env vars
the app sets** — otherwise the run fails for an unrelated reason (see the note below):

```
$env:JULIA_DEPOT_PATH = "$env:USERPROFILE\.julia;<install>\julia\depot"
$env:BIFRR_LIBDIR     = "<install>\julia\RoadRunner\src"
julia -Jbifsys.dll -e "println(:ok)"
```

Anything other than `ok` means the image is not portable to that CPU. Re-check after every rebuild.

### Building a faster, CPU-specific image (local use only)

The portable image tops out at the **`haswell`** variant, so on an AVX-512 machine (Skylake-X /
Xeon-W — e.g. the i9-9900X this was developed on) those wider instructions go unused by the
sysimage. If you want a faster image *for one machine*, override the target — no need to edit the
script, so the shipped default can't be lost:

```powershell
# Option 1 -- tuned to this machine only. NOT redistributable.
$env:BIFSYS_CPU_TARGET = "native"
julia --project=. build_sysimage.jl

# Option 2 -- portable AND uses AVX-512 where the CPU has it. Safe to ship, but larger again.
$env:BIFSYS_CPU_TARGET = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);skylake-avx512,clone_all"
julia --project=. build_sysimage.jl
```

The build prints its `cpu_target` and **warns** when it isn't the default, so a non-portable image is
obvious in the log. Clear the variable (`Remove-Item Env:\BIFSYS_CPU_TARGET`) before building a
release image.

**Rule of thumb:** anything that does not begin with `generic` must never leave this machine. An
Option 1 image is the exact bug documented above. Option 2 is genuinely shippable — it just trades
more size for an extra code path most users' CPUs won't select.

Temper expectations: **BLAS is unaffected either way.** OpenBLAS dispatches on CPU features at
runtime independently of the sysimage, so the linear algebra already uses AVX-512 on hardware that
has it. The gain here applies only to Julia-compiled code, which for this workload is unlikely to be
dramatic — measure before assuming it's worth a non-standard image.

> **If you omit `JULIA_DEPOT_PATH`** you get a red herring — an `InitError` from `OpenSpecFun_jll`
> saying the artifact "was not found by looking in the paths …", listing only the user depot and the
> Julia install. That is *not* a CPU-target problem and *not* a packaging bug: the app sets
> `JULIA_DEPOT_PATH` at runtime (`uJuliaEngine` via `BuildDepotPath`) so the bundled `julia\depot` is
> searched, and a bare `julia` command does not. Seen on the clean machine 2026-07-21 *after* the app
> itself was already working. It doubles as proof the bundled depot is load-bearing (§3).

## 2. The Julia version lock (important)

`julia\bifsys.dll` is a **PackageCompiler sysimage** baked against one exact Julia version. Loading
it under a different Julia can abort the process, not just error. The required version is recorded in
`julia\Manifest.toml` as `julia_version = "1.12.6"` — that string is the single source of truth.

The app reads it at startup (`uJuliaPaths.ReadRequiredJulia`) and compares it against the version
parsed from the discovered juliaup bin dir (`ParseJuliaFromBin`). On mismatch, `ufMain.FormCreate`
shows a dialog and skips engine start (the app still opens for editing). If you **rebuild the
sysimage against a newer Julia**, this lock updates automatically — just make sure the README's
`juliaup add <ver>` line matches the new `Manifest.toml` version.

---

## 3. The bundled depot (why users don't run `Pkg.instantiate()`)

**Settled 2026-07-20 — measured, not assumed.** Loading `BifWorkerCore` runs every dependency's
`__init__`, which is when artifact paths resolve. Enumerating `Base.loaded_modules` for `*_jll`
showed **exactly two** packages resolve into the user depot:

| JLL | Resolves to | Size |
|-----|-------------|------|
| `Arpack_jll` | `<depot>\artifacts\38145ce8…` (`libarpack.dll`) | 0.68 MB |
| `OpenSpecFun_jll` | `<depot>\artifacts\c1bc0753…` (`libopenspecfun.dll`) | 0.71 MB |

Every other JLL (`OpenBLAS`, `libblastrampoline`, `OpenLibm`, `CompilerSupportLibraries`,
`SuiteSparse`) resolves inside the **Julia install** and needs no depot. The ~50 other `_jll` entries
in `Manifest.toml` (Cairo, FFMPEG, GR/Plots, Xorg…) are there only because `Plots` is a project dep
and are **never loaded at runtime**.

So instead of making users run `Pkg.instantiate()`, we ship those two artifacts (1.4 MB) as
`julia\depot\artifacts\<hash>\` and point Julia at them:

- `uJuliaPaths.BuildDepotPath` returns `<user depot>;<projectdir>\depot`, and
  `uJuliaEngine` sets **`JULIA_DEPOT_PATH`** to it before `jl_init`.
- The **user's depot comes first** so Julia's writes (logs, compile cache) land somewhere writable —
  the app folder may be read-only. Artifact lookup scans *every* entry, so ours is still found.
- `BundledDepot` is `''` when `<projectdir>\depot` doesn't exist (the dev tree), and the engine then
  leaves `JULIA_DEPOT_PATH` alone. So this is deployment-only by construction and dev is unaffected.

**Verified** by running the distribution tree with `JULIA_DEPOT_PATH=<empty dir>;<dist>\julia\depot`:
all 7 JLLs loaded, Arpack/OpenSpecFun resolved to the bundled depot with `isfile=true`.

Re-check this if you ever rebuild the sysimage or change the worker's dependencies — a new dep can
introduce a new artifact. The probe script is in §6.

### Background

The sysimage bakes the *compiled Julia code* for the worker's packages (BifurcationKit, RoadRunner,
JSON3, Accessors, …). It does **not** bundle native `_jll` **artifacts**: a JLL's `__init__`
resolves its native library at runtime against the current Julia depot (`<depot>\artifacts\<hash>`).
If the artifact hash isn't present in *any* depot on `DEPOT_PATH`, loading fails. That's the gap the
bundled depot closes; `Pkg.instantiate()` was the earlier (heavier) way to close it, and is no
longer required of users.

Other notes:
- `BifWorkerCore` and `RoadRunner` are **path dependencies** in the Manifest, pointing at the local
  `julia\BifWorkerCore` / `julia\RoadRunner` folders — nothing to download.
- RoadRunner's own native DLLs are **not** depot artifacts — they live in `julia\RoadRunner\src` and
  are found via the `BIFRR_LIBDIR` env var the host sets. (This is the absolute-path fix from an
  earlier session; it is intact.)
- **Open question worth settling with the clean-machine test (§6):** whether any runtime-loaded
  package (e.g. Arpack_jll / OpenSpecFun_jll via BifurcationKit) actually pulls a depot artifact. If
  the clean test shows Compute works with **no** `instantiate`, you can drop that step from the
  README and setup becomes trivial. Until proven, keep it — it's the safe default.

---

## 4. Building the zip

### 4.1 Build the app

Debug is fine to ship; **Release** is smaller and produces no `.rsm`. Kill any running instance
first (it locks the exe):

```
Get-Process BifurcationTool -ErrorAction SilentlyContinue | Stop-Process -Force
cmd /c '"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild BifurcationTool.dproj /t:Build /p:Config=Debug /p:Platform=Win64'
```

(For a Release build use `/p:Config=Release`; the exe lands in `Win64\Release\` and you'll copy the
`julia\` folder next to it.)

### 4.2 Assemble a staging folder

Copy into a clean folder (e.g. `dist\BifurcationTool\`):

**From `Win64\Debug\`:**
- `BifurcationTool.exe`
- **`sk4d.dll`** — required; see the callout in §1.
- `julia\` — the whole folder, then prune (next step). This carries `libantimony.dll` and the MSVC
  runtimes inside `julia\RoadRunner\src\`; there is deliberately **no** second copy beside the exe
  (see §4.5).

**Add:** `README.md` (rename/keep as the user-facing readme), plus the MS runtime redistributables.

### 4.3 Prune the payload

Delete from the staging copy:

- **`*.rsm`** next to the exe (remote debug symbols, ~65 MB) — never ship.
- **Old/dev exes:** `BifEmbedTest.exe`, `BifEmbedTest.rsm`.
- **`*.dcu`** in the exe folder (compiler intermediates).
- Scratch/test files: `*.png`, the loose `*.txt` sample models (bundle only the ones you *want* as
  starter files, if any).
- Inside **`julia\RoadRunner\src\`**: the non-Windows libraries **`*.dylib`** and **`*.so`**
  (~175 MB of macOS/Linux binaries). Keep `roadrunner_c_api.dll`, `libantimony.dll`, and the `.jl`
  files.
- Inside **`julia\`**: the build-only scripts are optional at runtime and can be removed —
  `build_sysimage.jl`, `precompile_workload.jl`, `test_worker.jl`, `sysimage_build.log`. **Keep**
  `bifsys.dll`, `Project.toml`, `Manifest.toml`, `setup.jl`, `BifWorkerCore\`, `RoadRunner\`.
- The **package folders `julia\RoadRunner\` and `julia\BifWorkerCore\` are full git checkouts** — at
  runtime Julia only needs each package's `Project.toml` + `src\`. Delete the dev/docs/CI cruft:
  - In `julia\RoadRunner\`: `docs\` (~8.3 MB — an mkdocs site with its own `site\`/`src\`/`make.jl`/
    `mkdocs.yml`), `test\`, `.github\`, `.appveyor.yml`, `.travis.yml`, `.gitignore`, `README.md`.
    Keep `Project.toml`, `src\` (with `roadrunner_c_api.dll`, `libantimony.dll`, and the `.jl` files —
    minus the `.dylib`/`.so` above), and `LICENSE` (attribution; tiny).
  - In `julia\BifWorkerCore\`: likewise keep `Project.toml` + `src\`; drop any `test\` / CI files.

**Keep for certain:** `bifsys.dll` (~414 MB — dominates the zip), `Project.toml`, `Manifest.toml`,
`BifWorkerCore\` (`Project.toml` + `src\`), `RoadRunner\` (`Project.toml` + `src\` with Windows DLLs
+ `.jl`), and **`depot\`** (the 1.4 MB of bundled artifacts — see §3; without it the app can't
compute on a machine that never ran `Pkg.instantiate()`).

The bundled depot lives in the **dev tree** (`Win64\Debug\julia\depot`) like everything else, so it
is copied to the distribution along with the rest of `julia\` — there is no separate step to
remember. To (re)create it after a sysimage rebuild, copy the artifact folders out of your own depot
into the DEV tree:

```
$dst = "Win64\Debug\julia\depot\artifacts"
New-Item -ItemType Directory -Force -Path $dst
"38145ce8e6f591161bdfc09a13bb9c9d99a101bf","c1bc0753f7d08c4dcb1f132c45ca0cc509294c81" |
  ForEach-Object { Copy-Item "$env:USERPROFILE\.julia\artifacts\$_" $dst -Recurse -Force }
```

(Confirm the hashes with the §6 probe after any sysimage rebuild — they can change.)

Having it in the dev tree also means the `JULIA_DEPOT_PATH` code path in `uJuliaEngine` actually
runs during development instead of only on a user's install.

Resulting zip is ~450 MB, almost all of it `bifsys.dll`.

### 4.4 Zip it

```
Compress-Archive -Path dist\BifurcationTool\* -DestinationPath BifurcationTool-win64.zip
```

### 4.5 One `libantimony.dll`, in `julia\RoadRunner\src`

The install used to carry **two differently-versioned** copies: one beside the exe for the Delphi
host, and an older one in `julia\RoadRunner\src`. They are now consolidated to a single current
build (**3.1.3** — the larger binary; do not assume file date implies version) living only in
`julia\RoadRunner\src\`.

Why that folder wins: `RoadRunner.jl.__init__` does
`Libdl.dlopen(joinpath(libdir, "libantimony.dll"))` **unconditionally**, where `libdir` is
`BIFRR_LIBDIR` = `<projectdir>\RoadRunner\src`. So the file must exist there or `using RoadRunner`
throws and the engine never starts — even though our worker path is SBML-only and never calls those
bindings. Given it has to be there anyway, the host loads it from there too.

The host side is `uAntimonyAPI.setAntimonyLibraryName('julia\RoadRunner\src\libantimony.dll')`,
called in `ufMain.FormCreate` before `loadAntimonyLibrary` (`libAntimonyName` was already a var; the
setter just exposes it). Note the **relative** path form, matching `roadrunner_c_api.dll` — an
exe-anchored absolute path is known to break DLL loading in this app for reasons never established,
so don't "improve" it.

When refreshing libantimony, replace the copy in `julia\RoadRunner\src\` only. There should be no
`libantimony.dll` beside the exe.

---

## 5. Runtime path resolution (reference)

`uJuliaPaths.ResolveJuliaPaths` finds three things, none hardcoded:

- **Project dir** — `JULIA_PROJECT_DIR` override, else `<exedir>\julia`.
- **Julia bin** (`libjulia.dll`) — `JULIA_BINDIR` override, else juliaup's default channel from
  `<depot>\juliaup\juliaup.json`, else the newest `julia-*` under the juliaup dir. Depot is
  `JULIA_DEPOT_PATH[0]` or `%USERPROFILE%\.julia`.
- **Sysimage** — `<projectdir>\bifsys.dll` (or empty → plain `jl_init` fallback).
- **Bundled depot** — `<projectdir>\depot` if it exists, else `''` (dev). `BuildDepotPath` turns it
  into the `JULIA_DEPOT_PATH` value the engine sets (§3).

Plus the version fields (`RequiredJulia` / `DetectedJulia`) used by the startup check.

---

## 6. Pre-release checklist

- [ ] Build the app; confirm `NNNNN lines, ... 0 Error(s)`.
- [ ] Prune the staging folder per §4.3; confirm no `.rsm` / `.dylib` / `.so` slipped in, and that
      `julia\depot\artifacts\` **is** present.
- [ ] `Manifest.toml`'s `julia_version` matches the `juliaup add <ver>` line in `README.md`.
- [ ] **Artifact probe** — after any sysimage rebuild or dependency change, re-run this against the
      staged tree to confirm the bundled hashes still cover everything. Save as `probe.jl`:

      ```julia
      using BifWorkerCore
      for (id, m) in Base.loaded_modules
          n = string(nameof(m)); endswith(n, "_jll") || continue
          d = isdefined(m, :artifact_dir) ? string(getfield(m, :artifact_dir)) : ""
          println(rpad(n, 30), " -> ", d)
      end
      ```

      Run with an **empty** primary depot so nothing leaks in from your own:

      ```
      $env:JULIA_DEPOT_PATH = "C:\temp\emptydepot;<dist>\julia\depot"
      $env:BIFRR_LIBDIR     = "<dist>\julia\RoadRunner\src"
      julia --project="<dist>\julia" "-J<dist>\julia\bifsys.dll" probe.jl
      ```

      Every JLL must resolve to either the **Julia install** or the **bundled depot** — never to a
      path under the empty depot, and never error.
- [ ] **Clean-machine test** — on a machine (or VM) that has never run Julia: unzip, install juliaup,
      `juliaup add 1.12.6 && juliaup default 1.12.6`, run the app. Compute must succeed on an example
      model with **no** `Pkg.instantiate()`. Then set the juliaup default to a *wrong* version and
      confirm the mismatch dialog fires.
- [ ] Sanity-run each Examples entry; confirm point-click simulation opens.

This mirrors the project's "develop in the exact layout the user gets" principle — the zip *is* the
dev layout minus build cruft.

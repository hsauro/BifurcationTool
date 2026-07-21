module BifWorkerCore

# The bifurcation worker's logic, as a real package rather than a script.
#
# Why a package: PackageCompiler and Julia's own precompilation can only cache native code
# that belongs to a *package*. If run_bifurcation and its F/J closures lived in Main,
# BifurcationKit's specialisations on those closure types could not be baked by anything -- a
# custom sysimage would cut boot time but leave ~11.5 s of JIT on every start. Keeping the code
# in this package makes those specialisations cacheable.
#
# The Delphi host loads this package via embedded libjulia and calls the JSON entry points
# (run_bifurcation_json / steady_state_json / warmup_json) in-process. No HTTP, no subprocess.

using RoadRunner
using BifurcationKit
using Accessors: @optic
using JSON3
using LinearAlgebra: norm

# Cooperative cancel flag. A continuation is a single long blocking call on the one Julia worker
# thread, so the host can't call in to stop it (the thread is busy) and killing the thread would
# corrupt the runtime. Instead this 1-element buffer lives at a fixed address: the host writes 1
# to it from its UI thread (a plain memory store, no Julia call needed), and the per-step callback
# below polls it and returns `false` to stop the continuation. `pointer(CANCEL)` is stable for the
# life of the process (const global, non-moving GC), so the host reads the address once at startup.
const CANCEL = Cint[0]

# The worker is driven only over the embedded (libjulia) route: the Delphi host calls the
# JSON entry points below in-process on a single serialising worker thread, one continuation
# at a time. There is no HTTP server and no concurrency here, so no request lock is needed.

# ---------------------------------------------------------------------------- model setup

"""
Build a RoadRunner instance from SBML and report which species are the state variables.

With conserved moiety analysis on, RoadRunner reduces the system: `getRatesOfChange` returns
rates for the *independent* species only and `getReducedJacobian` is nIndep x nIndep. That
pairing is exactly what BifurcationKit needs. With it off, any model containing a moiety
cycle has a structurally singular Jacobian, Newton will not converge, and fold detection is
meaningless -- so this defaults on.

Note `getFloatingSpeciesIds` still returns *every* floating species regardless, so the
independent set has to come from `getIndependentFloatingSpeciesIds`.
"""
function build_model(; sbml, conserved::Bool = true)
    rr = RoadRunner.createRRInstance()
    try
        # The host (Delphi) owns Antimony->SBML conversion via its own libantimony and always
        # sends SBML, so the worker only ever loads SBML. This drops RoadRunner.jl's bundled
        # libantimony (x86_64-only) from the equation and keeps the worker platform-agnostic.
        RoadRunner.loadSBML(rr, String(sbml))
    catch e
        RoadRunner.freeRRInstance(rr)
        rethrow(e)
    end
    RoadRunner.setComputeAndAssignConservationLaws(rr, conserved)
    indep = RoadRunner.getIndependentFloatingSpeciesIds(rr)
    dep   = conserved ? RoadRunner.getDependentFloatingSpeciesIds(rr) : String[]
    return rr, indep, dep
end

"""
Push the state vector and continuation parameter into RoadRunner.

Only the independent species are set. RoadRunner recomputes the dependent ones from the
conservation relations, holding each conserved total at the value implied by the model's
initial concentrations. That total is therefore *fixed for the whole continuation*: the
diagram is always "at this total", and editing an initial concentration silently selects a
different diagram.
"""
function apply!(rr, indep, u, pname, pval)
    RoadRunner.setValue(rr, pname, Float64(pval))
    @inbounds for i in eachindex(indep)
        RoadRunner.setValue(rr, indep[i], Float64(u[i]))
    end
    return nothing
end

# ------------------------------------------------------------------------------- solving

getj(req, key, default) = haskey(req, key) && req[key] !== nothing ? req[key] : default

"""
Find a parameter value + state vector to start the continuation from — one that is actually an
equilibrium.

The old strategy (try only the model's parameter value, then fall back to raw initial
concentrations) fails badly for oscillators: at the model's parameter value the equilibrium may
be unstable and hard for RoadRunner's steady-state solver to locate, and the initial
concentrations are nowhere near it, so Newton can't start and BifurcationKit just says
"Stopping continuation." (Real example: the Tyson-Novak cell-cycle model at m=1.)

Instead, scan candidate parameter values across the range, run the steady-state solver at each,
and measure the residual ‖du/dt‖. Return the converged candidate closest to the model's own
value (most likely on the branch of interest). Because continuation runs bothside=true, the
exact start doesn't matter for coverage — only that it IS an equilibrium. If nothing converges,
raise an error that says what was tried.
"""
function find_start_point(rr, indep, pname, pmin, pmax, requested)
    modelval = clamp(RoadRunner.getValue(rr, pname), pmin, pmax)

    candidates = Float64[]
    if requested !== nothing
        push!(candidates, clamp(Float64(requested), pmin, pmax))
    else
        push!(candidates, modelval)
        push!(candidates, (pmin + pmax) / 2)
        for i in 0:10
            push!(candidates, pmin + (pmax - pmin) * i / 10)
        end
    end
    candidates = unique(candidates)

    residual_at(c) = begin
        RoadRunner.setValue(rr, pname, c)
        try; RoadRunner.steadyState(rr); catch; end
        u = Float64[RoadRunner.getValue(rr, s) for s in indep]
        r = try; norm(RoadRunner.getRatesOfChange(rr)); catch; Inf; end
        (u, r)
    end

    const_tol = 1e-6     # a real equilibrium
    loose_tol = 1e-3     # good enough for Newton at step 0 to polish
    good = Tuple{Float64, Vector{Float64}}[]   # (param, u) with residual < const_tol
    bestp = NaN; bestu = Float64[]; bestr = Inf
    tried = String[]

    for c in candidates
        u, r = residual_at(c)
        push!(tried, string(round(c, sigdigits = 4), " (r=",
                            isfinite(r) ? string(round(r, sigdigits = 2)) : "inf", ")"))
        if r < bestr; bestr = r; bestp = c; bestu = u; end
        r < const_tol && push!(good, (c, u))
    end

    if !isempty(good)
        # Closest converged start to the model's own parameter value.
        _, i = findmin([abs(g[1] - modelval) for g in good])
        return good[i]
    end
    bestr < loose_tol && return (bestp, bestu)

    error("Could not find a steady state to start the continuation of '$pname' in " *
          "[$pmin, $pmax]. Tried $pname = " * join(tried, ", ") *
          " (r = ‖du/dt‖ at the solver's best point; it should be ~0 at an equilibrium). " *
          "The model may have no steady state in this range, or the equilibrium is too hard " *
          "to locate from the current initial conditions — try a narrower range, or set the " *
          "model's variables near a known steady state.")
end

function run_bifurcation(req)
    sbml = getj(req, :sbml, nothing)
    sbml === nothing && error("request is missing 'sbml' (the host converts Antimony to SBML)")
    pname = getj(req, :parameter, nothing)
    pname === nothing && error("request is missing 'parameter'")
    pname = String(pname)

    # Validate what can be checked without touching roadrunner first, so these report their
    # own error rather than whatever the model build happens to fail on.
    pmin = Float64(getj(req, :pMin, nothing))
    pmax = Float64(getj(req, :pMax, nothing))
    pmin < pmax || error("pMin ($pmin) must be less than pMax ($pmax)")

    conserved = Bool(getj(req, :conservedMoieties, true))
    rr, indep, dep = build_model(; sbml = sbml, conserved = conserved)

    try
        if isempty(indep)
            error("The model has no floating species to continue. If you entered ODEs like " *
                  "\"x' = ...\", Antimony turns those into rate rules on parameters, which have " *
                  "no steady-state machinery. Rewrite each ODE as a reaction whose rate is the " *
                  "right-hand side, e.g.  -> x; <rhs>  (SBML allows negative rates).")
        end

        params = RoadRunner.getGlobalParameterIds(rr)
        if !(pname in params)
            avail = join(params, ", ")
            error("'$pname' is not a parameter of this model. Available parameters: $avail")
        end

        # Starting point. If the caller supplied an explicit startState (e.g. from the
        # "Find steady state" button), seed the continuation directly from it -- this is the
        # deterministic, user-controlled way to pick a branch. startState is a full
        # floating-species vector in getFloatingSpeciesIds order. Otherwise scan for a start
        # (find_start_point), honouring an explicit pStart if given.
        startState = getj(req, :startState, nothing)
        if startState !== nothing
            sids = RoadRunner.getFloatingSpeciesIds(rr)
            for i in eachindex(sids)
                i <= length(startState) && RoadRunner.setValue(rr, sids[i], Float64(startState[i]))
            end
            pstart = Float64(getj(req, :pStart, RoadRunner.getValue(rr, pname)))
            (pmin <= pstart <= pmax) ||
                error("pStart ($pstart) must lie within [pMin, pMax] = [$pmin, $pmax]")
            RoadRunner.setValue(rr, pname, pstart)
            u0 = Float64[RoadRunner.getValue(rr, s) for s in indep]
        else
            pstart, u0 = find_start_point(rr, indep, pname, pmin, pmax, getj(req, :pStart, nothing))
        end

        F(u, par) = (apply!(rr, indep, u, pname, par.p); RoadRunner.getRatesOfChange(rr))
        J(u, par) = (apply!(rr, indep, u, pname, par.p); RoadRunner.getReducedJacobian(rr))

        prob = BifurcationProblem(F, u0, (p = pstart,), (@optic _.p);
                                  J = J,
                                  record_from_solution = (x, p; k...) -> (u = copy(x),))

        # Defaults tuned for stiff biochemical models. dsMax=0.01 (the old value) was too fine:
        # continuation crawled through stiff regions, burned the step budget, and covered only
        # part of the branch. ds=0.005 / dsMax=0.05 / maxSteps=20000 traces the full Tyson-Novak
        # diagram (all folds + Hopfs over [-10,10]) while still locating bifurcations exactly
        # (BifurcationKit bisects to pin them down regardless of step size). Callers can override.
        opts = ContinuationPar(
            p_min = pmin, p_max = pmax,
            ds       = Float64(getj(req, :ds, 0.005)),
            dsmax    = Float64(getj(req, :dsMax, 0.05)),
            dsmin    = Float64(getj(req, :dsMin, 1e-7)),
            max_steps = Int(getj(req, :maxSteps, 20000)),
            detect_bifurcation = 3,
            n_inversion = 8,
            newton_options = NewtonPar(tol = Float64(getj(req, :newtonTol, 1e-10)),
                                       max_iterations = 25))

        # Reset the cancel flag for this run, then poll it once per continuation step. Returning
        # false stops the continuation gracefully (BifurcationKit returns the partial branch, no
        # exception), which is how the host interrupts a runaway solve (e.g. a closed isola that
        # would otherwise lap forever up to maxSteps).
        CANCEL[1] = 0
        stop_if_cancelled = (z, tau, step, contResult; kwargs...) -> (CANCEL[1] == 0)

        local br
        try
            br = continuation(prob, PALC(), opts; bothside = true,
                              finalise_solution = stop_if_cancelled)
        catch e
            msg = sprint(showerror, e)
            error("The continuation could not complete (started from $pname=$(round(pstart, sigdigits=4)); " *
                  "BifurcationKit: \"$msg\"). This usually means the branch hit a point where " *
                  "Newton lost the equilibrium -- often a very sharp fold, or a stiff region. " *
                  "Try a narrower [$pmin, $pmax] range, a smaller max step (dsMax), or a " *
                  "different start.")
        end

        ps = [pt.param  for pt in br.branch]
        us = [pt.u      for pt in br.branch]
        stable = [pt.stable for pt in br.branch]

        points = [Dict("p" => ps[i], "u" => us[i], "stable" => stable[i])
                  for i in eachindex(ps)]

        # A fold is where the branch reverses direction in the parameter. We detect it that
        # way rather than trusting BK's labels: with detect_bifurcation >= 2 BK disables its
        # own tangent-based fold test to avoid duplicates, and reports a saddle-node as :bp.
        folds = Dict{String,Any}[]
        for i in 2:length(ps)-1
            if (ps[i] - ps[i-1]) * (ps[i+1] - ps[i]) < 0
                push!(folds, Dict("p" => ps[i], "u" => us[i]))
            end
        end

        hopfs = Dict{String,Any}[]
        for sp in br.specialpoint
            if sp.type == :hopf
                push!(hopfs, Dict("p" => sp.param, "u" => copy(sp.printsol.u)))
            end
        end

        return Dict(
            "ok"          => true,
            "parameter"   => pname,
            "species"     => indep,
            "dependent"   => dep,
            "conserved"   => conserved,
            "branch"      => points,
            "folds"       => folds,
            "hopfs"       => hopfs,
            "nPoints"     => length(points),
            "cancelled"   => (CANCEL[1] != 0),   # host stopped this run early; branch is partial
        )
    finally
        RoadRunner.freeRRInstance(rr)
    end
end

# ---------------------------------------------------------------- string-in/string-out entry
#
# The entry point for the EMBEDDED route (Delphi calling libjulia directly, no HTTP server).
# Delphi hands over the request as a JSON string and gets the result back as a JSON string, so
# the Delphi side reuses exactly the same ParseResult it uses for the socket worker.
#
# Never throws: a bad request or a solver failure comes back as {"ok":false,"error":...}, so
# the caller always receives parseable JSON and a Julia exception never propagates across the
# C ABI (which would be undefined behaviour).
function run_bifurcation_json(json::AbstractString)::String
    try
        req = JSON3.read(String(json))
        return JSON3.write(run_bifurcation(req))
    catch e
        return JSON3.write(Dict("ok" => false, "error" => sprint(showerror, e)))
    end
end

"""
    warmup_json(json) -> String

Internal warm-up entry for the embedded (libjulia) engine. Unlike the production request path
(SBML-only, the host converts), this accepts an Antimony model and converts it here via `loada`:
the host's fixed warm-up fixture is written as Antimony for readability, and warming is an
internal concern, not the host<->worker protocol. Runs the same continuation as a real request
so the JIT cost is paid once at startup. Returns the same JSON shape as run_bifurcation_json.
"""
function warmup_json(json::AbstractString)::String
    try
        req = JSON3.read(String(json))
        d = Dict{Symbol,Any}()
        for (k, v) in pairs(req); d[k] = v; end
        if !haskey(d, :sbml) && haskey(d, :antimony)
            d[:sbml] = _sbml(String(d[:antimony]))
            delete!(d, :antimony)
        end
        return JSON3.write(run_bifurcation(d))
    catch e
        return JSON3.write(Dict("ok" => false, "error" => sprint(showerror, e)))
    end
end

"""
    steady_state_json(json) -> String

Compute the steady state of the model at a given parameter value, starting from the model's
initial conditions -- what the "Find steady state" button calls. Returns the full floating
species state (in getFloatingSpeciesIds order, so it can be fed straight back as `startState`)
plus the residual and whether it converged. This lets the caller (a) preview which branch a
seed lands on and (b) hand the continuation a guaranteed-good starting point.
"""
function steady_state_json(json::AbstractString)::String
    try
        req = JSON3.read(String(json))
        sbml = getj(req, :sbml, nothing)
        sbml === nothing && error("request is missing 'sbml' (the host converts Antimony to SBML)")
        pname = getj(req, :parameter, nothing)
        pname === nothing && error("request is missing 'parameter'")
        pname = String(pname)
        conserved = Bool(getj(req, :conservedMoieties, true))

        rr, indep, dep = build_model(; sbml = sbml, conserved = conserved)
        try
            params = RoadRunner.getGlobalParameterIds(rr)
            (pname in params) ||
                error("'$pname' is not a parameter of this model. Available: $(join(params, ", "))")

            pval = Float64(getj(req, :pStart, RoadRunner.getValue(rr, pname)))
            RoadRunner.setValue(rr, pname, pval)
            solved = true
            try
                RoadRunner.steadyState(rr)
            catch
                solved = false   # report it; the state is left at the solver's best effort
            end
            sids = RoadRunner.getFloatingSpeciesIds(rr)
            vals = Float64[RoadRunner.getValue(rr, s) for s in sids]
            resid = try; norm(RoadRunner.getRatesOfChange(rr)); catch; NaN; end
            return JSON3.write(Dict(
                "ok"        => true,
                "parameter" => pname,
                "pValue"    => pval,
                "species"   => sids,
                "state"     => vals,
                "residual"  => resid,
                "converged" => solved && isfinite(resid) && resid < 1e-6))
        finally
            RoadRunner.freeRRInstance(rr)
        end
    catch e
        return JSON3.write(Dict("ok" => false, "error" => sprint(showerror, e)))
    end
end

# ------------------------------------------------------------------------ internal warm-up
#
# Convert Antimony to SBML for the worker's own fixed precompile/warm-up fixtures. The request
# path is SBML-only (the host converts), but these internal fixtures are written as Antimony
# for readability, so they convert themselves here.
_sbml(antimony::AbstractString) = RoadRunner.getCurrentSBML(RoadRunner.loada(String(antimony)))


# ---------------------------------------------------------------- precompile

# Run a real continuation at precompile time so the native code is cached into this package's
# pkgimage. This is what removes the ~11.5 s of JIT from worker startup -- and, unlike a custom
# sysimage, it costs nothing at runtime and no 466 MB artifact.
using PrecompileTools

@setup_workload begin
    ant = """
        J1: -> X;  B;
        J2: X -> ; a3*X;
        J3: -> X;  a2*X^2;
        J4: X -> ; a1*X^3;
        X = 1.7; B = 23.0; a1 = 1.0; a2 = 9.0; a3 = 26.0;
    """
    cons = "J1: S1 -> S2; k1*S1; J2: S2 -> S1; k2*S2; S1=3; S2=1; k1=0.4; k2=0.9;"
    @compile_workload begin
        try
            reqs = (
                Dict(:sbml => _sbml(ant), :parameter => "B", :pMin => 23.0, :pMax => 25.0,
                     :pStart => 23.0, :ds => 0.001, :dsMax => 0.005, :maxSteps => 5000),
                Dict(:sbml => _sbml(cons), :parameter => "k1", :pMin => 0.1, :pMax => 2.0,
                     :pStart => 0.4, :ds => 0.001, :dsMax => 0.005, :maxSteps => 5000),
            )
            for req in reqs
                res = run_bifurcation(JSON3.read(JSON3.write(req)))
                JSON3.write(res)
                # Also the string-in/string-out entries the embedded (libjulia) route calls,
                # so their first real call is baked, not JIT'd.
                run_bifurcation_json(JSON3.write(req))
                steady_state_json(JSON3.write(req))
            end
        catch e
            # Precompilation must never fail the build. If roadrunner cannot be driven at
            # precompile time, we just fall back to JIT at runtime.
            @debug "precompile workload skipped" exception = e
        end
    end
end

end # module BifWorkerCore

# Exercises BifWorkerCore's embedded (libjulia) entry points in-process -- the same JSON-in/
# JSON-out calls the Delphi host makes. No socket, no subprocess.
#
#   julia --project=. test_worker.jl

using Pkg
Pkg.activate(@__DIR__)
using JSON3, RoadRunner, BifWorkerCore

const HERE = @__DIR__

# Delphi will do this conversion with its own libantimony; here we just need SBML to feed in.
function antimony_to_sbml(ant::String)
    rr = RoadRunner.loada(ant)
    return RoadRunner.getCurrentSBML(rr)
end

# One request: JSON in, JSON out, straight into the embedded entry point Delphi calls.
post(body) = JSON3.read(BifWorkerCore.run_bifurcation_json(JSON3.write(body)))

failures = String[]
check(cond, label) = (println(cond ? "  PASS  " : "  FAIL  ", label); cond || push!(failures, label))

try
    # ------------------------------------------------------- bistable / hysteresis case
    println("\n[bistable Schloegl cubic: dX/dt = B - a3*X + a2*X^2 - a1*X^3]")
    sbml = antimony_to_sbml("""
        J1: -> X;  B;
        J2: X -> ; a3*X;
        J3: -> X;  a2*X^2;
        J4: X -> ; a1*X^3;
        X = 1.7; B = 23.0; a1 = 1.0; a2 = 9.0; a3 = 26.0;
    """)
    r = post(Dict("sbml" => sbml, "parameter" => "B",
                  "pMin" => 23.0, "pMax" => 25.0, "pStart" => 23.0,
                  "ds" => 0.001, "dsMax" => 0.005))
    check(r.ok == true, "bistable request ok" * (r.ok ? "" : " -- $(get(r, :error, ""))"))
    if r.ok
        check(collect(r.species) == ["X"], "state variable is X")
        check(r.nPoints > 100, "branch has points (got $(r.nPoints))")
        check(length(r.folds) == 2, "two folds found (got $(length(r.folds)))")
        if length(r.folds) == 2
            fp = sort([f.p for f in r.folds])
            fu = sort([f.u[1] for f in r.folds])
            println("      folds at B = ", fp)
            println("      folds at X = ", fu)
            check(isapprox(fp[1], 23.6151, atol=1e-3), "lower fold B ~ 23.6151")
            check(isapprox(fp[2], 24.3849, atol=1e-3), "upper fold B ~ 24.3849")
            check(isapprox(fu[1], 2.4226,  atol=1e-3), "fold X ~ 2.4226")
            check(isapprox(fu[2], 3.5774,  atol=1e-3), "fold X ~ 3.5774")
        end
        nstab = count(p -> p.stable, r.branch)
        check(0 < nstab < r.nPoints, "branch has both stable and unstable segments ($nstab/$(r.nPoints))")
    end

    # ------------------------------------- request path is SBML-only (host converts Antimony)
    r7 = post(Dict("parameter" => "B", "pMin" => 0.0, "pMax" => 1.0))
    check(r7.ok == false && occursin("missing 'sbml'", r7.error), "missing model rejected")

    # ---------------------------------------------------------------- Hopf: Brusselator
    #
    #   dX/dt = A - (B+1)X + X^2*Y,  dY/dt = B*X - X^2*Y
    #   X* = A, Y* = B/A;  det J = A^2 > 0 always;  tr J = B - 1 - A^2
    #   => Hopf exactly at B = 1 + A^2. With A = 1: Hopf at B = 2, X = 1, Y = 2, and no folds.
    #
    # J3 is written "Y -> X" rather than "2X + Y -> 3X": the net effect on each species is
    # identical (+1 X, -1 Y) and it keeps X off both sides of the arrow.
    println("\n[Hopf: Brusselator, analytic Hopf at B=2]")
    rh = post(Dict("sbml" => antimony_to_sbml("""
            J1: -> X;   A;
            J2: X -> Y; B*X;
            J3: Y -> X; X^2*Y;
            J4: X -> ;  X;
            A = 1.0; B = 1.0; X = 1.0; Y = 1.0;
        """), "parameter" => "B", "pMin" => 1.0, "pMax" => 3.0, "pStart" => 1.0,
            "ds" => 0.001, "dsMax" => 0.005))
    check(rh.ok == true, "brusselator ok" * (rh.ok ? "" : " -- $(get(rh, :error, ""))"))
    if rh.ok
        check(collect(rh.species) == ["X", "Y"], "two state variables (got $(collect(rh.species)))")
        check(length(rh.hopfs) == 1, "exactly one Hopf found (got $(length(rh.hopfs)))")
        check(length(rh.folds) == 0, "no folds (got $(length(rh.folds)))")
        if length(rh.hopfs) == 1
            h = rh.hopfs[1]
            println("      Hopf at B = ", h.p, "  u = ", collect(h.u))
            check(isapprox(h.p, 2.0, atol = 1e-4), "Hopf at B = 2 (got $(h.p))")
            check(isapprox(h.u[1], 1.0, atol = 1e-6), "X = A = 1 at the Hopf (got $(h.u[1]))")
            check(isapprox(h.u[2], 2.0, atol = 1e-4), "Y = B/A = 2 at the Hopf (got $(h.u[2]))")
        end
        # X* = A for every B, so the branch is flat in X and only stability changes.
        check(all(p -> isapprox(p.u[1], 1.0, atol = 1e-6), rh.branch),
              "X stays at A=1 along the whole branch")
        nstab = count(p -> p.stable, rh.branch)
        check(0 < nstab < length(rh.branch),
              "stability changes across the Hopf ($nstab/$(length(rh.branch)))")
    end

    # ------------------------------------------------- conserved moiety model must reduce
    println("\n[conserved moiety: S1 <-> S2, total fixed]")
    sbml2 = antimony_to_sbml("J1: S1 -> S2; k1*S1; J2: S2 -> S1; k2*S2; S1=3; S2=1; k1=0.4; k2=0.9;")
    r2 = post(Dict("sbml" => sbml2, "parameter" => "k1", "pMin" => 0.1, "pMax" => 2.0, "pStart" => 0.4))
    check(r2.ok == true, "conserved model ok" * (r2.ok ? "" : " -- $(get(r2, :error, ""))"))
    if r2.ok
        check(collect(r2.species) == ["S1"], "state reduced to independent species only (got $(collect(r2.species)))")
        check(collect(r2.dependent) == ["S2"], "S2 reported as dependent")
        # analytic: S1* = k2*T/(k1+k2), T=4
        last_pt = r2.branch[end]
        expect = 0.9 * 4.0 / (last_pt.p + 0.9)
        check(isapprox(last_pt.u[1], expect, rtol=1e-6),
              "steady state matches analytic k2*T/(k1+k2)  (got $(last_pt.u[1]), want $expect)")
    end

    # --------------------------------------------------------------------- error handling
    println("\n[errors are reported, not fatal]")
    r3 = post(Dict("sbml" => sbml, "parameter" => "NoSuchParam", "pMin" => 0.0, "pMax" => 1.0))
    check(r3.ok == false && occursin("is not a parameter", r3.error), "unknown parameter rejected")

    r4 = post(Dict("sbml" => "this is not sbml", "parameter" => "B", "pMin" => 0.0, "pMax" => 1.0))
    check(r4.ok == false, "garbage SBML rejected")

    r5 = post(Dict("sbml" => sbml, "parameter" => "B", "pMin" => 25.0, "pMax" => 23.0))
    check(r5.ok == false && occursin("must be less than", r5.error), "reversed range rejected")

    println("\n[worker still responsive after those errors]")
    r6 = post(Dict("sbml" => sbml, "parameter" => "B", "pMin" => 23.0, "pMax" => 25.0))
    check(r6.ok == true, "still responsive after bad requests")

finally
    # nothing to tear down: the worker runs in-process
end

println()
if isempty(failures)
    println("ALL TESTS PASSED")
else
    println("FAILURES (", length(failures), "):")
    foreach(f -> println("  - ", f), failures)
    exit(1)
end

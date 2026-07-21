# Workload traced while building the sysimage.
#
# Drives BifWorkerCore's embedded (libjulia) entry points directly -- the same calls the Delphi
# host makes. There is no HTTP server to exercise; the worker runs in-process only.
#
# Note BifWorkerCore also carries a PrecompileTools @compile_workload, which caches this same
# code into its pkgimage during ordinary precompilation. That alone gets worker start to
# ~8.5 s with no sysimage at all. This file exists so create_sysimage traces the same paths
# when a sysimage is also wanted.

using BifWorkerCore
using JSON3

# The request path is SBML-only (the host converts Antimony->SBML). These fixtures are written
# as Antimony for readability and convert themselves via the worker's own helper.
_sbml = BifWorkerCore._sbml

const _MODELS = [
    # bistable, two folds, no conserved moiety
    Dict(:sbml => _sbml("""
            J1: -> X;  B;
            J2: X -> ; a3*X;
            J3: -> X;  a2*X^2;
            J4: X -> ; a1*X^3;
            X = 1.7; B = 23.0; a1 = 1.0; a2 = 9.0; a3 = 26.0;
         """),
         :parameter => "B", :pMin => 23.0, :pMax => 25.0, :pStart => 23.0,
         :ds => 0.001, :dsMax => 0.005, :maxSteps => 5000),

    # conserved moiety, so the reduced-jacobian path gets traced too
    Dict(:sbml => _sbml("J1: S1 -> S2; k1*S1; J2: S2 -> S1; k2*S2; S1=3; S2=1; k1=0.4; k2=0.9;"),
         :parameter => "k1", :pMin => 0.1, :pMax => 2.0, :pStart => 0.4,
         :ds => 0.001, :dsMax => 0.005, :maxSteps => 5000),
]

for m in _MODELS
    js = JSON3.write(m)
    BifWorkerCore.run_bifurcation(JSON3.read(js))
    # The string-in/string-out entries the host actually calls.
    BifWorkerCore.run_bifurcation_json(js)
    BifWorkerCore.steady_state_json(js)
end

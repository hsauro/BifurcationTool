# One-time setup for the bifurcation worker's Julia environment.
#
# Vendors RoadRunner.jl into ./vendor/RoadRunner with two local patches:
#
#   1. Removes the spurious `Documenter = "0.25.2"` runtime dependency. Documenter is
#      never referenced in RoadRunner's src/ (only in docs/), but that 2020-era pin holds
#      DocStringExtensions at 0.8, which blocks BifurcationKit 0.8. Pkg then silently
#      resolves BifurcationKit down to 0.7.1, which pulls BlockArrays 0.16, which fails to
#      precompile on Julia 1.12 ("too many parameters for type AbstractTriangular").
#
#   2. Adds getIndependentFloatingSpeciesIds / getDependentFloatingSpeciesIds. Both symbols
#      are already exported by the roadrunner_c_api.dll that RoadRunner.jl ships (verified
#      with dlsym) and are wrapped by the Delphi bindings -- the Julia bindings just never
#      wrapped them. We need the independent set to build the state vector when conserved
#      moiety analysis is on.
#
# Both patches are good upstream PRs against sys-bio/RoadRunner.jl; this vendoring is a
# stopgap until then.
#
# Run once:   julia setup.jl

using Pkg

const HERE   = @__DIR__
const VENDOR = joinpath(HERE, "RoadRunner")

# ---------------------------------------------------------------- locate installed source
function find_installed_roadrunner()
    root = joinpath(homedir(), ".julia", "packages", "RoadRunner")
    if !isdir(root)
        # Not installed yet: pull it into a temp env purely to populate the depot.
        @info "RoadRunner not in depot; fetching it once so we can vendor the source."
        Pkg.activate(temp = true)
        Pkg.add("RoadRunner")
    end
    isdir(root) || error("RoadRunner still not found in depot at $root")
    best, bestver = nothing, v"0"
    for d in readdir(root)
        p = joinpath(root, d, "Project.toml")
        isfile(p) || continue
        m = match(r"^version\s*=\s*\"([^\"]+)\""m, read(p, String))
        m === nothing && continue
        v = VersionNumber(m.captures[1])
        if v > bestver
            best, bestver = joinpath(root, d), v
        end
    end
    best === nothing && error("no versioned RoadRunner source found under $root")
    @info "Vendoring RoadRunner $bestver from $best"
    return best
end

src = find_installed_roadrunner()

isdir(VENDOR) && rm(VENDOR, recursive = true, force = true)
mkpath(dirname(VENDOR))
cp(src, VENDOR)

# The depot is read-only. Make only the two files we edit writable -- do NOT chmod the whole
# tree: stripping the exec bit off the bundled DLLs makes LoadLibrary fail with
# "Access is denied".
proj    = joinpath(VENDOR, "Project.toml")
mainsrc = joinpath(VENDOR, "src", "RoadRunner.jl")
chmod(proj, 0o644)
chmod(mainsrc, 0o644)

# ------------------------------------------------------------------ patch 1: Documenter
txt = read(proj, String)
before = txt
txt = replace(txt, r"Documenter\s*=\s*\"e30172f5-a6a5-5a46-863b-614d45cd2de4\"\r?\n" => "")
txt = replace(txt, r"Documenter\s*=\s*\"0\.25\.2\"\r?\n" => "")
txt == before && @warn "Documenter lines not found in Project.toml -- upstream may have fixed it."
write(proj, txt)
occursin("Documenter", read(proj, String)) && error("failed to strip Documenter from Project.toml")

# ------------------------------------------- patch 2: independent/dependent species wrappers
wrappers = """

###############################################################################
#     Independent / dependent floating species ids  (added locally)
#
#  Both symbols are exported by roadrunner_c_api but were never wrapped by
#  RoadRunner.jl. With conserved moiety analysis enabled, getFloatingSpeciesIds
#  still returns *every* floating species, so it cannot tell you which ones are
#  the independent variables. These can.
###############################################################################

\"\"\"
Convert an RRStringArray to a Vector{String} and free it.

Note roadrunner hands back NULL, not an empty array, when the list is legitimately empty --
getDependentFloatingSpeciesIds does exactly that for a model with no conserved moieties. So
NULL means "none", not "error".
\"\"\"
function _rr_string_array(data::Ptr{RRStringArray})
  data == C_NULL && return String[]
  ids = String[]
  try
    for i = 1:getNumberOfStringElements(data)
      push!(ids, getStringElement(data, i - 1))
    end
  finally
    freeStringArray(data)
  end
  return ids
end

function getIndependentFloatingSpeciesIds(rr::Ptr{Nothing})
  return _rr_string_array(ccall(dlsym(rrlib, :getIndependentFloatingSpeciesIds), cdecl,
                                Ptr{RRStringArray}, (Ptr{Nothing},), rr))
end

function getDependentFloatingSpeciesIds(rr::Ptr{Nothing})
  return _rr_string_array(ccall(dlsym(rrlib, :getDependentFloatingSpeciesIds), cdecl,
                                Ptr{RRStringArray}, (Ptr{Nothing},), rr))
end

end # module
"""

msrc = read(mainsrc, String)
if occursin("getIndependentFloatingSpeciesIds", msrc)
    @info "wrappers already present, skipping patch 2"
else
    idx = findlast("end # module", msrc)
    idx === nothing && error("could not find 'end # module' in RoadRunner.jl to patch")
    msrc = msrc[1:first(idx)-1] * wrappers
    write(mainsrc, msrc)
end

# ------------------------- patch 3: duplicate include, and the __precompile__ it forced
#
# rrc_types.jl is included twice: once from rrc_utilities_binding.jl line 1, and again from
# RoadRunner.jl. So every type in it is defined twice, which is method overwriting, which
# makes Julia refuse to precompile the module:
#
#   WARNING: Method definition (::Type{RoadRunner.RRVector})() ... overwritten on the same
#            line (check for duplicate calls to `include`).
#   ERROR: Method overwriting is not permitted during Module precompilation.
#
# That is what __precompile__(false) at the top of the module is working around. Dropping the
# duplicate include fixes the cause, and then precompilation can be turned back on.
#
# This is not just a startup optimisation: PackageCompiler cannot bake a package that refuses
# to precompile, so __precompile__(false) blocks custom sysimages *and* create_app -- i.e. it
# blocks the self-contained deployment path entirely.
msrc = read(mainsrc, String)

before_inc = msrc
msrc = replace(msrc, "include(\"rrc_utilities_binding.jl\")\ninclude(\"antimony_binding.jl\")\ninclude(\"rrc_types.jl\")" =>
                     "include(\"rrc_utilities_binding.jl\")  # this already includes rrc_types.jl\ninclude(\"antimony_binding.jl\")")
msrc = replace(msrc, "include(\"rrc_utilities_binding.jl\")\r\ninclude(\"antimony_binding.jl\")\r\ninclude(\"rrc_types.jl\")" =>
                     "include(\"rrc_utilities_binding.jl\")  # this already includes rrc_types.jl\r\ninclude(\"antimony_binding.jl\")")
msrc == before_inc && @warn "duplicate include of rrc_types.jl not found -- upstream may have fixed it"

before_pc = msrc
msrc = replace(msrc, "__precompile__(false)" =>
                     "# __precompile__(false)  # unnecessary once the duplicate include of rrc_types.jl is gone")
msrc == before_pc && @warn "__precompile__(false) not found -- upstream may have fixed it"

write(mainsrc, msrc)

# ------------------------- patch 4: resolve the native-lib dir at RUNTIME, not build time
#
# Upstream sets rr_api = joinpath(@__DIR__, "roadrunner_c_api.dll") at load and dlopens that.
# @__DIR__ is frozen into a sysimage/app when it is compiled, so the baked absolute path is
# wrong on any relocated or deployed install and __init__ crashes ("could not load library").
# Resolve the directory at runtime from BIFRR_LIBDIR (the host sets it to the real path on this
# machine), falling back to @__DIR__ for plain from-source use. Paths stay absolute so each
# DLL's sibling dependencies (roadrunner.dll, msvcp140.dll, ...) still resolve from its own dir.
msrc = read(mainsrc, String)
before_init = msrc
msrc = replace(msrc, "function __init__()" =>
    "function __init__()\n    libdir = get(ENV, \"BIFRR_LIBDIR\", @__DIR__)")
msrc = replace(msrc, "Libdl.dlopen(rr_api)"          => "Libdl.dlopen(joinpath(libdir, \"roadrunner_c_api.dll\"))")
msrc = replace(msrc, "Libdl.dlopen(antimony_api)"    => "Libdl.dlopen(joinpath(libdir, \"libantimony.dll\"))")
msrc = replace(msrc, "Libdl.dlopen(rr_api_linux)"       => "Libdl.dlopen(joinpath(libdir, \"libroadrunner_c_api.so\"))")
msrc = replace(msrc, "Libdl.dlopen(antimony_api_linux)" => "Libdl.dlopen(joinpath(libdir, \"libantimony.so\"))")
msrc == before_init && @warn "patch 4: __init__ dlopen block not found -- upstream may have changed it"
write(mainsrc, msrc)

# ------------------------------------------------------------------------- build the env
Pkg.activate(HERE)
Pkg.develop(path = VENDOR)
Pkg.add(["BifurcationKit", "Accessors", "JSON3"])
Pkg.instantiate()
Pkg.status()

@info "Verifying the patched stack loads..."
using RoadRunner, BifurcationKit, JSON3
rr = RoadRunner.createRRInstance()
tmp = RoadRunner.loada("J1: S1 -> S2; k1*S1; J2: S2 -> S1; k2*S2; S1=3; S2=1; k1=0.4; k2=0.9;")
RoadRunner.loadSBML(rr, RoadRunner.getCurrentSBML(tmp))
RoadRunner.setComputeAndAssignConservationLaws(rr, true)
println("independent species: ", RoadRunner.getIndependentFloatingSpeciesIds(rr))
println("dependent species:   ", RoadRunner.getDependentFloatingSpeciesIds(rr))
println("SETUP-OK")

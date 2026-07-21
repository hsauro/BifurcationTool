# Builds a custom sysimage (bifsys.dll) so the embedded worker starts fast and the first
# continuation does not pay ~14 s of JIT. The Delphi host loads it via jl_init_with_image_file.
#
#   julia --project=. build_sysimage.jl
#
# Takes several minutes and produces a few hundred MB. Note this only works because the
# vendored RoadRunner has had its __precompile__(false) removed -- PackageCompiler cannot
# bake a package that refuses to precompile. The dlopen calls are in __init__(), which runs
# at load time, so disabling precompilation was never necessary.

using Pkg
Pkg.activate(@__DIR__)

try
    @eval using PackageCompiler
catch
    @info "installing PackageCompiler"
    Pkg.add("PackageCompiler")
    @eval using PackageCompiler
end

const HERE = @__DIR__
const OUT = joinpath(HERE, Sys.iswindows() ? "bifsys.dll" : "bifsys.so")

@info "building sysimage -> $OUT  (several minutes)"
t0 = time()

# PORTABILITY: PackageCompiler defaults to cpu_target = "native", which bakes instructions for the
# CPU that BUILT the image (AVX2/AVX-512 ...). That image dies instantly -- illegal instruction, no
# catchable error, process just vanishes -- when loaded on an older CPU. Since this ships to other
# people's machines, the DEFAULT is the multi-versioned target Julia itself uses for redistributable
# images. Costs a little size and build time; makes the DLL run anywhere x86-64.
#
# Override for a LOCAL, faster image (never redistribute one):
#   $env:BIFSYS_CPU_TARGET = "native"                      # tuned to this machine only
#   $env:BIFSYS_CPU_TARGET = "$(PackageCompiler.default_app_cpu_target());skylake-avx512,clone_all"
#                                                          # portable AND uses AVX-512 where present
const CPU_TARGET = get(ENV, "BIFSYS_CPU_TARGET", PackageCompiler.default_app_cpu_target())
@info "cpu_target = $CPU_TARGET"
if CPU_TARGET != PackageCompiler.default_app_cpu_target()
    @warn "NON-DEFAULT cpu_target -- do NOT ship this image unless it starts with `generic`" CPU_TARGET
end

create_sysimage(
    # BifWorkerCore must be in this list. It holds run_bifurcation and its F/J closures, and
    # only code belonging to a baked *package* can have its specialisations cached -- that is
    # the whole reason the worker logic was moved out of worker.jl.
    ["BifWorkerCore", "RoadRunner", "BifurcationKit", "JSON3", "Accessors"];
    sysimage_path = OUT,
    precompile_execution_file = joinpath(HERE, "precompile_workload.jl"),
    cpu_target = CPU_TARGET,
)

@info "done in $(round((time()-t0)/60, digits=1)) min; size = $(round(filesize(OUT)/1e6, digits=1)) MB"
println("SYSIMAGE-BUILD-OK ", OUT)

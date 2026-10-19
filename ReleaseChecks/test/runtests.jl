# Tests of the checks
# ===================
#
# The unit tests call ReleaseChecks' functions directly.
# The end-to-end tests build git repositories of a toy package, `Toy`, in temporary directories, and run `ReleaseChecks/main.jl` in them, as the workflows do, with a scratch registry, so that the tests need no network.

using Test
using ReleaseChecks

include("helpers.jl")
include("units.jl")
include("gitflow.jl")
include("oneflow.jl")
include("trunk.jl")
include("back_merge.jl")

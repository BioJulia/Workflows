# Tests of the checks
# ===================
#
# The unit tests call ReleaseFlow's functions directly.
# The end-to-end tests build git repositories of a toy package, `Toy`, in temporary directories, and run `julia -m ReleaseFlow` in them, as the workflows do, with a scratch registry, so that the tests need no network.

using Test
using ReleaseFlow

include("helpers.jl")
include("units.jl")
include("gitflow.jl")
include("oneflow.jl")
include("trunk.jl")
include("initial.jl")
include("subdirectory.jl")
include("back_merge.jl")
include("tag.jl")
include("dependents.jl")

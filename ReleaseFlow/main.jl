# Runs one check of ReleaseFlow, as `julia --project=ReleaseFlow ReleaseFlow/main.jl <check>`, from the root of the package's repository.
using ReleaseFlow
exit(ReleaseFlow.main(ARGS))

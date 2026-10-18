# Runs one check of ReleaseFlow, as `julia --project=checks checks/main.jl <check>`, from the root of the package's repository.
using ReleaseFlow
exit(ReleaseFlow.main(ARGS))

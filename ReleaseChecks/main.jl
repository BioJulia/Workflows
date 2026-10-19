# Runs one check of ReleaseChecks, as `julia --project=ReleaseChecks ReleaseChecks/main.jl <check>`, from the root of the package's repository.
using ReleaseChecks
exit(ReleaseChecks.main(ARGS))

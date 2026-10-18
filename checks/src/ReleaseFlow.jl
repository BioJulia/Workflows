"""
    ReleaseFlow

Checks of the pull requests of a Julia package, under one of three branching models.

- gitflow: a main branch of releases and a develop branch of unreleased work.
  Into the main branch come only release and hotfix branches; a hotfix carries no unreleased commit of develop, as it branches from the main branch, and a release carries develop's unreleased commits, as it branches from develop.
  Into develop come any other branches, each with a new changelog entry.
- oneflow: one main branch, from which release and hotfix branches are released, registered at their last commit, and merged back.
  A hotfix branches from the last release's tag, and a release carries the main branch's work since then; any other branch adds a changelog entry.
- trunk: one main branch, on which a release is a commit that changes the version; any other pull request adds a changelog entry.

A release takes the next version, a changelog section that describes it, and, if it breaks the last release, a breaking version and a `### Breaking` subsection.
A change is breaking if the last release's public API is no longer provided, if its tests fail, or if a compat bound no longer admits every version that it did.
The last release is the main branch's version, at the commit that the registry records for it, cross-checked with its tag `vX.Y.Z`; gitflow compares with the main branch itself, which holds only releases.
Git doesn't record which branch a branch was made from, only its commits, so the rules about origins look at the commits.

Each check is a method of `check(::C, ::Settings{M})`; the rules that differ between models dispatch on the model `M`, those that differ between kinds of branch on the kind `K` of a `Branch{K}`, and those that differ by where the last release was found on the source `S` of a `LastRelease{S}`.

Run from the root of the package's repository with `julia --project=<Workflows>/checks <Workflows>/checks/main.jl source|version|changelog|breaking|entry|is-release`, or call [`main`](@ref).
Inputs are environment variables, so that branch names never reach a shell, and an empty one counts as missing:
- `RELEASEFLOW_MODEL`, `gitflow`, `oneflow` or `trunk`, `gitflow` unless given;
- `RELEASEFLOW_MAIN_BRANCH` and `RELEASEFLOW_DEVELOP_BRANCH`, `main` and `develop` unless given;
- `RELEASEFLOW_HEAD_REF`, the source branch, such as `release/v0.2.0`;
- `RELEASEFLOW_HEAD_SHA`, the pull request's head commit, `HEAD` unless given; in GitHub Actions, `HEAD` is the merge commit, which already contains the base;
- `RELEASEFLOW_BASE_BRANCH`, the name of the branch that the pull request merges into, for `source`;
- `RELEASEFLOW_BASE_REF`, what the pull request merges into, `origin/<RELEASEFLOW_MAIN_BRANCH>` unless given;
- `RELEASEFLOW_DEVELOP_REF`, `origin/<RELEASEFLOW_DEVELOP_BRANCH>` unless given;
- `RELEASEFLOW_SKIP_CHANGELOG`, `true` where the pull request has the label `RELEASEFLOW_SKIP_LABEL`, `skip changelog` unless given, for `entry`;
- `RELEASEFLOW_CHECK_LINKS`, whether the changelog's comparison links are checked, `true` unless given;
- `RELEASEFLOW_REGISTRY`, the name of an installed registry, or the path of a registry's directory, `General` unless given.
The base's files are read with `git show`, and a base without them, as before the first release, has no version and no changelog.
"""
module ReleaseFlow

using Pkg
using TOML
using UUIDs

include("models.jl")
include("settings.jl")
include("reporting.jl")
include("git.jl")
include("package.jl")
include("branches.jl")
include("registry.jl")
include("releases.jl")
include("changelog.jl")
include("checks/checks.jl")
include("checks/source.jl")
include("checks/version.jl")
include("checks/changelog.jl")
include("checks/entry.jl")
include("checks/is_release.jl")
include("checks/breaking.jl")

const USAGE = "usage: RELEASEFLOW_MODEL=$(join(sort(collect(keys(MODELS))), '|')) julia --project=checks checks/main.jl $(join(sort(collect(keys(CHECKS))), '|'))"

"""
    main(arguments; environment = ENV, root = pwd()) -> Int

Run the check named by the one argument in `arguments` on the repository at `root`, with the inputs in `environment`, and return the exit code: `0` where it passes, `1` where it fails, and `2` for a wrong argument or model.
"""
function main(arguments = ARGS; environment = ENV, root = pwd())
    if length(arguments) != 1 || !haskey(CHECKS, arguments[1]) || !haskey(MODELS, input(environment, "RELEASEFLOW_MODEL", "gitflow"))
        println(stderr, USAGE)
        return 2
    end
    settings = Settings(environment; root)
    check(CHECKS[arguments[1]], settings)
    return isempty(settings.errors) ? 0 : 1
end

end # module ReleaseFlow

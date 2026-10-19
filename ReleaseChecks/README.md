# ReleaseChecks

Checks that a pull request of a Julia package follows the repository's branching model, gitflow, OneFlow or trunk, and that a release takes the right version, describes itself in the changelog, and marks its breaking changes.

The [reusable workflows of BioJulia/Workflows](https://github.com/BioJulia/Workflows) run these checks on any Julia package's pull requests; this package is how they do it, and how a maintainer runs the same checks before opening one.
The workflows' README describes the models, what each check does, and how to set up a repository.

## Running a check

Install ReleaseChecks in a shared environment of its own, so that it doesn't enter a package's project:

```bash
julia --project=@ReleaseChecks -e 'using Pkg; Pkg.add("ReleaseChecks")'
```

Then run a check, which is the package's entry point, from the root of a package's repository:

```bash
MODEL=gitflow BASE_BRANCH=master HEAD_REF=release/v0.2.0 julia --project=@ReleaseChecks -m ReleaseChecks source
```

From a clone of BioJulia/Workflows, `--project=path/to/Workflows/ReleaseChecks` runs the clone's copy instead.
`julia -m` needs Julia 1.12 or later.

The checks are `source`, `version`, `changelog`, `breaking`, `entry` and `release`; the exit code is `0` where the check passes, `1` where it fails, with the failures as GitHub Actions annotations, and `2` for a wrong check or model.

## Inputs

The inputs are environment variables, so that branch names never reach a shell, and an empty one counts as missing.

| Variable | Default | Meaning |
|:--|:--|:--|
| `MODEL` | `gitflow` | `gitflow`, `oneflow` or `trunk`. |
| `MAIN_BRANCH` | `master` | The branch of releases. |
| `DEVELOP_BRANCH` | `develop` | The branch of unreleased work, for gitflow. |
| `HEAD_REF` | | The branch that the pull request comes from. |
| `HEAD_SHA` | `HEAD` | The pull request's head commit; in GitHub Actions, `HEAD` is the merge commit. |
| `BASE_BRANCH` | | The branch that the pull request merges into, for `source`. |
| `BASE_REF` | `origin/<MAIN_BRANCH>` | What the pull request merges into, as git names it. |
| `DEVELOP_REF` | `origin/<DEVELOP_BRANCH>` | Develop, as git names it. |
| `SKIP_CHANGELOG` | `false` | Whether the pull request has the label that exempts it from the changelog entry. |
| `SKIP_LABEL` | `skip changelog` | That label, for messages. |
| `CHECK_LINKS` | `true` | Whether to check the changelog's comparison links. |
| `PROJECT` | the root | The package's directory, relative to the repository's root, for a package in a subdirectory, such as `lib/Toy`; its `Project.toml` and `CHANGELOG.md` are read there, and its releases are its directory's trees. |
| `REGISTRY` | `General` | The name of an installed registry, or the path of a registry's directory, whose records give the commits of releases. |

## The code

The package has a file per concern: the model, settings, branch, last release and changelog types in `src/`, one file per check in `src/checks/`, and the listing of a package's public API, which the breaking check runs in the package's own project, in `src/surface.jl`.
Each check is a method of `check(::C, ::Settings{M})`, and the rules that differ dispatch on the model `M`, the kind `K` of a `Branch{K}`, or the source `S` of a `LastRelease{S}`.

The tests call the package directly, and build git repositories of a toy package and a scratch registry for the end-to-end checks, so they need no network:

```bash
julia --project=test -e 'using Pkg; Pkg.instantiate()'
```

```bash
julia --project=test test/runtests.jl
```

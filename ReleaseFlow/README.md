# ReleaseFlow

Checks that a pull request of a Julia package follows the repository's branching model, gitflow, OneFlow or trunk, and that a release takes the right version, describes itself in the changelog, and marks its breaking changes.

The [reusable workflows of BioJulia/Workflows](https://github.com/BioJulia/Workflows) run these checks on any Julia package's pull requests; this package is how they do it, and how a maintainer runs the same checks before opening one.
The workflows' README describes the models, what each check does, and how to set up a repository.

## Running a check

From the root of a package's repository, with a clone of BioJulia/Workflows:

```bash
RELEASEFLOW_MODEL=gitflow RELEASEFLOW_BASE_BRANCH=master RELEASEFLOW_HEAD_REF=release/v0.2.0 julia --project=path/to/Workflows/ReleaseFlow path/to/Workflows/ReleaseFlow/main.jl source
```

The checks are `source`, `version`, `changelog`, `breaking`, `entry` and `is-release`; the exit code is `0` where the check passes, `1` where it fails, with the failures as GitHub Actions annotations, and `2` for a wrong check or model.

## Inputs

The inputs are environment variables, so that branch names never reach a shell, and an empty one counts as missing.

| Variable | Default | Meaning |
|:--|:--|:--|
| `RELEASEFLOW_MODEL` | `gitflow` | `gitflow`, `oneflow` or `trunk`. |
| `RELEASEFLOW_MAIN_BRANCH` | `main` | The branch of releases. |
| `RELEASEFLOW_DEVELOP_BRANCH` | `develop` | The branch of unreleased work, for gitflow. |
| `RELEASEFLOW_HEAD_REF` | | The branch that the pull request comes from. |
| `RELEASEFLOW_HEAD_SHA` | `HEAD` | The pull request's head commit; in GitHub Actions, `HEAD` is the merge commit. |
| `RELEASEFLOW_BASE_BRANCH` | | The branch that the pull request merges into, for `source`. |
| `RELEASEFLOW_BASE_REF` | `origin/<RELEASEFLOW_MAIN_BRANCH>` | What the pull request merges into, as git names it. |
| `RELEASEFLOW_DEVELOP_REF` | `origin/<RELEASEFLOW_DEVELOP_BRANCH>` | Develop, as git names it. |
| `RELEASEFLOW_SKIP_CHANGELOG` | `false` | Whether the pull request has the label that exempts it from the changelog entry. |
| `RELEASEFLOW_SKIP_LABEL` | `skip changelog` | That label, for messages. |
| `RELEASEFLOW_CHECK_LINKS` | `true` | Whether to check the changelog's comparison links. |
| `RELEASEFLOW_REGISTRY` | `General` | The name of an installed registry, or the path of a registry's directory, whose records give the commits of releases. |

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

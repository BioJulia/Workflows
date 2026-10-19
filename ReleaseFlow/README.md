# ReleaseFlow

Checks that a pull request of a Julia package follows the repository's branching model, gitflow, OneFlow or trunk, and that a release takes the right version, describes itself in the changelog, and marks its breaking changes.

The [reusable workflows of BioJulia/Workflows](https://github.com/BioJulia/Workflows) run these checks on any Julia package's pull requests; this package is how they do it, and how a maintainer runs the same checks before opening one.
The workflows' README describes the models, what each check does, and how to set up a repository.

## Running a check

Install ReleaseFlow in a shared environment of its own, so that it doesn't enter a package's project:

```bash
julia --project=@ReleaseFlow -e 'using Pkg; Pkg.add("ReleaseFlow")'
```

Then run a check, which is the package's entry point, from the root of a package's repository:

```bash
RELEASEFLOW_MODEL=gitflow RELEASEFLOW_BASE_BRANCH=master RELEASEFLOW_HEAD_REF=release/v0.2.0 julia --project=@ReleaseFlow -m ReleaseFlow source
```

From a clone of BioJulia/Workflows, `--project=path/to/Workflows/ReleaseFlow` runs the clone's copy instead.
`julia -m` needs Julia 1.12 or later.

The checks are `source`, `version`, `changelog`, `breaking`, `entry` and `is-release`; the exit code is `0` where the check passes, `1` where it fails, with the failures as GitHub Actions annotations, and `2` for a wrong check or model.

## The initial release

Where the main branch has no version, the pull request is the package's initial release, which follows its own rules:
- a standard first version, 0.0.1, 0.1.0 or X.0.0, as General accepts for a new package;
- nothing released before: the registry records no version of the package, and the repository has no tag `vX.Y.Z` but the release's own, at its commit;
- a changelog of one release: its own section, linked to its own tag, with nothing left unreleased;
- under gitflow and OneFlow, a release branch, since a hotfix has nothing to fix.

There's nothing earlier to break, or for the branch to have come from.

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
| `RELEASEFLOW_PROJECT` | the root | The package's directory, relative to the repository's root, for a package in a subdirectory, such as `lib/Toy`; its `Project.toml` and `CHANGELOG.md` are read there, and its releases are its directory's trees. |
| `RELEASEFLOW_REGISTRY` | `General` | The name of an installed registry, or the path of a registry's directory, whose records give the commits of releases. |

## The code

The package has a file per concern: the model, settings, branch, last release and changelog types in `src/`, one file per check in `src/checks/`, and the listing of a package's public API, which the breaking check runs in the package's own project, in `src/surface.jl`.
Each check is a method of `check(::C, ::Settings{M})`, and the rules that differ dispatch on the model `M`, the kind `K` of a `Branch{K}`, or the `Baseline` of the pull request: a `LastRelease{S}`, from the source `S`, or the `InitialRelease`.

The tests call the package directly, and build git repositories of a toy package and a scratch registry for the end-to-end checks, so they need no network:

```bash
julia --project=test -e 'using Pkg; Pkg.instantiate()'
```

```bash
julia --project=test test/runtests.jl
```

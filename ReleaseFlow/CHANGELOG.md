# Changelog

All notable changes to BioJulia/Workflows are documented in this file: the workflows, the action, and the package ReleaseFlow, which share one version, in `ReleaseFlow/Project.toml`.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a breaking change to a workflow's inputs, jobs or check names, or to ReleaseFlow's public API, takes a new major version.

## [Unreleased]

- The breaking check counts a name that still resolves as provided, such as an old name kept with `Base.@deprecate_binding`, which Julia's `names` leaves out; a rename through a deprecated binding is no longer reported as a removal.
- The breaking check runs the last release's tests without its own inputs, the `RELEASEFLOW_*` variables, and without `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY` and `JULIA_LOAD_PATH`, which tests that run ReleaseFlow, as its own do, would otherwise inherit, such as the load path of a `Pkg.test` that lacks the standard library.
- The breaking check runs the last release's tests in a checkout of the head's commit, rather than a copy of the package's directory, so that the tests of a package in a subdirectory find the files around it.
- This repository checks its own pull requests with its gitflow workflow at the major tag, `v1`, rather than the pull request's own, whose calls of the action a release sets to a tag that doesn't exist until the release merges.

## [1.0.0] - 2026-10-19

- ReleaseFlow, the checks of the pull requests of a Julia package under gitflow, OneFlow and trunk: source branches and where they came from, versions, changelogs with comparison links, breaking changes to the public API, tests and compat bounds, and changelog entries.
- The last release, for OneFlow and trunk, is the commit whose tree the registry records for the main branch's version, cross-checked with its tag.
- Each check is a method of `check(::C, ::Settings{M})`, dispatching on the model, the kind of branch, and the baseline: the last release, by its source, or the initial release.
- The initial release takes its own rules: a standard first version, 0.0.1, 0.1.0 or X.0.0; no version that the registry records or that a tag names; a changelog of its own section, linked to its tag; and a release branch, not a hotfix.
- `RELEASEFLOW_PROJECT`, for a package in a subdirectory: its `Project.toml` and `CHANGELOG.md` are read there, and its releases are the trees of its directory, as a registry records them.
- `ReleaseFlow.main`, the package's entry point, which runs a check and returns its exit code: `julia -m ReleaseFlow source`.
- A composite action, `action.yml`, that runs ReleaseFlow at its own version.
- The reusable workflows `gitflow.yml`, `back-merge.yml`, `oneflow.yml` and `trunk.yml`, with the input `project` for a package in a subdirectory, which the back-merge reads its version from.
- CI: the tests, Runic, actionlint, and the pins of the workflows' calls of the action.
- TagBot, which tags the releases of ReleaseFlow, registered from `ReleaseFlow/`, as `ReleaseFlow-vX.Y.Z`.
- This repository follows gitflow, with `master` and `develop`, and checks its own pull requests with its reusable gitflow and back-merge workflows.
- The back-merge job runs in the deployment environment `releaseflow`, whose secrets reach only the main branch, and takes the app's client ID, `RELEASEFLOW_APP_CLIENT_ID`, as `actions/create-github-app-token` v3 does.
- The workflows and the action pin the actions of other owners to commits, which Dependabot updates, and `.github/CODEOWNERS` requires a maintainer's review of the workflows and the action.
- The README explains how to create the ReleaseFlow token, `RELEASEFLOW_TOKEN`, and store it as a secret of the `releaseflow` environment.
- The back-merge workflow opens its pull request with a GitHub App's token, from the secrets `RELEASEFLOW_APP_CLIENT_ID` and `RELEASEFLOW_APP_PRIVATE_KEY`, in preference to `RELEASEFLOW_TOKEN`; the README explains how to create the app.
- The back-merge workflow creates its branch with the job's own token, so the app or personal token needs only read and write access to pull requests; where GitHub refuses the job's token the branch, the other token creates it, with access to contents and workflows.

[Unreleased]: https://github.com/BioJulia/Workflows/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/BioJulia/Workflows/releases/tag/v1.0.0

# Changelog

All notable changes to BioJulia/Workflows are documented in this file: the workflows, the action, and the package ReleaseFlow, which share one version, in `ReleaseFlow/Project.toml`.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a breaking change to a workflow's inputs, jobs or check names, or to ReleaseFlow's public API, takes a new major version.

## [Unreleased]

- ReleaseFlow, the checks of the pull requests of a Julia package under gitflow, OneFlow and trunk: source branches and where they came from, versions, changelogs with comparison links, breaking changes to the public API, tests and compat bounds, and changelog entries.
- The last release, for OneFlow and trunk, is the commit whose tree the registry records for the main branch's version, cross-checked with its tag.
- Each check is a method of `check(::C, ::Settings{M})`, dispatching on the model, the kind of branch, and the source of the last release.
- `RELEASEFLOW_PROJECT`, for a package in a subdirectory: its `Project.toml` and `CHANGELOG.md` are read there, and its releases are the trees of its directory, as a registry records them.
- `ReleaseFlow.main`, the package's entry point, which runs a check and returns its exit code: `julia -m ReleaseFlow source`.
- A composite action, `action.yml`, that runs ReleaseFlow at its own version.
- The reusable workflows `gitflow.yml`, `back-merge.yml`, `oneflow.yml` and `trunk.yml`, with the input `project` for a package in a subdirectory, which the back-merge reads its version from.
- CI: the tests, Runic, actionlint, and the pins of the workflows' calls of the action.
- TagBot, which tags the releases of ReleaseFlow, registered from `ReleaseFlow/`, as `ReleaseFlow-vX.Y.Z`.
- This repository follows gitflow, with `master` and `develop`, and checks its own pull requests with its reusable gitflow and back-merge workflows.
- The README explains how to create the ReleaseFlow token, `RELEASEFLOW_TOKEN`, and store it as a repository or organization secret.
- The back-merge workflow opens its pull request with a GitHub App's token, from the secrets `RELEASEFLOW_APP_ID` and `RELEASEFLOW_APP_PRIVATE_KEY`, in preference to `RELEASEFLOW_TOKEN`; the README explains how to create the app.
- The back-merge workflow creates its branch with the job's own token, so the app or personal token needs only read and write access to pull requests; where GitHub refuses the job's token the branch, the other token creates it, with access to contents and workflows.

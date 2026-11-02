# Changelog

All notable changes to BioJulia/Workflows are documented in this file: the workflows, the action, and the package ReleaseFlow, which share one version, in `ReleaseFlow/Project.toml`.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a breaking change to a workflow's inputs, jobs or check names, or to ReleaseFlow's public API, takes a new major version.

## [Unreleased]

### Added

- The changelog entry check compares the public API of a pull request that changes the package's `src/` or `Project.toml` with its base's, and needs a new entry under `### Breaking` where it removes or changes any, and under `### Added` where it adds any, so that the release takes the right version from its pull requests' entries, rather than the breaking check finding a breaking change only at the release.

### Changed

- This repository's `CI.yml` runs on pushes to `master` and `develop` only, not to `release/*` and `hotfix/*` branches, which their pull requests test, nor to tags, which name commits already tested; so a release's commit is tested once, not once for its push and again for its pull request.

### Fixed

- The workflows' Julia caches no longer try to delete their older caches, which needs the permission `actions: write`, which the jobs lack, so the cleanup at each job's end no longer logs GitHub's refusal; GitHub evicts the older caches once the repository's caches reach its limit.
- The breaking check, and the changelog entry check's comparison of the public API, count a name that's still defined but no longer exported or declared `public` as removed, since `using` no longer gives it, rather than as still provided; and so one that becomes public as added.

## [1.2.0] - 2026-11-01

### Added

- The version check fails a release whose section has `### Added` entries with the next patch, from 1.0, where new features take the next minor or major version, and a hotfix whose section has any, since a hotfix adds no features; before, only `prepare`'s step `auto` read them.

### Changed

- `register.yml` comments for Registrator with the workflow's `GITHUB_TOKEN`, as `github-actions[bot]`, whose comments Registrator acts on, so it needs no machine user: its caller grants `contents: write`, and `REGISTRATOR_TOKEN`, now optional, comments instead where it's given.
  Where GitHub refuses the comment, the error gives GitHub's message and what the token needs, and the job summary gives the comment to make by hand meanwhile.
- The README's callers of `gitflow.yml`, `oneflow.yml` and `trunk.yml` take a concurrency group, so that a pull request's new push cancels the run of its outdated commit, as this repository's `CI.yml` and `Self-Gitflow.yml` now do; `CI.yml`'s runs on pushes to a branch or a tag still run to the end.

## [1.1.1] - 2026-10-31

### Changed

- The breaking check's summary shows each failing test of the last release with its expression, and what it evaluated to or the exception it threw, at its path in the repository, rather than only the line naming its file.

### Fixed

- The checks' messages name the changelog by its path in the repository, such as `ReleaseFlow/CHANGELOG.md` for a package in a subdirectory, rather than `CHANGELOG.md`.
- `release.yml` and `register.yml` run the action at its release, and with `local-action` at the checkout, in jobs of their own, since GitHub resolves every action of a job before it runs, even one whose step is skipped; so `Self-Register.yml` no longer fails where a release merges, whose own tag doesn't exist until it's registered.
  The jobs that run the action no longer have the tokens: `release.yml`'s `Push` job applies the changes that its `Prepare` job passes on, and pushes them, and `register.yml`'s `Register` job, after its `Registration` job, comments, and only runs where there's a version to register.

## [1.1.0] - 2026-10-29

### Added

- The reusable workflow `tag.yml`, which moves each major tag, such as `v1`, to the newest release of its major version, `vX.Y.Z`, whichever made the tag, TagBot or a maintainer, and whenever, for a repository that callers follow by its major tag; it only moves a major tag forwards, to a release that descends from where it is, leaves pre-releases out, and reports what it did for each major tag as a notice on the run and a line of the job's summary, or, where GitHub refuses a move, an error with GitHub's message.
- This repository moves `v1` with it, through `Self-Tag.yml`, once TagBot tags a release `vX.Y.Z`, with `tag_prefix: NO_PREFIX`, in place of `ReleaseFlow-vX.Y.Z`, and with the ReleaseFlow app's token, which the ruleset on `v*` tags lets through; so the workflows' callers get a release once ReleaseFlow's is registered.
- This repository's TagBot names `master` as its release branch, so that its tags land on `master`'s merge commits rather than on the back-merges into `develop`, which share their trees, once TagBot searches that branch first.
- The reusable workflow `dependents.yml`, which runs the tests of the packages that depend on this one, each checked out at its default branch, with the pull request's branch in its place, as the checks `dependents / <repository>`.
- The back-merge's inputs `from` and `into`, which bring any branch into any other, such as a maintenance branch into the main branch, from a branch `back-merge/<from>-<commit>`; by default, the main branch into develop, as before.
- `registration`, which reports, as the action's outputs `version`, `register` and `notes`, the version at the head, whether the registry still lacks it, and its section of the changelog, as the release notes; where the registry doesn't know the package, its first release is registered by hand, and the check warns with the comment to make and the commit to make it on.
- The reusable workflow `register.yml`, which comments `@JuliaRegistrator register`, with the release notes, on a release's commit once it merges, with a machine user's token, `REGISTRATOR_TOKEN`; TagBot then tags the release; and `Self-Register.yml`, which registers this repository's releases.
- `prepare`, which prepares a release in a checkout of the branch it starts from: the next version after the last release, by `RELEASEFLOW_STEP`, where `auto` reads the unreleased section's `### Breaking` and `### Added`, set in `Project.toml`; the unreleased entries moved into its dated section, with the changelog's links; and the pins of `RELEASEFLOW_PIN_ACTION` set to it.
- The reusable workflow `release.yml`, started from the Actions tab, which prepares a release or hotfix with `prepare`, pushes its branch, and opens its pull request, a draft for a hotfix, with the ReleaseFlow app's token; and `Self-Release.yml`, which prepares this repository's releases.
- The input `local-action` of `release.yml` and `register.yml`, which runs the action from the checked-out commit instead of its release; `Self-Release.yml` and `Self-Register.yml` set it, since a release of this repository may be the first with a check that they call, and its own tag only exists once it's registered.

## [1.0.1] - 2026-10-20

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

[Unreleased]: https://github.com/BioJulia/Workflows/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/BioJulia/Workflows/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/BioJulia/Workflows/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/BioJulia/Workflows/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/BioJulia/Workflows/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/BioJulia/Workflows/releases/tag/v1.0.0

# Changelog

All notable changes to ReleaseChecks are documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Checks of the pull requests of a Julia package under gitflow, OneFlow and trunk: source branches and where they came from, versions, changelogs with comparison links, breaking changes to the public API, tests and compat bounds, and changelog entries.
- The last release, for OneFlow and trunk, is the commit whose tree the registry records for the main branch's version, cross-checked with its tag.
- Each check is a method of `check(::C, ::Settings{M})`, dispatching on the model, the kind of branch, and the source of the last release.
- `PROJECT`, for a package in a subdirectory: its `Project.toml` and `CHANGELOG.md` are read there, and its releases are the trees of its directory, as a registry records them.
- `ReleaseChecks.main`, the package's entry point, which runs a check and returns its exit code: `julia -m ReleaseChecks source`.

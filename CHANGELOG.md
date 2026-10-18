# Changelog

All notable changes to this project are documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a breaking change to a workflow's inputs, jobs or check names takes a new major version.

## [Unreleased]

- The release checks, the package `ReleaseFlow` in `checks/`, for gitflow, OneFlow and trunk repositories: source branches, versions, changelogs with comparison links, breaking changes and changelog entries, with the last release found in the registry and cross-checked with its tag.
- A composite action, `action.yml`, that runs the checks at its own version.
- The reusable workflows `gitflow.yml`, `back-merge.yml`, `oneflow.yml` and `trunk.yml`.
- CI: the tests, Runic, actionlint, and the pins of the workflows' calls of the action.

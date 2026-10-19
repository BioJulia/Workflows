# Changelog

All notable changes to the workflows and the action are documented in this file; those to the package ReleaseFlow are in [its own changelog](ReleaseFlow/CHANGELOG.md).

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a breaking change to a workflow's inputs, jobs or check names takes a new major version.

## [Unreleased]

- The package `ReleaseFlow`, in `ReleaseFlow/`, which holds the checks; its own changelog describes them.
- A composite action, `action.yml`, that runs the checks at its own version.
- The reusable workflows `gitflow.yml`, `back-merge.yml`, `oneflow.yml` and `trunk.yml`.
- The input `project`, for a package in a subdirectory.
- CI: the tests, Runic, actionlint, and the pins of the workflows' calls of the action.
- TagBot, which tags the releases of ReleaseFlow, registered from `ReleaseFlow/`, as `ReleaseFlow-vX.Y.Z`.

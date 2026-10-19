# Workflows

Reusable GitHub Actions workflows for Julia packages: checks that a pull request follows the repository's branching model, and that a release takes the right version, describes itself in the changelog, and marks its breaking changes.

The repository holds two things:
- **the workflows**, in [`.github/workflows/`](.github/workflows), with the composite action, [`action.yml`](action.yml), that they call, tagged `vX.Y.Z`;
- **the checks**, a Julia package, [ReleaseChecks](ReleaseChecks), registered in General from this repository's `ReleaseChecks/` directory, and tagged `ReleaseChecks-vX.Y.Z`.

Both share one version, in `ReleaseChecks/Project.toml`, and one changelog, [`ReleaseChecks/CHANGELOG.md`](ReleaseChecks/CHANGELOG.md).

The action runs the copy of ReleaseChecks at its own tag, so a workflow and its checks always come from one release; a package calls a workflow by its tag, and updates the checks by moving to a newer tag.

## Models

| Model | Branches | A release | Workflow |
|:--|:--|:--|:--|
| [Gitflow](https://nvie.com/posts/a-successful-git-branching-model/) | a main branch of releases, and `develop` | a `release/vX.Y.Z` branch from `develop`, or a `hotfix/vX.Y.Z` branch from the main branch, merges into the main branch, which is registered; the main branch then merges back into `develop` | [`gitflow.yml`](.github/workflows/gitflow.yml), [`back-merge.yml`](.github/workflows/back-merge.yml) |
| [OneFlow](https://www.endoflineblog.com/oneflow-a-git-branching-model-and-workflow) | one main branch | a `release/vX.Y.Z` branch from the main branch, or a `hotfix/vX.Y.Z` branch from the last release's tag, is registered at its last commit, and then merges back into the main branch | [`oneflow.yml`](.github/workflows/oneflow.yml) |
| Trunk | one main branch | a commit on the main branch that changes the version is registered | [`trunk.yml`](.github/workflows/trunk.yml) |

## Using the workflows

A package calls a workflow from its own workflow file, which says when it runs.

Gitflow, in `.github/workflows/Gitflow.yml`:

```yaml
name: Gitflow
on:
  pull_request:
    branches: [master, develop]
    # Adding or removing the `skip changelog` label runs the checks again.
    types: [opened, synchronize, reopened, labeled, unlabeled]
permissions: {}
jobs:
  gitflow:
    uses: BioJulia/Workflows/.github/workflows/gitflow.yml@v1
    permissions:
      contents: read
```

And the back-merge, in `.github/workflows/BackMerge.yml`, which opens the pull request that brings a release or hotfix back into `develop`:

```yaml
name: Back-merge
on:
  push:
    branches: [master]
  workflow_dispatch:
permissions: {}
jobs:
  back-merge:
    uses: BioJulia/Workflows/.github/workflows/back-merge.yml@v1
    permissions:
      contents: write
      pull-requests: write
    secrets:
      BACK_MERGE_TOKEN: ${{ secrets.BACK_MERGE_TOKEN }}
```

OneFlow and trunk, in `.github/workflows/OneFlow.yml` or `.github/workflows/Trunk.yml`:

```yaml
name: OneFlow
on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened, labeled, unlabeled]
permissions: {}
jobs:
  oneflow:
    uses: BioJulia/Workflows/.github/workflows/oneflow.yml@v1   # or trunk.yml
    permissions:
      contents: read
```

A package can follow the major tag, `v1`, or pin a release, such as `v1.0.0`; Dependabot's `github-actions` updates keep a pinned release current.

### Inputs

| Input | Default | Workflows | Meaning |
|:--|:--|:--|:--|
| `main-branch` | `master` for gitflow, `main` otherwise | all | The branch of releases. |
| `develop-branch` | `develop` | gitflow, back-merge | The branch of unreleased work. |
| `skip-label` | `skip changelog` | gitflow, oneflow, trunk | The label that exempts a pull request from the changelog entry. |
| `check-links` | `true` | gitflow, oneflow, trunk | Whether to check the changelog's comparison links. |
| `require-entry` | `true` | trunk | Whether a pull request that isn't a release must add a changelog entry, for a changelog without an unreleased section. |
| `project` | the root | gitflow, oneflow, trunk | The package's directory, for a package in a subdirectory, such as `lib/Toy`. |
| `registry` | `General` | gitflow, oneflow, trunk | The registry of the package's releases. |

For example, `with: { main-branch: main }` for a gitflow repository whose main branch is `main`.

### Setting up the repository

- **Rulesets.** The checks enforce the model once rulesets require pull requests and require the checks, by their names with the calling job's prefix, such as `gitflow / Source branch`:
  - gitflow, on both the main branch and `develop`: `Source branch`, `Version`, `Changelog`, `Breaking changes` and `Changelog entry`;
  - OneFlow, on the main branch: the same five;
  - trunk, on the main branch: `Release`, `Version`, `Changelog`, `Breaking changes` and `Changelog entry`.

  The checks that don't apply to a pull request are skipped, and GitHub counts a skipped check as passed, so a ruleset can require all of them.
  GitHub only offers a check's name once it has run, and only enforces rulesets on a private repository with a paid plan.
- **The label.** Create the `skip changelog` label, for changes that users won't notice.
- **The back-merge token.** Pull requests opened with the default `GITHUB_TOKEN` don't start workflows, so their checks would never report; the secret `BACK_MERGE_TOKEN` opens them instead, as described in [Creating the back-merge token](#creating-the-back-merge-token).
  Without it, the back-merge pull request says to close and reopen it, which starts the checks.
  Either way, allow GitHub Actions to create pull requests, in the repository's Settings → Actions → General → Workflow permissions → "Allow GitHub Actions to create and approve pull requests".
- **Code owners.** A pull request runs its own copy of its workflow files, so a `CODEOWNERS` entry for `/.github/workflows/`, with the ruleset requiring a code owner's review, keeps a pull request from changing which checks it runs.
- **Forks.** The checks look at the pull request's head commit and this repository's branches, so they work the same for pull requests from forks; GitHub asks a maintainer to approve the workflows of a first-time contributor.

### Creating the back-merge token

The token is a fine-grained personal access token, which the back-merge workflow uses to create the `back-merge/vX.Y.Z` branch and open its pull request.
GitHub shows the token's owner as the pull request's author, so prefer a maintainers' machine account, such as a bot account of the organization, to a person's: an author can't approve their own pull request, and the token outlives a maintainer's involvement.

1. Signed in as the token's owner, open Settings → Developer settings → Personal access tokens → Fine-grained tokens, and choose "Generate new token".
2. Name it, such as `BACK_MERGE_TOKEN for <organization>`, and set an expiration; the organization may cap it, and the token must be regenerated and the secret updated before it expires.
3. Set the resource owner to the organization that owns the repositories, rather than the account; an organization that reviews fine-grained tokens holds it as pending until an owner approves it, in the organization's Settings → Personal access tokens → Pending requests.
4. Under repository access, choose "Only select repositories", and select the repositories that use the back-merge workflow.
5. Under repository permissions, set:
   - Contents: Read and write, to create the branch;
   - Pull requests: Read and write, to open the pull request;
   - Workflows: Read and write, since the branch carries the main branch's workflow files, which may differ from `develop`'s.

   Metadata: Read-only is added by itself; leave every other permission at no access.
6. Choose "Generate token", and copy it; GitHub shows it only once.
7. Store it as a secret named `BACK_MERGE_TOKEN`, in either:
   - the repository's Settings → Secrets and variables → Actions → New repository secret, for one repository;
   - the organization's Settings → Secrets and variables → Actions → New organization secret, with access for the selected repositories, so that one token serves every repository that uses the workflow.

The caller passes the secret to the reusable workflow, as `secrets: BACK_MERGE_TOKEN: ${{ secrets.BACK_MERGE_TOKEN }}`; the token never needs to appear anywhere else.
To check it, run the caller's Back-merge workflow from the Actions tab, with "Run workflow": it opens the pull request if `develop` lacks the main branch's commit, and its checks start.

## The checks

- **Source branch.**
  - Gitflow: the main branch takes only `release/*` and `hotfix/*` branches, and `develop` takes any other branch.
  - Gitflow and OneFlow: a hotfix carries no unreleased work, as it branches from what's released, and a release carries the unreleased work, as it branches from where that is.
    Git doesn't record which branch a branch was made from, so these rules look at the commits: where the head last met the branch of unreleased work, `develop` or the main branch, must be released for a hotfix, and not yet released for a release.
- **Version.** `Project.toml`'s version is a single step up from the last release's, without a prerelease or build suffix, and the next patch for a hotfix.
  For gitflow and OneFlow, the branch's name gives the same version.
  The version isn't yet registered or tagged, except at the head commit, as OneFlow registers a release before it merges back.
- **Changelog.** `CHANGELOG.md` has a section for the version, `## [X.Y.Z]`, with entries, before every earlier version's, with nothing left under `## [Unreleased]`.
  Its comparison links compare each version's tag with the one before, and the newest with `HEAD` for the unreleased changes, unless `check-links` is false.
- **Breaking changes.** The last release's public API, its names, methods, keywords and fields, is still provided; its tests still pass against the head; and the compat bounds of Julia and of the dependencies still admit every version that they did.
  A breaking change needs the next major version, or the next minor version below 1.0, and a `### Breaking` subsection in the version's section; a hotfix can't be breaking.
  The job's summary lists what breaks.
- **Changelog entry.** A pull request of unreleased work adds an entry under `## [Unreleased]`, or rewords one, unless it has the `skip changelog` label, or brings the main branch back into `develop`.
- **Release.** For trunk, whether the pull request changes the version, which decides which checks run.

**The last release.** Gitflow compares a release with its main branch, which holds only releases.
OneFlow and trunk compare it with the last release: the main branch's version, at the commit whose tree the registry records for that version, which is what users install.
The tag `vX.Y.Z` is a second datapoint, and must agree with the registry; where the registry doesn't know the version, the tag is the last release, and without a tag, the main branch.

## Running the checks locally

[ReleaseChecks' README](ReleaseChecks/README.md) describes installing the package and running a check from the root of a package's repository, before a pull request.

## Developing

ReleaseChecks' tests, in `ReleaseChecks/test/`, call it directly, and build git repositories of a toy package and a scratch registry for the end-to-end checks, so they need no network:

```bash
julia --project=ReleaseChecks/test -e 'using Pkg; Pkg.instantiate()'
```

```bash
julia --project=ReleaseChecks/test ReleaseChecks/test/runtests.jl
```

## Contributing

This repository follows gitflow, with `master` and `develop`, and checks its own pull requests with its reusable gitflow workflow, through [`GitflowChecks.yml`](.github/workflows/GitflowChecks.yml):
- features and fixes branch from `develop`, add an entry under `## [Unreleased]` in [`ReleaseChecks/CHANGELOG.md`](ReleaseChecks/CHANGELOG.md), and merge back by pull request;
- a release branches from `develop` as `release/vX.Y.Z`, and a hotfix from `master` as `hotfix/vX.Y.Z`; either merges into `master` by pull request, and the Back-merge workflow then opens the pull request that brings `master` back into `develop`.

The workflows and ReleaseChecks share one version, in `ReleaseChecks/Project.toml`, and one changelog.
The reusable workflows call the action at the release that they belong to, such as `BioJulia/Workflows@v1.0.0`, so that a workflow and its checks come from one release; the CI's Pins check holds them to it.

A release or hotfix branch:
1. sets its version in `ReleaseChecks/Project.toml`;
2. sets every `uses: BioJulia/Workflows@…` in `.github/workflows/` to that version, `vX.Y.Z`;
3. moves the changelog's unreleased entries into a `## [X.Y.Z]` section, with its comparison link.

Once it merges into `master`:
1. tag the merge commit `vX.Y.Z`, and move the major tag to it, with `git tag -f v1 vX.Y.Z` and `git push -f origin v1`;
2. comment `@JuliaRegistrator register subdir=ReleaseChecks` on the commit, which registers ReleaseChecks in General from its subdirectory;
3. once General merges the registration, TagBot tags the commit `ReleaseChecks-vX.Y.Z`.

A breaking change to a workflow's inputs, jobs or check names, or to ReleaseChecks' public API, takes a new major version, and a new major tag, such as `v2`.

The repository's own pull requests are checked by the released checks, at the action's pins, while CI tests the pull request's own.
So the first release, `v1.0.0`, can't be checked before it's tagged: require the Gitflow checks in the rulesets of `master` and `develop` once it is.

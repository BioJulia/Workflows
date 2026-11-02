# Workflows

Reusable GitHub Actions workflows for Julia packages: checks that a pull request follows the repository's branching model, and that a release takes the right version, describes itself in the changelog, and marks its breaking changes.

The repository holds two things:
- **the workflows**, in [`.github/workflows/`](.github/workflows), with the composite action, [`action.yml`](action.yml), that they call, tagged `vX.Y.Z`;
- **the checks**, a Julia package, [ReleaseFlow](ReleaseFlow), registered in General from this repository's `ReleaseFlow/` directory, whose version, and tag, the workflows share.

Both share one version, in `ReleaseFlow/Project.toml`, and one changelog, [`ReleaseFlow/CHANGELOG.md`](ReleaseFlow/CHANGELOG.md).

The action runs the copy of ReleaseFlow at its own tag, so a workflow and its checks always come from one release; a package calls a workflow by its tag, and updates the checks by moving to a newer tag.

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
    branches: [main, develop]
    # Adding or removing the `skip changelog` label runs the checks again.
    types: [opened, synchronize, reopened, labeled, unlabeled]
# A new push, or a change of the labels, cancels the run that's still checking the pull request.
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true
permissions: {}
jobs:
  gitflow:
    uses: BioJulia/Workflows/.github/workflows/gitflow.yml@v1
    permissions:
      contents: read
```

The concurrency group lets only the newest run check a pull request, so that a force-push or a new commit doesn't leave the run of the outdated commit going.
The workflows that run on pushes, such as the back-merge and the register workflow below, take none, since cancelling one partway could leave a release half made.

And the back-merge, in `.github/workflows/BackMerge.yml`, which opens the pull request that brings a release or hotfix back into `develop`:

```yaml
name: Back-merge
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions: {}
jobs:
  back-merge:
    uses: BioJulia/Workflows/.github/workflows/back-merge.yml@v1
    permissions:
      contents: write
      pull-requests: write
    # The ReleaseFlow app's client ID and private key, or a personal access token, so that the pull request's checks run; see below.
    secrets:
      RELEASEFLOW_APP_CLIENT_ID: ${{ secrets.RELEASEFLOW_APP_CLIENT_ID }}
      RELEASEFLOW_APP_PRIVATE_KEY: ${{ secrets.RELEASEFLOW_APP_PRIVATE_KEY }}
      RELEASEFLOW_TOKEN: ${{ secrets.RELEASEFLOW_TOKEN }}
```

With `from` and `into`, the back-merge brings any branch into any other, such as a maintenance branch into the main branch, from a caller that runs on pushes to the maintenance branch:

```yaml
on:
  push:
    branches: [release-1.x]
jobs:
  back-merge:
    uses: BioJulia/Workflows/.github/workflows/back-merge.yml@v1
    permissions:
      contents: write
      pull-requests: write
    with:
      from: release-1.x
      into: master
```

From the main branch, the pull request's branch is `back-merge/vX.Y.Z`, named after the release; from any other, `back-merge/<from>-<commit>`, such as `back-merge/release-1.x-abc1234`.
The `releaseflow` environment then also allows the branch that it brings.
Under gitflow, ReleaseFlow's source branch check allows a `back-merge/*` branch only into develop, so a merge into the main branch suits a repository that doesn't require the gitflow checks there.

And the dependents' tests, in `.github/workflows/Dependents.yml`, which run the tests of the packages that depend on this one with the pull request's branch in its place:

```yaml
name: Dependents
on:
  pull_request:
    branches: [main]
  workflow_dispatch:
permissions: {}
jobs:
  dependents:
    uses: BioJulia/Workflows/.github/workflows/dependents.yml@v1
    permissions:
      contents: read
    with:
      dependents: |
        BioJulia/BED.jl
        BioJulia/GFF3.jl
```

Each dependent is checked out at its default branch, and its tests run as the check `dependents / <repository>`, with `julia-version`, `1` unless given.
A breaking release is expected to break its dependents until they adapt, so whether a ruleset requires these checks is the maintainers' choice; without that, they report what a release would break before it's registered.
A dependent whose project takes the package from a local path, through `[sources]`, tests against that path instead.

And the release, in `.github/workflows/Release.yml`, started by hand from the Actions tab, which prepares a release or a hotfix and opens its pull request:

```yaml
name: Release
on:
  workflow_dispatch:
    inputs:
      kind:
        type: choice
        options: [release, hotfix]
      step:
        type: choice
        options: [auto, patch, minor, major]
permissions: {}
jobs:
  release:
    uses: BioJulia/Workflows/.github/workflows/release.yml@v1
    permissions:
      contents: read
    with:
      model: gitflow   # or oneflow, or trunk
      kind: ${{ inputs.kind }}
      step: ${{ inputs.step }}
    secrets:
      RELEASEFLOW_APP_CLIENT_ID: ${{ secrets.RELEASEFLOW_APP_CLIENT_ID }}
      RELEASEFLOW_APP_PRIVATE_KEY: ${{ secrets.RELEASEFLOW_APP_PRIVATE_KEY }}
      RELEASEFLOW_TOKEN: ${{ secrets.RELEASEFLOW_TOKEN }}
```

It starts a release from `develop` under gitflow, and from the main branch otherwise, and a hotfix from the main branch, or under OneFlow from the last release's tag.
On a new branch, `release/vX.Y.Z` or `hotfix/vX.Y.Z`, it sets the version in `Project.toml`, moves the changelog's unreleased entries into a dated `## [X.Y.Z]` section with its comparison links, and, with `pin-action`, sets that action's `uses: …@vX.Y.Z` pins in the workflows; then it opens the pull request into the main branch, which the checks pass.
The step `auto` reads the unreleased section: a `### Breaking` subsection takes a breaking version, the next major version, or below 1.0 the next minor; `### Added` takes the next minor version; anything else, the next patch.
A hotfix is always the next patch, and its section waits for the fix's entry, so its pull request is a draft until the fix is pushed.

And the registration, in `.github/workflows/Register.yml`, which comments `@JuliaRegistrator register` on a release's commit once it merges into the main branch, with its section of the changelog as the release notes:

```yaml
name: Register
on:
  push:
    branches: [main]   # under OneFlow, workflow_dispatch, run on the release branch
  workflow_dispatch:
permissions: {}
jobs:
  register:
    uses: BioJulia/Workflows/.github/workflows/register.yml@v1
    permissions:
      contents: write
```

A commit whose version the registry already records has nothing to register, so a push that releases nothing does nothing.
A package's first release is registered by hand, since the registry reviews a new package before it merges: where the registry doesn't know the package, the workflow doesn't comment, and its warning and job summary give the comment to make, `@JuliaRegistrator register`, and the commit to make it on; once the registry merges the first release, after its waiting period for new packages, the workflow registers later releases by itself.
Registrator acts on comments from the repository's collaborators and its organization's members, which an app's bot isn't, and from `github-actions[bot]`, so the workflow comments with its own `GITHUB_TOKEN`, which needs the permission `contents: write` that the caller grants; where it's given, the secret `REGISTRATOR_TOKEN` comments instead, as described in [The Registrator token](#the-registrator-token).
TagBot then tags the release once the registry merges it.

OneFlow and trunk, in `.github/workflows/OneFlow.yml` or `.github/workflows/Trunk.yml`:

```yaml
name: OneFlow
on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened, labeled, unlabeled]
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true
permissions: {}
jobs:
  oneflow:
    uses: BioJulia/Workflows/.github/workflows/oneflow.yml@v1   # or trunk.yml
    permissions:
      contents: read
```

And, for a repository that callers follow by its major tag, such as one of GitHub Actions or reusable workflows, the tag workflow, in `.github/workflows/Tag.yml`, which moves each major tag, such as `v1`, to the newest release of its major version, `vX.Y.Z`:

```yaml
name: Tag
on:
  push:
    tags: ['v[0-9]+.[0-9]+.[0-9]+']   # version tags pushed by hand, or by TagBot with an SSH key
  workflow_run:
    workflows: [TagBot]               # TagBot's tags, made with GITHUB_TOKEN, start no workflow
    types: [completed]
  schedule:
    - cron: '17 4 * * *'              # a daily fallback
  workflow_dispatch:
permissions: {}
jobs:
  tag:
    uses: BioJulia/Workflows/.github/workflows/tag.yml@v1
    permissions:
      contents: write
    secrets:
      RELEASEFLOW_APP_CLIENT_ID: ${{ secrets.RELEASEFLOW_APP_CLIENT_ID }}
      RELEASEFLOW_APP_PRIVATE_KEY: ${{ secrets.RELEASEFLOW_APP_PRIVATE_KEY }}
      RELEASEFLOW_TOKEN: ${{ secrets.RELEASEFLOW_TOKEN }}
```

It works alongside [TagBot](https://github.com/JuliaRegistries/TagBot), which tags each release `vX.Y.Z` once the registry records it, at the commit that the registry records, with its GitHub release, but never moves a major tag; for a package in a subdirectory, TagBot's `tag_prefix: NO_PREFIX` makes its tags `vX.Y.Z` rather than `<Package>-vX.Y.Z`.
The tag workflow follows whatever version tags exist, whenever they appear, including those that a maintainer pushes by hand: a major tag moves only to its major version's newest release, by version, so an older version's tag doesn't move it, pre-releases such as `v2.0.0-rc1` are left out, and a rerun changes nothing.
It only moves a major tag forwards, to a release that descends from where the tag is, so deleting a version's tag doesn't take the major tag back to an older release; and where GitHub refuses a move, it reports GitHub's message as an error, and fails once every major tag is handled.
So callers of the major tag get a release once it's registered and tagged, and never a release whose tag doesn't exist yet.
For each major tag, it reports what it did, made it, moved it or left it, as a notice on the run and a line of the job's summary, under the job `<caller's job> / Major tags`.

It moves the tags with the ReleaseFlow app's token, or else `RELEASEFLOW_TOKEN`, or else the job's own token; a ruleset on `v*` tags must let that token through, such as with the app on its bypass list.
Its triggers run on the default branch or on a tag, not on the main branch, so the `releaseflow` environment must allow them, as described in [The ReleaseFlow environment](#the-releaseflow-environment), or the caller passes `with: { environment: '' }` to run the job without an environment, with the job's own token.

A package can follow the major tag, `v1`, or pin a release, such as `v1.0.0`; Dependabot's `github-actions` updates keep a pinned release current.

### Inputs

| Input | Default | Workflows | Meaning |
|:--|:--|:--|:--|
| `main-branch` | `main` | all | The branch of releases. |
| `develop-branch` | `develop` | gitflow, back-merge, release | The branch of unreleased work. |
| `from` | the main branch | back-merge | The branch to bring. |
| `into` | the develop branch | back-merge | The branch to bring it into. |
| `skip-label` | `skip changelog` | gitflow, oneflow, trunk | The label that exempts a pull request from the changelog entry. |
| `check-links` | `true` | gitflow, oneflow, trunk | Whether to check the changelog's comparison links. |
| `require-entry` | `true` | trunk | Whether a pull request that isn't a release must add a changelog entry, for a changelog without an unreleased section. |
| `project` | the root | gitflow, back-merge, oneflow, trunk, dependents, release | The package's directory, for a package in a subdirectory, such as `lib/Toy`. |
| `registry` | `General` | gitflow, oneflow, trunk, release | The registry of the package's releases. |
| `dependents` | none | dependents | The repositories of the packages that depend on this one, one per line or separated by commas. |
| `julia-version` | `1` | dependents | The version of Julia that the dependents' tests run on. |
| `model` | `gitflow` | release | The branching model, `gitflow`, `oneflow` or `trunk`. |
| `kind` | `release` | release | A release, or a hotfix. |
| `step` | `auto` | release | The step of the version, `auto`, `patch`, `minor` or `major`. |
| `pin-action` | none | release | An action whose pins in the workflows take the new version, such as `BioJulia/Workflows` for this repository. |
| `environment` | `releaseflow` | back-merge, release | The deployment environment that holds the secrets. |

For example, `with: { main-branch: master }` for a repository whose main branch is `master`.

### Setting up the repository

- **Rulesets.** The checks enforce the model once rulesets require pull requests and require the checks, by their names with the calling job's prefix, such as `gitflow / Source branch`:
  - gitflow, on both the main branch and `develop`: `Source branch`, `Version`, `Changelog`, `Breaking changes` and `Changelog entry`;
  - OneFlow, on the main branch: the same five;
  - trunk, on the main branch: `Release`, `Version`, `Changelog`, `Breaking changes` and `Changelog entry`.

  The checks that don't apply to a pull request are skipped, and GitHub counts a skipped check as passed, so a ruleset can require all of them.
  GitHub only offers a check's name once it has run, and only enforces rulesets on a private repository with a paid plan.
- **The label.** Create the `skip changelog` label, for changes that users won't notice.
- **The ReleaseFlow credentials.** Pull requests opened with the default `GITHUB_TOKEN` don't start workflows, so their checks would never report, and it can't push workflow files.
  The release and back-merge workflows use another token, in order of preference:
  - the ReleaseFlow app's, which they create for each run from the secrets `RELEASEFLOW_APP_CLIENT_ID` and `RELEASEFLOW_APP_PRIVATE_KEY`, as described in [Creating the ReleaseFlow app](#creating-the-releaseflow-app);
  - a fine-grained personal access token, in the secret `RELEASEFLOW_TOKEN`, as described in [Creating the ReleaseFlow token](#creating-the-releaseflow-token).

  The release needs one of them; without either, the back-merge pull request says to close and reopen it, which starts the checks.
  Keep these secrets in the repository's `releaseflow` environment, as described in [The ReleaseFlow environment](#the-releaseflow-environment).
  Either way, allow GitHub Actions to create pull requests, in the repository's Settings → Actions → General → Workflow permissions → "Allow GitHub Actions to create and approve pull requests".
- **Code owners.** A pull request runs its own copy of its workflow files, so a `CODEOWNERS` entry for `/.github/`, such as `/.github/ @<organization>/maintainers` in `.github/CODEOWNERS`, with the ruleset requiring a code owner's review, keeps a pull request from changing which checks it runs.
- **Forks.** The checks look at the pull request's head commit and this repository's branches, so they work the same for pull requests from forks; GitHub asks a maintainer to approve the workflows of a first-time contributor.

### The ReleaseFlow environment

Any workflow that runs in a repository can read its repository and organization secrets, whatever its branch: anyone who can push a branch, or run a workflow from one, could read the ReleaseFlow credentials with a workflow of their own.
An environment's secrets reach only the jobs on the branches that the environment allows, so the release and back-merge jobs run in the environment that their input `environment` names, `releaseflow`:

1. Open the repository's Settings → Environments, and choose "New environment", named `releaseflow`.
2. Under "Deployment branches and tags", choose "Selected branches and tags", and add rules for the main branch, such as `master`, where the back-merge runs; the branch that releases are started from in the Actions tab, such as `develop`, the default branch, where the tag workflow runs too; and tags matching `v*`, on which the tag workflow runs, whose ruleset limits who can make them.
3. Under "Environment secrets", add the ReleaseFlow credentials: `RELEASEFLOW_APP_CLIENT_ID` and `RELEASEFLOW_APP_PRIVATE_KEY` for the app, or `RELEASEFLOW_TOKEN` for a personal access token.

GitHub uses the environment's secrets in place of secrets of the same name that the caller passes, so the caller needs no change.
Without the environment, GitHub creates it unprotected on the first run, and the workflows work with repository or organization secrets, without that protection.

### Creating the ReleaseFlow app

A GitHub App belongs to the organization rather than to a person, so the branches and pull requests it opens come from its bot, `<app>[bot]`, which any maintainer can approve, and its tokens last an hour, so there's nothing to renew.
One app serves every repository of the organization that uses the release or back-merge workflow.

1. Open the organization's Settings → Developer settings → GitHub Apps, and choose "New GitHub App".
2. Name it, such as `<organization> ReleaseFlow`, which must be unique on GitHub, and give its homepage URL, such as the organization's page.
3. Under Webhook, clear "Active": the workflow calls the app, rather than the app listening for events.
4. Under repository permissions, set:
   - Contents: Read and write, to push a release's branch, and for the tag workflow, to move the major tags;
   - Pull requests: Read and write, to open the pull request;
   - Workflows: Read and write, since a release's branch may change workflow files, such as an action's pins.

   Metadata: Read-only is added by itself; leave every other permission at no access.
   A repository that only back-merges can give Pull requests alone, since the back-merge's job creates its branch with its own token, unless GitHub refuses it, which its log then says.
5. Under "Where can this GitHub App be installed?", choose "Only on this account", and choose "Create GitHub App".
6. On the app's page, note its Client ID, and under Private keys choose "Generate a private key", which downloads a `.pem` file.
7. Choose "Install App", install it on the organization, and choose "Only select repositories", with the repositories that use the release or back-merge workflow.
8. In each repository's `releaseflow` environment, add two environment secrets:
   - `RELEASEFLOW_APP_CLIENT_ID`, the Client ID;
   - `RELEASEFLOW_APP_PRIVATE_KEY`, the whole contents of the `.pem` file, from `-----BEGIN RSA PRIVATE KEY-----` to `-----END RSA PRIVATE KEY-----`.

   Then delete the downloaded file; a new key can be generated if it's lost, and a key can be revoked on the app's page if it leaks.

The caller passes both secrets to the reusable workflow, which creates the app's token for its repository with `actions/create-github-app-token`.
To check it, run the caller's Release workflow from the Actions tab: it pushes `release/vX.Y.Z` and opens its pull request as `<app>[bot]`, and its checks start.

### The Registrator token

The register workflow comments with its own `GITHUB_TOKEN`, as `github-actions[bot]`, so it needs no secret.
Where the comment should come from another account, such as a machine user that the maintainers share, the secret `REGISTRATOR_TOKEN`, a fine-grained personal access token of that account, comments instead:

1. Give the account write access to the repositories that use the register workflow, through a team of the organization.
2. Signed in as the account, open Settings → Developer settings → Personal access tokens → Fine-grained tokens, and choose "Generate new token", named such as `REGISTRATOR_TOKEN for <organization>`, with the organization as its resource owner, and an expiration.
3. Under repository access, choose "Only select repositories", with those repositories, and under repository permissions, set Contents to Read and write, which commenting on a commit needs.
4. Store it as an environment secret named `REGISTRATOR_TOKEN`, in each repository's `releaseflow` environment, and pass it to the register workflow with `secrets: { REGISTRATOR_TOKEN: ${{ secrets.REGISTRATOR_TOKEN }} }`.

### Creating the ReleaseFlow token

Where a GitHub App can't be created, such as for a repository of a personal account, a fine-grained personal access token does the same, in the secret `RELEASEFLOW_TOKEN`.
GitHub shows the token's owner as the author of the branches and pull requests, so prefer a maintainers' machine account, such as a bot account of the organization, to a person's: an author can't approve their own pull request, and the token outlives a maintainer's involvement.

1. Signed in as the token's owner, open Settings → Developer settings → Personal access tokens → Fine-grained tokens, and choose "Generate new token".
2. Name it, such as `RELEASEFLOW_TOKEN for <organization>`, and set an expiration; the organization may cap it, and the token must be regenerated and the secret updated before it expires.
3. Set the resource owner to the organization that owns the repositories, rather than the account; an organization that reviews fine-grained tokens holds it as pending until an owner approves it, in the organization's Settings → Personal access tokens → Pending requests.
4. Under repository access, choose "Only select repositories", and select the repositories that use the release or back-merge workflow.
5. Under repository permissions, set Contents, Pull requests and Workflows to Read and write, as for the app.
6. Choose "Generate token", and copy it; GitHub shows it only once.
7. Store it as an environment secret named `RELEASEFLOW_TOKEN`, in each repository's `releaseflow` environment.

## The checks

- **Source branch.**
  - Gitflow: the main branch takes only `release/*` and `hotfix/*` branches, and `develop` takes any other branch.
  - Gitflow and OneFlow: a hotfix carries no unreleased work, as it branches from what's released, and a release carries the unreleased work, as it branches from where that is.
    Git doesn't record which branch a branch was made from, so these rules look at the commits: where the head last met the branch of unreleased work, `develop` or the main branch, must be released for a hotfix, and not yet released for a release.
- **Version.** `Project.toml`'s version is a single step up from the last release's, without a prerelease or build suffix, and the next patch for a hotfix.
  A version whose section has `### Added` entries takes the next minor or major version, from 1.0, since below 1.0 Julia's compat takes the next patch as a compatible release; and a hotfix's section has none, since a hotfix adds no features.
  For gitflow and OneFlow, the branch's name gives the same version.
  The version isn't yet registered or tagged, except at the head commit, as OneFlow registers a release before it merges back.
- **Changelog.** `CHANGELOG.md` has a section for the version, `## [X.Y.Z]`, with entries, before every earlier version's, with nothing left under `## [Unreleased]`.
  Its comparison links compare each version's tag with the one before, and the newest with `HEAD` for the unreleased changes, unless `check-links` is false.
- **Breaking changes.** The last release's public API, its names, methods, keywords and fields, is still provided; its tests still pass against the head; and the compat bounds of Julia and of the dependencies still admit every version that they did.
  A breaking change needs the next major version, or the next minor version below 1.0, and a `### Breaking` subsection in the version's section; a hotfix can't be breaking.
  A public name is still exported, or declared `public`, as `using` takes it; a deprecated binding, such as one of `Base.@deprecate_binding`, still provides its old name.
  The job's summary lists what breaks.
- **Changelog entry.** A pull request of unreleased work adds an entry under `## [Unreleased]`, or rewords one, unless it has the `skip changelog` label, or brings the main branch back into `develop`.
  Where it changes the package's `src/` or `Project.toml`, its public API is compared with the base's, as the breaking check compares a release's: a removed or changed name, method, keyword or field needs a new entry under `### Breaking`, and an added one a new entry under `### Added`.
  A change in behaviour that keeps the API, or a feature that adds none, such as a workflow's input, isn't seen, and the breaking check of the release is left to find a breaking one.
- **Release.** For trunk, whether the pull request changes the version, which decides which checks run.

**The last release.** Gitflow compares a release with its main branch, which holds only releases.
OneFlow and trunk compare it with the last release: the main branch's version, at the commit whose tree the registry records for that version, which is what users install.
The tag `vX.Y.Z` is a second datapoint, and must agree with the registry; where the registry doesn't know the version, the tag is the last release, and without a tag, the main branch.

## Running the checks locally

[ReleaseFlow's README](ReleaseFlow/README.md) describes installing the package and running a check from the root of a package's repository, before a pull request.

## Developing

ReleaseFlow's tests, in `ReleaseFlow/test/`, call it directly, and build git repositories of a toy package and a scratch registry for the end-to-end checks, so they need no network:

```bash
julia --project=ReleaseFlow/test -e 'using Pkg; Pkg.instantiate()'
```

```bash
julia --project=ReleaseFlow/test ReleaseFlow/test/runtests.jl
```

## Contributing

This repository follows gitflow, with `master` and `develop`, and checks its own pull requests with its reusable gitflow workflow, through [`Self-Gitflow.yml`](.github/workflows/Self-Gitflow.yml):
- features and fixes branch from `develop`, add an entry under `## [Unreleased]` in [`ReleaseFlow/CHANGELOG.md`](ReleaseFlow/CHANGELOG.md), and merge back by pull request;
- a release branches from `develop` as `release/vX.Y.Z`, and a hotfix from `master` as `hotfix/vX.Y.Z`; either merges into `master` by pull request, and the Back-merge workflow then opens the pull request that brings `master` back into `develop`.

The workflows and ReleaseFlow share one version, in `ReleaseFlow/Project.toml`, and one changelog.
The reusable workflows call the action at the release that they belong to, such as `BioJulia/Workflows@v1.0.0`, so that a workflow and its checks come from one release; the CI's Pins check holds them to it.

A release or hotfix branch, which `Self-Release.yml` prepares from the Actions tab:
1. sets its version in `ReleaseFlow/Project.toml`;
2. sets every `uses: BioJulia/Workflows@…` in `.github/workflows/` to that version, `vX.Y.Z`;
3. moves the changelog's unreleased entries into a `## [X.Y.Z]` section, with its comparison link.

Once it merges into `master`:
1. `Self-Register.yml` comments `@JuliaRegistrator register subdir=ReleaseFlow` on the commit, with its section of the changelog, which registers ReleaseFlow in General from its subdirectory;
2. once General merges the registration, TagBot tags the commit `vX.Y.Z`, with its GitHub release, which the workflows' calls of the action name;
3. the Tag workflow, [`Self-Tag.yml`](.github/workflows/Self-Tag.yml), then moves the major tag, `v1`, to it, so callers get the release once it's registered and tagged.

A breaking change to a workflow's inputs, jobs or check names, or to ReleaseFlow's public API, takes a new major version, and a new major tag, such as `v2`.

Every package that calls the workflows runs what their tags point to, so:
- a ruleset on tags matching `v*` restricts who can create, move or delete them to the maintainers and the ReleaseFlow app, on its bypass list, with whose token TagBot tags releases and the Tag workflow moves the major tag;
- the workflows and the action pin the actions of other owners to commits, with their versions in comments, which Dependabot updates by pull request, labelled `skip changelog`;
- `.github/CODEOWNERS` requires a maintainer's review of any change to the workflows, the action, or ReleaseFlow, which the action runs.

The repository's own pull requests are checked by the released checks, since `Self-Gitflow.yml` calls `gitflow.yml` at the major tag, `v1`, while CI tests the pull request's own.
A release's pull request sets the workflows' calls of the action to its own tag, which only exists once it merges, so its checks are those of the release before it.
So the first release, `v1.0.0`, can't be checked before it's tagged: require the Gitflow checks in the rulesets of `master` and `develop` once it is.
Preparing and registering a release can't use the released action, though: a release may be the first with a check that they call, and its own tag only exists once it's registered.
So `Self-Release.yml` and `Self-Register.yml` call this commit's `release.yml` and `register.yml` with `local-action: true`, which run the action from the checked-out commit, in a job of its own; GitHub resolves every action of a job before it runs, even one whose step is skipped, so the job at the release, which names the tag that doesn't exist yet, is skipped whole.

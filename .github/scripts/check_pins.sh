#!/bin/bash
# The reusable workflows call this repository's action at the release that they belong to, so that a workflow and its checks always come from one release.
# Every such reference must name the same release.
# The repository has one version, ReleaseChecks', so a release, which RELEASE=true marks for a pull request into master, must call the action at that version, and the push of a release's tag, vX.Y.Z, in TAG, must be that version too; a major tag, such as v1, only moves to a release.
# Run from the root of the repository.
set -euo pipefail
refs=$(grep -hoE '^[[:space:]]*(- )?uses: BioJulia/Workflows@[^[:space:]]+' .github/workflows/*.yml | sed 's/.*@//' | sort -u)
if [ -z "$refs" ]; then
  echo "::error title=Pins::No workflow calls the action BioJulia/Workflows."
  exit 1
fi
if [ "$(echo "$refs" | wc -l)" -ne 1 ]; then
  echo "::error title=Pins::The workflows call the action at different releases: $(echo $refs); they must all call the same one."
  exit 1
fi
version="v$(sed -n 's/^version = "\(.*\)"$/\1/p' ReleaseChecks/Project.toml)"
echo "The workflows call the action at $refs; the version is $version."
tag="${TAG:-}"
if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$tag" != "$version" ]; then
  echo "::error title=Pins::The tag $tag isn't the version in ReleaseChecks/Project.toml, $version."
  exit 1
fi
if { [ "${RELEASE:-false}" = "true" ] || [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; } && [ "$refs" != "$version" ]; then
  echo "::error title=Pins::The release $version calls the action at $refs; set every reference to $version."
  exit 1
fi

#!/bin/bash
# The reusable workflows call this repository's action at the release that they belong to, so that a workflow and its script always come from one release.
# Every such reference must name the same release, and on the push of a release's tag, vX.Y.Z, that release; a major tag, such as v1, only moves to a release.
# Run from the root of the repository, with the pushed tag, if any, in TAG.
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
echo "The workflows call the action at $refs."
tag="${TAG:-}"
if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$refs" != "$tag" ]; then
  echo "::error title=Pins::The release $tag calls the action at $refs; set every reference to $tag before tagging."
  exit 1
fi

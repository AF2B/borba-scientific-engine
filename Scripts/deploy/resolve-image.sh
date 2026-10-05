#!/usr/bin/env bash
# Resolves a published version to what a deployment must use: the immutable reference of the image, by digest, and the
# commit it was built from. A tag can be moved and a digest cannot, so what was verified is what gets deployed.
#
# Usage: Scripts/deploy/resolve-image.sh REPOSITORY VERSION
#   REPOSITORY   The image repository, such as ghcr.io/<owner>/<repo>
#   VERSION      A release (v1.2.3, v1.2.3-rc.1) or a commit (sha-1a2b3c4). Never latest and never a branch: they move.
#
# Prints key=value lines, one per output, ready for $GITHUB_OUTPUT:
#   reference=<repository>@sha256:<digest>
#   commit=<the commit the image was built from>
#
# Pulls the image, so it fails when the image does not exist or cannot be read with the credentials in use.
# Exit status: 0 on success, 1 when the image could not be resolved, 2 on a usage error.
set -euo pipefail

readonly VERSION_PATTERN='^(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|sha-[0-9a-f]{7,40})$'
readonly REVISION_LABEL="org.opencontainers.image.revision"

if [[ $# -ne 2 ]]; then
    sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
fi

repository="$1"
version="$2"

if [[ ! "${version}" =~ ${VERSION_PATTERN} ]]; then
    echo "error: '${version}' is not a deployable version: use a release such as v1.2.3 or a commit such as sha-1a2b3c4" >&2
    exit 2
fi

if ! docker pull --quiet "${repository}:${version}" >/dev/null; then
    echo "error: could not pull ${repository}:${version}" >&2
    exit 1
fi

reference="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${repository}:${version}" \
    | grep "^${repository}@" | head -n 1)"
if [[ -z "${reference}" ]]; then
    echo "error: ${repository}:${version} has no digest: it was not pulled from a registry" >&2
    exit 1
fi

commit="$(docker image inspect --format "{{index .Config.Labels \"${REVISION_LABEL}\"}}" "${reference}")"
if [[ -z "${commit}" ]]; then
    echo "error: ${reference} carries no ${REVISION_LABEL} label, so the deployment cannot be verified against a commit" >&2
    exit 1
fi

echo "reference=${reference}"
echo "commit=${commit}"

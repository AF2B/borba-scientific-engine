#!/usr/bin/env bash
# Template for a deploy provider: the one piece of the deployment pipeline that knows how a particular platform runs the
# service. Copy this file to Scripts/deploy/providers/<name>.sh, implement the two commands and select the provider with
# the DEPLOY_PROVIDER variable of the GitHub environment. Names that start with an underscore cannot be selected.
#
# A provider does not verify, retry or roll back: Scripts/deploy.sh does, around these commands. A rollback is a
# deployment of the previous reference, so the two commands are all a platform has to offer.
#
# Commands:
#   current           Print the image reference that is deployed now, exactly as it was given to `apply`, or print nothing
#                     when the service is not deployed. Exit 0 either way; a non-zero exit means "could not find out".
#   apply REFERENCE   Make the platform run REFERENCE, such as ghcr.io/<owner>/<repo>@sha256:<digest>, and return once the
#                     platform considers the new version up. Exit non-zero when it did not get there. It runs the
#                     `migrate --yes` command of the image first when the platform has no separate job for it.
#
# Environment available to a provider:
#   DEPLOY_ENV_FILE   Path of a dotenv file with the environment's secrets and settings, written by the pipeline from the
#                     DEPLOY_ENV_FILE secret of the GitHub environment. Absent when the secret is not set.
#   Anything else the pipeline exports from the variables and secrets of the environment.
set -euo pipefail

case "${1:-}" in
    current)
        echo "implement: print the image reference that is deployed now" >&2
        exit 70
        ;;
    apply)
        echo "implement: deploy ${2:-REFERENCE} and wait until the platform reports it up" >&2
        exit 70
        ;;
    *)
        echo "usage: $0 current | apply REFERENCE" >&2
        exit 2
        ;;
esac

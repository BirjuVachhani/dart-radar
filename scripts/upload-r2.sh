#!/usr/bin/env bash
#
# Upload one file to a Cloudflare R2 bucket over R2's S3-compatible API.
#
#     scripts/upload-r2.sh <local-file> <object-key>
#
# Credentials come from the environment (the Makefile sources them from
# config.mk, CI from repository secrets):
#
#   R2_ACCOUNT_ID          Cloudflare account id, the S3 endpoint host
#   R2_ACCESS_KEY_ID       R2 API token access key id
#   R2_SECRET_ACCESS_KEY   R2 API token secret access key
#   R2_BUCKET              destination bucket
#   R2_CONTENT_TYPE        optional Content-Type for the object
#   R2_CACHE_CONTROL       optional Cache-Control for the object
#
# Uses the AWS CLI when it is installed, so a local upload goes through the same
# client as the release workflow, and falls back to rclone otherwise. Both are
# configured entirely through the environment: nothing is written to
# ~/.aws/credentials or ~/.config/rclone, so a stray config file cannot end up
# holding these keys.
#
# rclone's retries are turned down from their defaults on purpose. A wrong
# account id still resolves (the endpoint host is a wildcard), so bad
# credentials look like a retryable server error rather than a hard failure,
# and the defaults spend minutes on it before saying so.
set -euo pipefail

FILE="${1:-}"
KEY="${2:-}"

if [ -z "$FILE" ] || [ -z "$KEY" ]; then
    echo "usage: $0 <local-file> <object-key>" >&2
    exit 2
fi

test -f "$FILE" || { echo "ERROR: no such file: $FILE" >&2; exit 1; }

for var in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET; do
    eval "value=\${$var:-}"
    if [ -z "$value" ]; then
        echo "ERROR: $var is not set." >&2
        echo "       Add it to config.mk (see config.mk.example) or the environment." >&2
        exit 1
    fi
done

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
CONTENT_TYPE="${R2_CONTENT_TYPE:-application/octet-stream}"
CACHE_CONTROL="${R2_CACHE_CONTROL:-}"

echo "Uploading $(basename "$FILE") to s3://${R2_BUCKET}/${KEY} ..."

# Cache-Control is passed only when asked for, so an object that does not need
# one keeps whatever the bucket's own defaults are rather than being pinned to
# this script's idea of a good value. Held as arrays (an extra --header-upload
# for rclone) so an empty value adds no flag at all.
#
# Expanded below as ${ARR[@]+"${ARR[@]}"} rather than plain "${ARR[@]}":
# bash 3.2, which is what /bin/bash still is on macOS, treats expanding an
# empty array as an unbound variable and `set -u` would abort the upload.
AWS_CACHE_ARGS=()
RCLONE_CACHE_ARGS=()
if [ -n "$CACHE_CONTROL" ]; then
    AWS_CACHE_ARGS=(--cache-control "$CACHE_CONTROL")
    RCLONE_CACHE_ARGS=(--header-upload "Cache-Control: $CACHE_CONTROL")
fi

if command -v aws >/dev/null 2>&1; then
    # R2 rejects the CRC checksum headers the AWS CLI started sending by default
    # in 2.23; these two restore "send one only when the operation needs it".
    AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
    AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
    AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    aws s3 cp "$FILE" "s3://${R2_BUCKET}/${KEY}" \
        --endpoint-url "$ENDPOINT" \
        --content-type "$CONTENT_TYPE" \
        ${AWS_CACHE_ARGS[@]+"${AWS_CACHE_ARGS[@]}"}
elif command -v rclone >/dev/null 2>&1; then
    # An R2 API token scoped to one bucket cannot call CreateBucket, which is
    # what rclone's default bucket check attempts, so turn that check off.
    RCLONE_CONFIG_R2_TYPE=s3 \
    RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
    RCLONE_CONFIG_R2_REGION=auto \
    RCLONE_CONFIG_R2_ENDPOINT="$ENDPOINT" \
    RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
    rclone copyto "$FILE" "r2:${R2_BUCKET}/${KEY}" \
        --header-upload "Content-Type: $CONTENT_TYPE" \
        ${RCLONE_CACHE_ARGS[@]+"${RCLONE_CACHE_ARGS[@]}"} \
        --progress \
        --stats-one-line \
        --contimeout 30s \
        --retries 2 \
        --low-level-retries 3
else
    echo "ERROR: neither the AWS CLI nor rclone is installed." >&2
    echo "       Install one of them:" >&2
    echo "" >&2
    echo "           brew install awscli   # or: brew install rclone" >&2
    exit 1
fi

echo "Uploaded ${KEY} ($(du -h "$FILE" | cut -f1))"

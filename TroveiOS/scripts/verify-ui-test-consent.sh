#!/bin/bash
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

server_url="${SERVER_URL:-http://127.0.0.1:8080/api/v0}"
keycloak_url="${KEYCLOAK_URL:-http://localhost:8180}"
dev_password="${KEYCLOAK_DEV_PASSWORD:?KEYCLOAK_DEV_PASSWORD is required}"
result_dir="${TROVE_UI_CONSENT_RESULT_DIR:?TROVE_UI_CONSENT_RESULT_DIR is required}"
mkdir -p "$result_dir"
umask 077

participant_token="$(curl --fail --silent --show-error \
    --request POST "$keycloak_url/realms/trove/protocol/openid-connect/token" \
    --data-urlencode 'grant_type=password' --data-urlencode 'client_id=trove-dev-cli' \
    --data-urlencode 'username=alice@example.com' --data-urlencode "password=$dev_password" \
    | jq --exit-status --raw-output '.access_token | select(type == "string" and length > 0)')"
unset dev_password

# The test owns a fresh stack with one synthetic enrollment. More records are a fixture error.
enrollment="$(curl --fail --silent --show-error --header "Authorization: Bearer $participant_token" \
    "$server_url/participant/enrollments" | jq --exit-status 'select(length == 1) | .[0] |
        select(.withdrawnAt != null and .currentRevision == 2 and .stateVersion == 4)')"
enrollment_id="$(jq --raw-output '.id' <<< "$enrollment")"
receipts="$(curl --fail --silent --show-error --header "Authorization: Bearer $participant_token" \
    "$server_url/participant/enrollments/$enrollment_id/consents")"
jq --exit-status --arg enrollment "$enrollment_id" 'length == 2
    and (map(.revision) | sort == [1, 2])
    and (map(.id) | unique | length == 2)
    and (map(.presentation.digest) | unique | length == 2)
    and all(.[];
    .enrollmentId == $enrollment and .acceptedEnrollmentVersion == (.revision + 1)
    and .presentation.locale == "en-US" and (.presentation.digest | test("^[a-f0-9]{64}$"))
    and .userResponses.toggles.agree == true
    and .userResponses.signatures.participant.name.givenName == "Alice"
    and .userResponses.signatures.participant.name.familyName == "Participant"
    and (.userResponses.signatures.participant.signature | length > 0)
    and (.userResponses.signatures.participant.size | length == 2 and all(. > 0)))' <<< "$receipts" > /dev/null
for revision in 1 2; do
    receipt_id="$(jq --raw-output --argjson revision "$revision" '.[] | select(.revision == $revision) | .id' <<< "$receipts")"
    pdf_path="$result_dir/consent-revision-$revision.pdf"
    curl --fail --silent --show-error --header "Authorization: Bearer $participant_token" \
        "$server_url/participant/enrollments/$enrollment_id/consents/$receipt_id/pdf" \
        --output "$pdf_path"
    test "$(head -c 5 "$pdf_path")" = '%PDF-'
    test "$(wc -c < "$pdf_path")" -le 10000000
done
if cmp -s "$result_dir/consent-revision-1.pdf" "$result_dir/consent-revision-2.pdf"; then
    echo 'Expected distinct retained PDFs for the two reviewed revisions.' >&2
    exit 1
else
    comparison_status=$?
    if [ "$comparison_status" -ne 1 ]; then
        echo 'Unable to compare the retained consent PDFs.' >&2
        exit "$comparison_status"
    fi
fi
echo 'Verified two exact-revision consent receipts and authenticated PDFs after adoption and withdrawal.'

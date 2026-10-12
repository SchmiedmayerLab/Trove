#!/bin/bash
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"
SERVER_URL="${SERVER_URL:-http://127.0.0.1:8080/api/v0}"
REALM="${KEYCLOAK_REALM:-trove}"
DEV_CLIENT="${KEYCLOAK_DEV_CLIENT:-trove-dev-cli}"
DEV_PASSWORD="${KEYCLOAK_DEV_PASSWORD:?KEYCLOAK_DEV_PASSWORD is required}"
STUDY_TITLE="${TROVE_UI_TEST_STUDY_TITLE:-Trove UI Test Study}"

token_for() {
    local username="$1"
    curl --fail-with-body --silent --show-error \
        --request POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=password' \
        --data-urlencode "client_id=$DEV_CLIENT" \
        --data-urlencode "username=$username" \
        --data-urlencode "password=$DEV_PASSWORD" \
        | jq --raw-output '.access_token'
}

researcher_token="$(token_for 'leland@example.com')"
participant_token="$(token_for 'alice@example.com')"

profile="$(jq --null-input '{
    firstName: "Alice",
    lastName: "Participant",
    gender: "preferNotToState",
    dateOfBirth: "1990-01-01",
    region: "US",
    language: "en-US",
    phoneNumber: "+16505550123"
}')"

profile_status="$(
    curl --silent --output /dev/null --write-out '%{http_code}' \
        --header "Authorization: Bearer $participant_token" \
        "$SERVER_URL/participant/profile"
)"

case "$profile_status" in
    200) profile_method=PUT ;;
    404) profile_method=POST ;;
    *)
        echo "Unexpected participant profile status: $profile_status" >&2
        exit 1
        ;;
esac

curl --fail-with-body --silent --show-error \
    --request "$profile_method" "$SERVER_URL/participant/profile" \
    --header "Authorization: Bearer $participant_token" \
    --header 'Content-Type: application/json' \
    --data-binary "$profile" \
    > /dev/null

curl --fail-with-body --silent --show-error \
    --header "Authorization: Bearer $participant_token" \
    "$SERVER_URL/participant/enrollments" \
    | jq --raw-output '.[] | select(.withdrawnAt == null) | .id' \
    | while IFS= read -r enrollment_id; do
        [ -z "$enrollment_id" ] || curl --fail-with-body --silent --show-error \
            --request POST "$SERVER_URL/participant/enrollments/$enrollment_id/withdraw" \
            --header "Authorization: Bearer $participant_token" \
            > /dev/null
    done

group_id="$(
    curl --fail-with-body --silent --show-error \
        --header "Authorization: Bearer $researcher_token" \
        "$SERVER_URL/groups" \
        | jq --raw-output '.[0].id'
)"

curl --fail-with-body --silent --show-error \
    --header "Authorization: Bearer $researcher_token" \
    "$SERVER_URL/groups/$group_id/studies" \
    | jq --raw-output --arg title "$STUDY_TITLE" '.[] | select(.title == $title) | .id' \
    | while IFS= read -r existing_study_id; do
        [ -n "$existing_study_id" ] || continue
        existing_revision="$(
            curl --fail-with-body --silent --show-error \
                --header "Authorization: Bearer $researcher_token" \
                "$SERVER_URL/studies/$existing_study_id" \
                | jq --exit-status --raw-output '.draftRevision'
        )"
        curl --fail-with-body --silent --show-error \
            --request DELETE "$SERVER_URL/studies/$existing_study_id" \
            --header "Authorization: Bearer $researcher_token" \
            --header "If-Match: \"$existing_revision\"" \
            > /dev/null
    done

created_study="$(
    jq --null-input --arg title "$STUDY_TITLE" '{title: $title, icon: "heart"}' \
        | curl --fail-with-body --silent --show-error \
            --request POST "$SERVER_URL/groups/$group_id/studies" \
            --header "Authorization: Bearer $researcher_token" \
            --header 'Content-Type: application/json' \
            --data-binary @-
)"
study_id="$(jq --exit-status --raw-output '.id' <<< "$created_study")"
created_revision="$(jq --exit-status --raw-output '.draftRevision' <<< "$created_study")"

updated_study="$(
jq --null-input '{collectionRequirements: [{
    profile: "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate",
    sourceKind: "participant-app"
}], consent: {"en-US": {
    title: "Study Consent",
    content: "Please review this synthetic study consent.\n\n<toggle id=\"agree\" expected-value=\"true\">I agree to participate.</toggle>\n\n<signature id=\"participant\"/>"
}}}' \
    | curl --fail-with-body --silent --show-error \
        --request PATCH "$SERVER_URL/studies/$study_id" \
        --header "Authorization: Bearer $researcher_token" \
        --header "If-Match: \"$created_revision\"" \
        --header 'Content-Type: application/json' \
        --data-binary @-
)"
updated_revision="$(jq --exit-status --raw-output '.draftRevision' <<< "$updated_study")"
validation="$(
    curl --fail-with-body --silent --show-error \
        --request POST "$SERVER_URL/studies/$study_id/draft/validations" \
        --header "Authorization: Bearer $researcher_token" \
        --header "If-Match: \"$updated_revision\""
)"
jq --exit-status --arg revision "$updated_revision" \
    '.draftRevision == $revision and .publicationRevision == 1' <<< "$validation" > /dev/null
validation_id="$(jq --exit-status --raw-output '.id' <<< "$validation")"

jq --null-input --arg id "$validation_id" '{validationId: $id}' \
    | curl --fail-with-body --silent --show-error \
    --request POST "$SERVER_URL/studies/$study_id/publish" \
    --header "Authorization: Bearer $researcher_token" \
    --header "If-Match: \"$updated_revision\"" \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    > /dev/null

curl --fail-with-body --silent --show-error \
    --header "Authorization: Bearer $participant_token" \
    "$SERVER_URL/participant/studies" \
    | jq --exit-status --arg study_id "$study_id" 'any(.[]; .studyId == $study_id)' \
    > /dev/null

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "study_title=$STUDY_TITLE" >> "$GITHUB_OUTPUT"
fi

echo "Seeded published study '$STUDY_TITLE' and participant profile."

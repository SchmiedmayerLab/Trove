<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Study Authoring CLI

The `trove` executable uses the generated Swift API client. It supports reading a
draft, creating and editing a study, importing a localized questionnaire component,
validating a publication candidate, and explicitly publishing that candidate.
It does not provide browser login, refresh-token storage, delegation management,
participant access, or the complete dashboard command surface yet.

Build with `swift build --package-path TroveAPI --product trove`. Use `trove --help`
and each command's `--help` for arguments. The server URL must include the API
version path. Output is one typed JSON document on standard output; errors go to
standard error and exit nonzero without printing credentials or server response
bodies.

Run from SwiftPM's product directory with its adjacent resource bundles. Copying
only the executable can omit resources required by its dependencies; a distributable
CLI package or installer is not provided yet.

## Authentication

Supply an already-issued access token through `--token-file /protected/access-token`
or `--token-stdin` with a pipe from a credential provider. Do not place a token in
command arguments or environment variables. Credential files must be regular,
owned by the current user, and unreadable by other users (for example mode `0600`).
Symlinks, terminal input, oversized credentials and header-control characters are
rejected. Tokens are held only for the command; this is not a login or renewal flow.

HTTPS is required. Local development can opt into
`--allow-insecure-loopback --server http://127.0.0.1:8080/api/v0`.
HTTP redirects are never followed, including same-origin redirects.

Draft commands optionally accept `--delegation <UUID>` to select an existing
server-side grant for a registered draft-only OAuth client. The grant ID is not a
credential. Study creation and publication do not accept that option; the server
independently enforces the token's client identity, membership and permissions.

## Reviewed Writes

1. Run `trove study get <study-id>` with the connection and credential options.
2. Prepare a `StudyPatchInput` JSON file and retain the returned `draftRevision`.
3. Run `trove study edit <study-id> --file edit.json --revision <draft-revision>`.
4. Read the draft again after successful edits. Component writes share the same
   study revision. A `412` requires review, not replacing the revision and blindly
   replaying the same edit.

`trove study create --group <group-id> --file create.json` accepts
`StudyCreateInput`, for example `{"title":"Example Study","icon":"heart"}`.
`trove questionnaire import --study <study-id> --revision <draft-revision> --file questionnaire.json --name "Wellbeing" --locale en-US`
accepts a raw UTF-8 FHIR Questionnaire JSON file. The CLI checks the resource type
and wraps its original text in the typed localized component input; it does not
rewrite resource IDs, profiles or whitespace. The server assigns the separate
component ID. Full validation and supported questionnaire execution rules remain
server-owned.

## Exact Publication

Run `trove study validate <study-id> --revision <draft-revision>`. Review the
returned candidate ID, revision, archive digest, questionnaire evidence, validator
identity, execution capability and expiry. Then an authorized administrator can
run `trove study publish <study-id> --validation <candidate-id> --revision <draft-revision>`.

Publication never implicitly validates or selects the latest draft. Retain the
candidate ID and revision: the server uses that pair for an exact authorized
publication retry if a response is lost. Other writes are not retried automatically;
after an ambiguous transport failure, inspect server state before repeating them.

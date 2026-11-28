<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Study CLI

The `trove` executable uses the generated Swift API client. It supports reading a
draft, creating and editing a study, importing, exporting and validating a
multilingual questionnaire component, validating a draft into a publication
candidate, and explicitly publishing that candidate.
Researchers with clinical data access can also retrieve study measurement pages
and download authorized recordings.
It does not provide browser login, refresh-token storage, delegation management
or participant access.

Build with `swift build --package-path TroveAPI --product trove`. Use `trove --help`
and each command's `--help` for arguments. The server URL must include the API
version path. Except for recording downloads, output is one typed JSON document
on standard output; `trove questionnaire export` writes the stored FHIR resource
itself. Errors go to
standard error and exit nonzero without printing credentials or server response
bodies.

Run from SwiftPM's product directory with its adjacent resource bundles. Copying
only the executable can omit resources required by its dependencies. There is no
distributable CLI package or installer.

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

## Study Data

`trove study data <study-id>` uses the same connection and credential options.
It requires interactive researcher authority, membership in the study's group,
and that group's explicit `data-reader` capability. Draft delegation and
administrator membership alone do not authorize clinical data.

The command returns one `StudyDataPage` JSON document. `--limit` selects 1–100
outputs (default 20); `--before <nextBefore>` continues the returned page in the
same study and version view. `--history` includes superseded versions, marked
`isCurrent: false`; they must not be counted as additional measurements. Current
versions are the default. The CLI does not automatically fetch or accumulate all
pages. Start again from the first page after changed eligibility or to see newly
attributed historical data. These live pages are not frozen final datasets.

Each record contains a derived study-specific FHIR collection Bundle in
`bundleBase64`. Decode Base64 directly to bytes when saving a Bundle; parsing and
rewriting FHIR numbers with ordinary JSON tools can lose precision. The returned
Bundles preserve authorized source facts and derivation Provenance, but are not
the original custody Bundles. Store command output as study data in an approved
location. A `503` may require a smaller `--limit`; `400` or `409` on continuation
may require restarting. Failed requests produce no page on standard output.

## Recording Downloads

`trove study recording <study-id> <grant-id> --output recording.csv` uses the same
connection and credential options. Take both IDs from the `DocumentReference`
attachment URL in the derived study Bundle. Use `--history` if that URL selects
`versions=history`; the default selects current versions. The grant ID is not a
credential. The server independently verifies current researcher and study access
for every download and audits the release.

The output contains the original bytes described by the attachment, including
when the server stores a compressed representation. The CLI requests identity HTTP
encoding and rejects an encoded response before saving any output bytes. Binary HTTP transport
preserves CSV, JSON, FHIR, CDA and PPG source bytes; the required original-media
header must name a registered supported type. JSON values and version parameters
are not decoded or rewritten. Downloads stream with
backpressure on macOS and Linux into a private temporary file in the destination
directory. On macOS, inherited extended ACLs on staging storage are rejected
before requesting or writing recording data. Successful completion publishes an
owner-only file atomically without
replacing existing files or symlinks. The destination filesystem must support
hard links for this exclusive publication. The server-provided filename is never
used.
Failures and task cancellation discard private staging storage and publish no
partial output. An ungraceful process termination can leave a private
`.trove-recording-*` directory, which the owner may remove after the process exits.

`--max-bytes` sets the accepted file limit (default 512 MiB, maximum 2147483647).
Advertised oversized responses are rejected before body consumption; unknown-size
responses stop when they cross the limit. Network buffering can receive some
additional in-flight bytes, but no oversized file is published. Response headers have a ten-minute deadline; the connection timeout is 30 seconds
and an idle response times out after 60 seconds. Existing output paths and unavailable output
directories fail before networking. Recording downloads produce no standard
output. Save recordings only in an approved study-data location.

## Reviewed Writes

1. Run `trove study get <study-id>` with the connection and credential options.
2. Prepare a `StudyPatchInput` JSON file and retain the returned `draftRevision`.
3. Run `trove study edit <study-id> --file edit.json --revision <draft-revision>`.
4. Read the draft again after successful edits. Component writes share the same
   study revision. A `412` requires review, not replacing the revision and blindly
   replaying the same edit.

`trove study create --group <group-id> --file create.json` accepts
`StudyCreateInput`, for example
`{"title":"Example Study","sourceLanguage":"en","icon":"heart"}`. Study details
in a `StudyPatchInput` name their source language and are keyed by BCP 47
language tag, for example
`{"details":{"sourceLanguage":"en","content":{"en":{"title":"Example Study"},"de":{"title":"Beispielstudie"}}}}`.

A questionnaire is one FHIR Questionnaire JSON file holding every language:
`Questionnaire.language` names the base language, and standard `translation`
extensions carry the others.
`trove questionnaire import --study <study-id> --revision <draft-revision> --file questionnaire.json --name "Wellbeing"`
accepts that raw UTF-8 file without a byte order mark. The CLI checks the resource type and wraps its
original text in the typed component input; it does not rewrite resource IDs,
profiles, translations or whitespace. The server assigns the separate component
ID and returns it with the base and translation languages it finds.
`trove questionnaire export --study <study-id> --component <component-id> > questionnaire.json`
writes the stored resource to standard output byte for byte, without a trailing
newline, so an export of an imported file is identical to it. Full validation and
supported questionnaire execution rules remain server-owned.

## Validation

`trove questionnaire validate --study <study-id> --component <component-id>`
validates the stored resource and prints one `QuestionnaireValidation` document: the
`status`, the SHA-256 digest of the validated bytes, the draft revision it was read
at, the validator identity and contract, and every finding in `diagnostics`. Each
finding has a `severity`, a `source` (`fhir`, `grove` or `trove`), a `rule`, the
FHIRPath `path` of the element, the `language` of a translation it concerns and,
for Trove's rules, a `nextAction`. The command changes nothing and its result is
not publication evidence. It requires a grant that permits validation when used
with `--delegation`.

`trove study validate <study-id> --revision <draft-revision>` validates the exact
draft revision and prints one `StudyDraftValidation` document. `blockers` lists the
findings that prevent publication, each naming its `componentId` where it concerns
a component; `advisories` lists warnings and information. A `candidate` is present
only when the status is `valid`.

Both commands print their result before exiting with a status-specific code:

| Exit code | Status | Meaning |
|---|---|---|
| 0 | `valid` | No finding is an error and no check was reported as skipped. |
| 2 | `invalid` | At least one finding is an error. |
| 3 | `incomplete` | A check could not be evaluated, so validity is not established. |
| 4 | `unavailable` | The validator could not be reached; validate again later. |
| 1 | none | The request failed; nothing is printed on standard output. |

## Scenarios

`trove questionnaire scenario --study <study-id> --component <component-id> --file scenarios.json`
evaluates named synthetic answer sets against the stored resource and prints one
`QuestionnaireScenarioReport` document: the branching graph, and for each scenario
the state of every item instance, the outcome of each condition and the answers a
completed response keeps. The file holds `{"scenarios": [...]}`; each scenario has a
unique `name` and its answers in `item`, in the shape of `QuestionnaireResponse.item`.
The command changes nothing, and a grant that permits inspection suffices with
`--delegation`. It exits 0 when the graph and every scenario are fully evaluated and
3 when a condition, expression, dependency cycle, answer or a warning in the graph
leaves the analysis incomplete; a failed request exits 1 and prints nothing on
standard output. The [study model](../docs/Study-Model-and-Research-Workflows.md#branching-scenarios)
describes the evaluation rules.

## Language Approvals

Publication requires an administrator's approval of each administration language
of each questionnaire, for the exact stored resource.
`trove study approve-language <study-id> --component <component-id> --sha256 <digest> --language <language>`
approves one language. `--sha256` names the digest of the resource you reviewed,
as `trove study validate` reports it for the questionnaire; the server refuses an
approval when the stored resource has a different digest. The command prints the
`QuestionnaireLanguageApproval`, also when the same approval is already in force.
`trove study revoke-language-approval <study-id> --component <component-id> --approval <approval-id>`
revokes one. Both use interactive administrator authority and do not change the
draft revision; validate the draft again before publishing. `trove questionnaire import`
admits the base language only; admit a translation language on the questionnaire
form or through the component API before approving it.

## Exact Publication

Run `trove study validate <study-id> --revision <draft-revision>`. Review the
returned candidate ID, revision, archive digest, questionnaire evidence, validator
identity, execution capability, expiry and any advisories. Then an authorized
administrator can run
`trove study publish <study-id> --validation <candidate-id> --revision <draft-revision>`.

Publication never implicitly validates or selects the latest draft. Retain the
candidate ID and revision: the server uses that pair for an exact authorized
publication retry if a response is lost. Other writes are not retried automatically;
after an ambiguous transport failure, inspect server state before repeating them.

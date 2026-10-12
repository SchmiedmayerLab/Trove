<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Web

The researcher-facing portal. Researchers define studies by specifying metadata, participant criteria, and app components; those definitions then configure the participant app.

<picture><source media="(prefers-color-scheme: dark)" srcset="../docs/images/web/study-details~dark.png"><img src="../docs/images/web/study-details.png" alt="Study details and participant preview"></picture>

See the [platform tour](../docs/Platform-Tour.md) for current web and mobile
screens, and the [capture guide](../docs/images/README.md) to reproduce them.

## Getting started

1. Install the dependencies: `npm install`
2. Copy the environment file: `cp .env.example .env`
3. Start the API server and Keycloak from [`TroveInfrastructure/docker`](../TroveInfrastructure/docker)
4. Start the development server: `npm run dev`

## Container transport

The image defaults to `APP_ENVIRONMENT=production` and serves HTTPS on port 8080.
Mount the PEM certificate chain and unencrypted private key read-only at
`/run/secrets/https/tls.crt` and `/run/secrets/https/tls.key`. Missing or invalid
identity files prevent startup; HTTP does not serve dashboard content. Restart
the container after certificate renewal and verify a fresh connection.

The local Compose files explicitly select `APP_ENVIRONMENT=development` for HTTP.
Other values are rejected. This does not change Vite's local development server.
Both modes use the same SPA, asset-cache and runtime-configuration rules.

The container uses one unprivileged Nginx worker and a read-only root filesystem
in Kubernetes and Compose. Its only writable volume is a 16 MiB in-memory cache
at `/var/cache/nginx`, holding the PID, runtime settings and temporary files.
The application assets and Nginx configuration remain read-only.

Frontend request logs are disabled because URLs may contain authentication codes
or participant identifiers. Startup diagnostics remain available; deployed ingress
logs retain only the configured allowlisted operational fields.

CI builds the image and runs `TroveInfrastructure/tools/verify_web_image.py` against
it. The same local check requires Docker, Node.js 24, and the pinned Python tooling
dependencies:

```bash
docker build -f TroveWeb/Dockerfile -t trove-web:local .
python3 -m venv .build/web-tooling
.build/web-tooling/bin/pip install -r TroveInfrastructure/tools/requirements.txt
.build/web-tooling/bin/python TroveInfrastructure/tools/verify_web_image.py --image trove-web:local
```

Run these commands from the repository root. The verifier owns and removes its
containers, network and synthetic certificates; its evidence directory contains
only logs and a result summary. This is not live-cluster or release acceptance.

## API client

The TypeScript client is generated from the shared contract at [`TroveAPI/openapi.yaml`](../TroveAPI/openapi.yaml). Regenerate it after the contract changes:

```bash
npm run generate:api
```

Handwritten client boundaries live outside the generated directory. HTTP failures
become `ApiError` values using the response status, not a status supplied in the
response body. Only string problem titles and details are accepted. Network and
cancellation errors retain their original identity because no HTTP response exists.

The access-token provider owns a request session. Replacing or removing the
provider cancels its requests; pending refreshes and late JSON results cannot be
adopted by the replacement session. Concurrent requests share a refresh within
that session, while cancelling one request does not cancel the others. API
requests are restricted to the configured origin and reject redirects. Register
or clear the provider at authentication boundaries rather than overriding the
client's fetch configuration; tests mock the underlying network transport.
Cancellation cannot undo a mutation already accepted by the server; it is not
permission to replay that mutation automatically after signing in again.

`AuthProvider` owns session closure and cache clearing. Logout, refresh failure,
malformed identity claims, or a changed issuer, subject, audience, realm role or
group closes the dashboard before continuing. Late Keycloak refresh callbacks
cannot reopen that lifetime. Continuing uses a fresh page so router state is
not reused across authority changes; ordinary token renewal keeps the current
session and updates display claims. Logout uses Keycloak's POST flow, while local
credentials and UI access are closed even if navigation fails. This does not
claim that the identity provider completed logout while it was unreachable.

Dashboard group roles require an exact `/group/admin` or `/group/researcher`
claim. Extra path segments do not grant a role, and an explicit administrator
role takes precedence regardless of claim order. These roles support the UI;
the server independently authorizes every protected operation. Audit access is
not inferred from a dashboard role.

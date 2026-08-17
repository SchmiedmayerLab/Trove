<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# API

The shared OpenAPI contract (`openapi.yaml`) and the Swift libraries generated from it: `TroveAPITypes`, `TroveAPIClient`, and `TroveAPIServer`. It is the single source of truth consumed by the server, the iOS app, and — through a generated TypeScript client — the web portal.

## Code generation

The generated `Types.swift`, `Client.swift`, and `Server.swift` are checked in. Regenerate them after editing `openapi.yaml`:

```bash
swift run --package-path TroveAPI TroveAPIGenerator --package-path TroveAPI
```

Individual targets can be regenerated on their own:

```bash
swift run --package-path TroveAPI TroveAPIGenerator --package-path TroveAPI --types --client
```

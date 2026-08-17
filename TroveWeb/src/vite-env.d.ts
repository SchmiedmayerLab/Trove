//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_BASE_PATH: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

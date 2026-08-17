//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { defineConfig } from "@hey-api/openapi-ts";

// eslint-disable-next-line import-x/no-default-export -- required by hey-api config
export default defineConfig({
  input: "../TroveAPI/openapi.yaml",
  output: { path: "src/lib/api/generated" },
  plugins: [
    "@hey-api/typescript",
    "@hey-api/sdk",
    "@hey-api/client-fetch",
    "zod",
    {
      name: "@tanstack/react-query",
      queryOptions: true,
      mutationOptions: true,
    },
  ],
});

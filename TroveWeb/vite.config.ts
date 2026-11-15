//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import path from "node:path";
import tailwindcss from "@tailwindcss/vite";
import { tanstackRouter } from "@tanstack/router-plugin/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import istanbul from "vite-plugin-istanbul";
import { dedent } from "./src/utils/dedent";

export default defineConfig(({ mode }) => ({
  root: ".",
  base: "/",
  plugins: [
    tanstackRouter({
      routeToken: "layout",
      routeFilePrefix: "~",
      routeTreeFileHeader: [
        dedent`
          //
          // This source file is part of the Trove open-source project
          //
          // SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
          //
          // SPDX-License-Identifier: MIT
          //
        `,
        "/* prettier-ignore-start */",
        "/* eslint-disable */",
        "// @ts-nocheck",
        "// noinspection JSUnusedGlobalSymbols",
      ],
    }),
    react(),
    tailwindcss(),
    // Only instrument when the end-to-end run asks for coverage; the shipped bundle is untouched.
    ...(process.env.COVERAGE === "true" ?
      [
        istanbul({
          include: "src/*",
          exclude: [
            "node_modules",
            "src/lib/api/generated",
            "src/routeTree.gen.ts",
          ],
          extension: [".ts", ".tsx"],
          requireEnv: false,
        }),
      ]
    : []),
  ],
  build: {
    rolldownOptions: {
      output: {
        minify: { compress: { dropConsole: mode === "production" } },
      },
    },
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
}));

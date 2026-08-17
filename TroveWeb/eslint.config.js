//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { getEslintReactConfig } from "@schmiedmayerlab/grove-configurations";

const defaultConfig = getEslintReactConfig({
  tsconfigRootDir: import.meta.dirname,
});
const config = [
  { ignores: ["src/lib/api/generated/**"] },
  ...defaultConfig,
  {
    rules: {
      // TanStack Router redirects and not-found results are thrown by design.
      "@typescript-eslint/only-throw-error": "off",
    },
  },
  // This is necessary to make sure that the import.meta.dirname is available in the config
  // See https://github.com/eslint/eslint/discussions/16037
  { languageOptions: { ecmaVersion: "latest", sourceType: "module" } },
];

export default config;

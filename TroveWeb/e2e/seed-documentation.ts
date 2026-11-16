// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

// Node 26 executes this fixture without a build step.
// eslint-disable-next-line import-x/extensions
import { seedDocumentationStudy } from "./documentation-fixture.ts";

console.log(JSON.stringify(await seedDocumentationStudy()));

//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { cn as _cn } from "@schmiedmayerlab/grove-design-system";
import { twMerge } from "tailwind-merge";

export const cn = (...inputs: Parameters<typeof _cn>) =>
  twMerge(_cn(...inputs));

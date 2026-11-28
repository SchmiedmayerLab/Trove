// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { zLanguageTag } from "@/lib/api/generated/zod.gen";

export const languageTagHint =
  "Use a language tag such as en, de, zh-Hant or pt-BR.";

/** A BCP 47 language with an optional script and region in canonical case, as the API accepts it. */
export const isLanguageTag = (value: string): boolean =>
  zLanguageTag.safeParse(value).success;

// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { DeviceUnitIdentifiers } from "./CollectionForm";

describe("device unit identifier control", () => {
  it("labels and describes the choice and starts unchecked", () => {
    const markup = renderToStaticMarkup(
      <DeviceUnitIdentifiers checked={false} onChange={() => undefined} />,
    );
    expect(markup).toContain("Include device unit identifiers in study data");
    expect(markup).toContain(
      "(native, provider and FHIR collection recordings) are not available to this study",
    );
    const described = /aria-describedby="([^"]+)"/.exec(markup)?.[1];
    expect(described).toBeDefined();
    expect(markup).toContain(`id="${described}"`);
    expect(markup).toMatch(/aria-checked="false"|data-state="unchecked"/);
    expect(markup).not.toMatch(/aria-checked="true"|data-state="checked"/);
  });
});

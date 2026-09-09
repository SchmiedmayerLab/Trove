// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import { parseGroupMemberships } from "./groupMemberships";

describe("group claims", () => {
  it.each([
    ["/Lab/admin", "/Lab/researcher"],
    ["/Lab/researcher", "/Lab/admin"],
  ])(
    "retains the strongest explicit role regardless of order: %j",
    (...groups) => {
      expect(parseGroupMemberships(groups)).toEqual({ Lab: "admin" });
    },
  );

  it.each([
    "/Lab/admin/extra",
    "/Lab/admin/",
    "//Lab/admin",
    "Lab/admin",
    "/Lab",
    "/Lab/audit-reader",
  ])("does not infer membership from %s", (path) =>
    expect(parseGroupMemberships([path])).toEqual({}),
  );

  it.each([
    { groups: null, expected: {} },
    { groups: true, expected: {} },
    { groups: 42, expected: {} },
    { groups: "/Lab/admin", expected: {} },
    { groups: {}, expected: {} },
    {
      groups: [null, 7, {}, "/Lab/researcher"],
      expected: { Lab: "researcher" },
    },
  ])("treats claims as untrusted data: $groups", ({ groups, expected }) => {
    expect(parseGroupMemberships(groups)).toEqual(expected);
  });

  it("preserves exact group names without prototype setters", () => {
    const groups = parseGroupMemberships([
      "/__proto__/admin",
      "/constructor/researcher",
      "/Other/researcher",
    ]);
    expect(Object.hasOwn(groups, "__proto__")).toBe(true);
    expect(groups.__proto__).toBe("admin");
    expect(groups.constructor).toBe("researcher");
    expect(groups.Other).toBe("researcher");
    expect(Object.getPrototypeOf(groups)).toBe(Object.prototype);
  });
});

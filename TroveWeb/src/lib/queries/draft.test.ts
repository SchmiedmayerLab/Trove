// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { afterEach, describe, expect, it, vi } from "vitest";
import { draftHeaders, readDraftSnapshot, selectFormSnapshot } from "./draft";
import { getStudiesByStudyId } from "../api/generated/sdk.gen";

vi.mock("../api/generated/sdk.gen", () => ({ getStudiesByStudyId: vi.fn() }));
afterEach(() => vi.resetAllMocks());

const initial = {
  draftRevision: "e02b460f-437b-45ab-a68f-aa28e685ca85",
  title: "Original",
};
const changed = {
  draftRevision: "20f01b57-0faa-4249-b534-cde0e4b95368",
  title: "Changed elsewhere",
};

describe("revision-bound form snapshots", () => {
  it("retains both loaded content and its revision while a form has unsaved changes", () => {
    const loaded = selectFormSnapshot(
      undefined,
      initial,
      "study:locale",
      false,
    );
    const retained = selectFormSnapshot(loaded, changed, "study:locale", true);
    expect(retained).toBe(loaded);
    expect(retained?.value).toBe(initial);
    expect(draftHeaders(initial.draftRevision)).toEqual({
      "If-Match": `"${initial.draftRevision}"`,
    });
  });

  it("adopts new content and revision together when the form is clean", () => {
    const loaded = selectFormSnapshot(undefined, initial, "study", false);
    expect(selectFormSnapshot(loaded, changed, "study", false)?.value).toBe(
      changed,
    );
    expect(selectFormSnapshot(loaded, initial, "study", false)).toBe(loaded);
  });

  it("does not reuse another study or locale's snapshot while its data is unavailable", () => {
    const loaded = selectFormSnapshot(undefined, initial, "study:en", false);
    expect(
      selectFormSnapshot(loaded, undefined, "other:en", true),
    ).toBeUndefined();
    expect(selectFormSnapshot(loaded, changed, "study:de", true)?.value).toBe(
      changed,
    );
    expect(selectFormSnapshot(loaded, undefined, "study:en", true)).toBe(
      loaded,
    );
  });

  it("loads the study before fresh child data and retains the earlier revision", async () => {
    const order: string[] = [];
    vi.mocked(getStudiesByStudyId).mockImplementation(() => {
      order.push("study");
      return Promise.resolve({
        data: {
          ...initial,
          id: "study",
          collectionRequirements: [],
          locales: ["en-US"],
          icon: "",
          details: {},
          consent: {},
          visibility: "unlisted" as const,
          enrollmentConditions: "none" as const,
          participationCriterion: { type: "ageAtLeast" as const, age: 18 },
        },
        request: new Request("https://api.example.test/studies/study"),
        response: new Response(),
      });
    });
    const signal = new AbortController().signal;
    const read = vi.fn((receivedSignal: AbortSignal) => {
      order.push("component");
      expect(receivedSignal).toBe(signal);
      return Promise.resolve({ title: "Fresh component" });
    });
    const snapshot = await readDraftSnapshot("study", read, signal);
    expect(order).toEqual(["study", "component"]);
    expect(getStudiesByStudyId).toHaveBeenCalledWith({
      path: { studyId: "study" },
      signal,
      throwOnError: true,
    });
    expect(snapshot).toEqual({
      draftRevision: initial.draftRevision,
      value: { title: "Fresh component" },
    });
    expect(getStudiesByStudyId).toHaveBeenCalledTimes(1);
  });

  it("does not read children when study authorization or loading fails", async () => {
    vi.mocked(getStudiesByStudyId).mockRejectedValue(new Error("Denied"));
    const read = vi.fn();
    await expect(readDraftSnapshot("study", read)).rejects.toThrow("Denied");
    expect(read).not.toHaveBeenCalled();
  });
});

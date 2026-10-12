// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { toast } from "@schmiedmayerlab/grove-design-system";
import { afterEach, expect, it, vi } from "vitest";
import { onMutationError } from "./mutationCallbacks";
import { ApiError } from "../api/client";

vi.mock("@schmiedmayerlab/grove-design-system", () => ({
  toast: { error: vi.fn() },
}));
vi.mock("../env", () => ({
  env: { VITE_API_BASE_PATH: "https://api.example.test" },
}));
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllGlobals();
});

it("requires explicit reload and review after a stale write without automatically retrying", () => {
  const reload = vi.fn();
  vi.stubGlobal("window", { location: { reload } });
  onMutationError("Save failed")(new ApiError({ title: "Stale", status: 412 }));
  expect(reload).not.toHaveBeenCalled();
  const call = vi.mocked(toast.error).mock.calls[0];
  expect(call[0]).toBe("The study draft has changed");
  expect(call[1]?.description).toContain("Your changes were not saved");
  expect(call[1]?.description).toContain("reload and review");
  expect(call[1]?.action).toMatchObject({ label: "Reload draft" });
});

it("does not label authorization and transport failures as stale drafts", () => {
  onMutationError("Save failed")(
    new ApiError({ title: "Denied", status: 403 }),
  );
  expect(toast.error).toHaveBeenCalledWith("Save failed", {
    description: "Denied",
    duration: 5000,
  });
});

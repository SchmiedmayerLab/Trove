// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { afterEach, describe, expect, it, vi } from "vitest";
import { setAccessTokenProvider } from "../api/client";
import {
  downloadStudyRecording,
  recordingDownloadErrorMessage,
  recordingFallbackByteLimit,
} from "./studyRecordingDownload";
import type { StudyRecording } from "./studyRecordings";

vi.mock("../env", () => ({
  env: { VITE_API_BASE_PATH: "https://api.example.test" },
}));

const recording: StudyRecording = {
  studyId: "11111111-1111-4111-8111-111111111111",
  grantId: "22222222-2222-4222-8222-222222222222",
  versions: "current",
  byteCount: 4,
};
const bytes = new Uint8Array([97, 44, 98, 10]);
const headers = {
  "Content-Type": "text/csv; charset=utf-8",
  "Cache-Control": "no-store",
};
const deferred = <T>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
};
const destination = (write?: (chunk: Uint8Array) => Promise<void> | void) => {
  const saved: number[] = [];
  const close = vi.fn();
  const abort = vi.fn();
  const stream = new WritableStream<Uint8Array>({
    async write(chunk) {
      saved.push(...chunk);
      await write?.(chunk);
    },
    close,
    abort,
  });
  const createWritable = vi.fn(() => Promise.resolve(stream));
  const picker = vi.fn(() => Promise.resolve({ createWritable }));
  vi.stubGlobal("window", { showSaveFilePicker: picker });
  return { saved, close, abort, picker, createWritable };
};
const download = (signal = new AbortController().signal) =>
  downloadStudyRecording(recording, signal, () => undefined);

afterEach(() => {
  setAccessTokenProvider(undefined);
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("recording download streaming", () => {
  it("uses the generated authenticated endpoint and commits exact CSV bytes", async () => {
    const target = destination();
    const fetch = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      expect(request.url).toBe(
        `https://api.example.test/api/v0/studies/${recording.studyId}/data/recordings/${recording.grantId}?versions=current`,
      );
      expect(request.cache).toBe("no-store");
      expect(request.redirect).toBe("error");
      expect(request.headers.get("Authorization")).toBe(
        "Bearer synthetic-token",
      );
      return Promise.resolve(new Response(bytes, { headers }));
    });
    vi.stubGlobal("fetch", fetch);
    setAccessTokenProvider(() => Promise.resolve("synthetic-token"));
    const progress = vi.fn();
    await expect(
      downloadStudyRecording(recording, new AbortController().signal, progress),
    ).resolves.toBe("saved");
    expect(target.saved).toEqual([...bytes]);
    expect(target.close).toHaveBeenCalledOnce();
    expect(target.abort).not.toHaveBeenCalled();
    expect(progress).toHaveBeenLastCalledWith(bytes.length);
    expect(fetch).toHaveBeenCalledOnce();
  });

  it.each([new Uint8Array([97]), new Uint8Array([1, 2, 3, 4, 5])])(
    "aborts the destination on truncated or oversized CSV",
    async (body) => {
      const target = destination();
      vi.stubGlobal("fetch", () =>
        Promise.resolve(new Response(body, { headers })),
      );
      await expect(download()).rejects.toThrow("Recording size mismatch");
      expect(target.close).not.toHaveBeenCalled();
      expect(target.abort).toHaveBeenCalledOnce();
      expect(target.saved.length).toBeLessThanOrEqual(recording.byteCount);
    },
  );

  it("keeps source reads bounded while the file writer applies backpressure", async () => {
    const started = deferred<undefined>();
    const resume = deferred<undefined>();
    const target = destination(async () => {
      started.resolve(undefined);
      await resume.promise;
    });
    let produced = 0;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new Uint8Array([produced++]));
        if (produced === 100) controller.close();
      },
    });
    vi.stubGlobal("fetch", () =>
      Promise.resolve(new Response(body, { headers })),
    );
    const pending = downloadStudyRecording(
      { ...recording, byteCount: 100 },
      new AbortController().signal,
      () => undefined,
    );
    await started.promise;
    // Allow pending reads to settle while the first disk write remains blocked.
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    expect(produced).toBeLessThanOrEqual(4);
    expect(target.close).not.toHaveBeenCalled();
    resume.resolve(undefined);
    await expect(pending).resolves.toBe("saved");
    expect(target.saved).toHaveLength(100);
  });

  it.each(["cancel", "session"])(
    "aborts a pending write on %s without committing a partial file",
    async (reason) => {
      const started = deferred<undefined>();
      const resume = deferred<undefined>();
      const target = destination(async () => {
        started.resolve(undefined);
        await resume.promise;
      });
      vi.stubGlobal("fetch", () =>
        Promise.resolve(new Response(bytes, { headers })),
      );
      const cancellation = new AbortController();
      const pending = download(cancellation.signal);
      await started.promise;
      if (reason === "cancel") cancellation.abort();
      else setAccessTokenProvider(() => Promise.resolve("another-session"));
      const failed = expect(pending).rejects.toMatchObject({
        name: "AbortError",
      });
      resume.resolve(undefined);
      await failed;
      expect(target.close).not.toHaveBeenCalled();
      expect(target.abort).toHaveBeenCalledOnce();
    },
  );

  it("cannot adopt another session while the save picker is open", async () => {
    const chosen = deferred<object>();
    const picker = vi.fn(() => chosen.promise);
    vi.stubGlobal("window", { showSaveFilePicker: picker });
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    const pending = download();
    expect(picker).toHaveBeenCalledOnce();
    setAccessTokenProvider(() => Promise.resolve("another-session"));
    chosen.resolve({});
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("does not fetch when the save picker is cancelled", async () => {
    vi.stubGlobal("window", {
      showSaveFilePicker: () =>
        Promise.reject(new DOMException("Cancelled", "AbortError")),
    });
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    await expect(download()).rejects.toMatchObject({ name: "AbortError" });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("rejects unexpected content before opening a destination stream", async () => {
    const target = destination();
    vi.stubGlobal("fetch", () =>
      Promise.resolve(
        new Response(bytes, {
          headers: { ...headers, "Content-Type": "text/html" },
        }),
      ),
    );
    await expect(download()).rejects.toThrow("Invalid recording response");
    expect(target.createWritable).not.toHaveBeenCalled();
  });

  it("bounds fallback capacity before requesting recording contents", async () => {
    vi.stubGlobal("window", {});
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    await downloadStudyRecording(
      { ...recording, byteCount: recordingFallbackByteLimit + 1 },
      new AbortController().signal,
      () => undefined,
    ).catch((error: unknown) => {
      expect(recordingDownloadErrorMessage(error)).toContain("64 MiB");
      expect(recordingDownloadErrorMessage(error)).toContain("Trove CLI");
    });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("offers bounded fallback downloads after verifying their full size", async () => {
    vi.stubGlobal("window", {});
    const anchor = { href: "", download: "", click: vi.fn() };
    vi.stubGlobal("document", { createElement: () => anchor });
    const url = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:synthetic");
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", () =>
      Promise.resolve(new Response(bytes, { headers })),
    );
    await expect(download()).resolves.toBe("started");
    const blob = url.mock.calls[0][0] as Blob;
    expect(new Uint8Array(await blob.arrayBuffer())).toEqual(bytes);
    expect(anchor.click).toHaveBeenCalledOnce();
    expect(anchor.download).toBe(`recording-${recording.grantId}.csv`);
  });

  it("does not offer a partial fallback download", async () => {
    vi.stubGlobal("window", {});
    const url = vi.spyOn(URL, "createObjectURL");
    vi.stubGlobal("fetch", () =>
      Promise.resolve(new Response(new Uint8Array([97]), { headers })),
    );
    await expect(download()).rejects.toThrow("Recording size mismatch");
    expect(url).not.toHaveBeenCalled();
  });

  it.each([401, 403, 404, 409, 503])(
    "sanitizes HTTP %s without retrying or opening a destination stream",
    async (status) => {
      const target = destination();
      const fetch = vi.fn(() =>
        Promise.resolve(
          Response.json(
            { title: "synthetic-sensitive", detail: "synthetic-sensitive" },
            { status },
          ),
        ),
      );
      vi.stubGlobal("fetch", fetch);
      await download().catch((error: unknown) => {
        expect(recordingDownloadErrorMessage(error)).not.toContain(
          "synthetic-sensitive",
        );
      });
      expect(fetch).toHaveBeenCalledOnce();
      expect(target.createWritable).not.toHaveBeenCalled();
    },
  );
});

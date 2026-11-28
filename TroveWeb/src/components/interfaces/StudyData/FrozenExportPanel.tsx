// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { Button } from "@schmiedmayerlab/grove-design-system";
import { useEffect, useRef, useState } from "react";
import { Card } from "@/components/ui/Card";
import { apiSessionSignal } from "@/lib/api/client";
import {
  createStudyExport,
  downloadStudyExport,
  executeStudyExport,
  getStudyExport,
} from "@/lib/api/generated/sdk.gen";
import type { FrozenExport } from "@/lib/api/generated/types.gen";
import { zFrozenExport } from "@/lib/api/generated/zod.gen";
import { verifiedExportFile } from "@/lib/queries/studyExportDownload";

const downloadFile = async (
  studyId: string,
  job: FrozenExport,
  signal: AbortSignal,
) => {
  const result = await downloadStudyExport({
    signal,
    cache: "no-store",
    throwOnError: true,
    path: { studyId, exportId: job.id },
    parseAs: "blob",
  });
  const blob = await verifiedExportFile(result.data, job);
  signal.throwIfAborted();
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `study-export-${job.id}.ndjson`;
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
};

export const FrozenExportPanel = ({ studyId }: { studyId: string }) => {
  const [job, setJob] = useState<FrozenExport>();
  const [exportId, setExportId] = useState("");
  const [history, setHistory] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const pendingRef = useRef<AbortController | undefined>(undefined);
  const requestRef = useRef<string | undefined>(undefined);
  useEffect(() => () => pendingRef.current?.abort(), []);

  const run = async (action: "create" | "read" | "execute" | "download") => {
    if (pendingRef.current) return;
    const controller = new AbortController();
    pendingRef.current = controller;
    const signal = AbortSignal.any([controller.signal, apiSessionSignal()]);
    const options = { signal, cache: "no-store", throwOnError: true } as const;
    setBusy(true);
    setError("");
    try {
      if (action === "download") {
        if (job?.status !== "ready") return;
        await downloadFile(studyId, job, signal);
        return;
      }
      const path = { studyId, exportId };
      let result;
      if (action === "create") {
        requestRef.current ??= crypto.randomUUID();
        result = await createStudyExport({
          ...options,
          path: { studyId },
          body: {
            requestId: requestRef.current,
            versions: history ? "history" : "current",
          },
        });
      } else if (action === "execute") {
        result = await executeStudyExport({ ...options, path });
      } else {
        result = await getStudyExport({ ...options, path });
      }
      signal.throwIfAborted();
      const next = zFrozenExport.parse(result.data);
      if (
        next.studyId.toLowerCase() !== studyId.toLowerCase() ||
        (action !== "create" &&
          next.id.toLowerCase() !== exportId.toLowerCase())
      )
        throw new Error();
      setJob(next);
      setExportId(next.id);
      if (action === "create") requestRef.current = undefined;
    } catch {
      if (!signal.aborted) {
        if (action !== "download") setJob(undefined);
        setError(
          "The export request failed. Check the identifier and current study permissions.",
        );
      }
    } finally {
      pendingRef.current = undefined;
      if (!controller.signal.aborted) setBusy(false);
    }
  };

  return (
    <Card className="gap-3 p-5">
      <h2>Frozen study exports</h2>
      <label>
        <input
          type="checkbox"
          checked={history}
          disabled={busy}
          onChange={(event) => {
            requestRef.current = undefined;
            setHistory(event.target.checked);
          }}
        />{" "}
        Include superseded versions
      </label>
      <Button disabled={busy} onClick={() => void run("create")}>
        Capture membership
      </Button>
      <label>
        Export ID{" "}
        <input
          value={exportId}
          disabled={busy}
          onChange={(event) => {
            setExportId(event.target.value);
            setJob(undefined);
          }}
        />
      </label>
      <Button disabled={busy || !exportId} onClick={() => void run("read")}>
        Read manifest
      </Button>
      {job && (
        <div aria-live="polite">
          <p>
            {job.outputCount} outputs ({job.status})
          </p>
          {job.status === "queued" ?
            <Button disabled={busy} onClick={() => void run("execute")}>
              Prepare file
            </Button>
          : <>
              <p>
                SHA-256 <code>{job.sha256}</code>
              </p>
              <Button disabled={busy} onClick={() => void run("download")}>
                Download NDJSON
              </Button>
            </>
          }
          <details>
            <summary>Manifest</summary>
            <pre className="overflow-auto">{JSON.stringify(job, null, 2)}</pre>
          </details>
        </div>
      )}
      {error && <p role="alert">{error}</p>}
    </Card>
  );
};

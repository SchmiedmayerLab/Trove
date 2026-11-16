// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { Button } from "@schmiedmayerlab/grove-design-system";
import { useEffect, useId, useRef, useState } from "react";
import { Card } from "@/components/ui/Card";
import type {
  StudyDataPage,
  StudyDataRecord,
  StudyDataVersions,
} from "@/lib/api/generated/types.gen";
import {
  loadStudyData,
  studyBundleBytes,
  studyDataErrorMessage,
} from "@/lib/queries/studyData";
import {
  downloadStudyRecording,
  recordingDownloadErrorMessage,
  recordingFallbackCapacityMessage,
  supportsStreamingRecordingSave,
} from "@/lib/queries/studyRecordingDownload";
import {
  studyRecordings,
  type StudyRecording,
} from "@/lib/queries/studyRecordings";

const downloadRecord = (record: StudyDataRecord) => {
  const blob = new Blob([studyBundleBytes(record.bundleBase64)], {
    type: "application/fhir+json",
  });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `study-record-${record.id}.json`;
  anchor.click();
  // Release after the browser has consumed the click's download URL.
  setTimeout(() => URL.revokeObjectURL(url), 0);
};

/** The route keys this component by study; AuthProvider unmounts it on session changes. */
export const StudyDataPanel = ({ studyId }: { studyId: string }) => {
  const controlId = useId();
  const [versions, setVersions] = useState<StudyDataVersions>("current");
  const [limit, setLimit] = useState(20);
  const [page, setPage] = useState<StudyDataPage>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string>();
  const [recordings, setRecordings] = useState<
    Record<string, StudyRecording[]>
  >({});
  const [download, setDownload] = useState<{
    received: number;
    total: number;
  }>();
  const [downloadStatus, setDownloadStatus] = useState<string>();
  const pendingRef = useRef<AbortController | null>(null);
  const pendingDownloadRef = useRef<AbortController | null>(null);

  useEffect(
    () => () => {
      pendingRef.current?.abort();
      pendingDownloadRef.current?.abort();
    },
    [],
  );

  const clear = () => {
    pendingRef.current?.abort();
    pendingRef.current = null;
    pendingDownloadRef.current?.abort();
    pendingDownloadRef.current = null;
    setPage(undefined);
    setRecordings({});
    setDownload(undefined);
    setDownloadStatus(undefined);
    setError(undefined);
    setLoading(false);
  };

  const load = async (before?: string) => {
    clear();
    const controller = new AbortController();
    pendingRef.current = controller;
    setLoading(true);
    try {
      const result = await loadStudyData(
        studyId,
        versions,
        limit,
        before,
        controller.signal,
      );
      const attachments = Object.fromEntries(
        result.records.map((record) => [
          record.id,
          studyRecordings(record, studyId, versions),
        ]),
      );
      if (!controller.signal.aborted) {
        setRecordings(attachments);
        setPage(result);
      }
    } catch (failure) {
      if (!controller.signal.aborted) setError(studyDataErrorMessage(failure));
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  };

  const saveRecording = async (recording: StudyRecording) => {
    if (pendingDownloadRef.current) return;
    const controller = new AbortController();
    pendingDownloadRef.current = controller;
    setError(undefined);
    setDownloadStatus(undefined);
    setDownload({ received: 0, total: recording.byteCount });
    let lastProgress = 0;
    try {
      const result = await downloadStudyRecording(
        recording,
        controller.signal,
        (received) => {
          if (pendingDownloadRef.current !== controller) return;
          const now = performance.now();
          if (received === recording.byteCount || now - lastProgress >= 100) {
            lastProgress = now;
            setDownload({ received, total: recording.byteCount });
          }
        },
      );
      if (pendingDownloadRef.current === controller) {
        setDownloadStatus(
          result === "saved" ? "Recording saved." : (
            "Recording download started."
          ),
        );
      }
    } catch (failure) {
      if (pendingDownloadRef.current === controller)
        setError(recordingDownloadErrorMessage(failure));
    } finally {
      if (pendingDownloadRef.current === controller) {
        pendingDownloadRef.current = null;
        setDownload(undefined);
      }
    }
  };

  return (
    <Card className="gap-5 p-5">
      <p className="text-text-secondary text-sm">
        Read the measurements currently authorized for this study. Pages are a
        live view; new data or permission changes may require starting again.
        Downloads contain study-specific FHIR records and their provenance.
      </p>
      <div className="flex flex-wrap items-end gap-4">
        <div className="flex flex-col gap-1 text-sm">
          <label htmlFor={`${controlId}-versions`}>Versions</label>
          <select
            id={`${controlId}-versions`}
            className="bg-layer rounded border p-2"
            value={versions}
            onChange={(event) => {
              clear();
              setVersions(
                event.target.value === "history" ? "history" : "current",
              );
            }}
          >
            <option value="current">Current measurements</option>
            <option value="history">Include superseded versions</option>
          </select>
        </div>
        <div className="flex flex-col gap-1 text-sm">
          <label htmlFor={`${controlId}-limit`}>Records per page</label>
          <select
            id={`${controlId}-limit`}
            className="bg-layer rounded border p-2"
            value={limit}
            onChange={(event) => {
              clear();
              setLimit(Number(event.target.value));
            }}
          >
            {[1, 10, 20, 50, 100].map((value) => (
              <option key={value} value={value}>
                {value}
              </option>
            ))}
          </select>
        </div>
        <Button onClick={() => void load()} disabled={loading}>
          Load first page
        </Button>
        <Button
          onClick={() => void load(page?.nextBefore)}
          disabled={loading || !page?.nextBefore}
        >
          Next page
        </Button>
      </div>
      {versions === "history" && (
        <p className="text-text-secondary text-sm">
          History includes earlier versions of measurements. Do not count these
          as additional measurements. Withdrawn or retracted data is excluded.
        </p>
      )}
      {loading && <p role="status">Loading study data…</p>}
      {error && <p role="alert">{error}</p>}
      {download && (
        <div className="flex flex-wrap items-center gap-3">
          <p role="status">
            {download.received === 0 ?
              "Preparing recording download…"
            : `Saving recording: ${(download.received / 1024 / 1024).toFixed(1)} of ${(download.total / 1024 / 1024).toFixed(1)} MiB`
            }
          </p>
          <Button onClick={() => pendingDownloadRef.current?.abort()}>
            Cancel download
          </Button>
        </div>
      )}
      {downloadStatus && <p role="status">{downloadStatus}</p>}
      {Object.values(recordings).some((items) => items.length > 0) &&
        !supportsStreamingRecordingSave() && (
          <p className="text-text-secondary text-sm">
            {recordingFallbackCapacityMessage}
          </p>
        )}
      {page && (
        <>
          <p role="status">
            {page.records.length === 0 ?
              "No eligible measurements on this page."
            : `Outputs: ${page.records.reduce((count, record) => count + record.outputs.length, 0)}. Records: ${page.records.length}.`
            }
          </p>
          {page.records.length > 0 && (
            <div className="overflow-x-auto">
              <table className="w-full text-left text-sm">
                <caption className="sr-only">Authorized study records</caption>
                <thead>
                  <tr>
                    <th scope="col" className="p-2">
                      Record
                    </th>
                    <th scope="col" className="p-2">
                      Outputs
                    </th>
                    <th scope="col" className="p-2">
                      Download
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {page.records.map((record, index) => (
                    <tr key={record.id}>
                      <th scope="row" className="p-2 font-normal">
                        {index + 1}
                      </th>
                      <td className="p-2">
                        <div>
                          {
                            record.outputs.filter((output) => output.isCurrent)
                              .length
                          }{" "}
                          current
                        </div>
                        <div>
                          {
                            record.outputs.filter((output) => !output.isCurrent)
                              .length
                          }{" "}
                          superseded
                        </div>
                      </td>
                      <td className="p-2">
                        <Button
                          onClick={() => {
                            try {
                              downloadRecord(record);
                            } catch {
                              setError(
                                "Unable to download this record. Load the page again.",
                              );
                            }
                          }}
                          aria-label={`Download record ${index + 1}`}
                        >
                          Download FHIR
                        </Button>
                        {recordings[record.id].map(
                          (recording, recordingIndex) => (
                            <Button
                              key={recording.grantId}
                              disabled={download !== undefined || loading}
                              onClick={() => void saveRecording(recording)}
                              aria-label={`Save recording ${recordingIndex + 1} for record ${index + 1}`}
                            >
                              Save recording (
                              {(recording.byteCount / 1024 / 1024).toFixed(1)}{" "}
                              MiB)
                            </Button>
                          ),
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </Card>
  );
};

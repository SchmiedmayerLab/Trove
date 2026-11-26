//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  toast,
} from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { useNavigate, useParams } from "@tanstack/react-router";
import { Rocket } from "lucide-react";
import { useState } from "react";
import { getStudiesByStudyId } from "@/lib/api/generated/sdk.gen";
import type { StudyDraftValidation } from "@/lib/api/generated/types.gen";
import { componentListQueryOptions } from "@/lib/queries/component";
import { onMutationError } from "@/lib/queries/mutationCallbacks";
import {
  publicationNeedsReview,
  publicationRequest,
  validationRequest,
} from "@/lib/queries/publication";
import {
  publishedStudiesQueryOptions,
  usePublishStudyMutation,
  useValidateStudyMutation,
} from "@/lib/queries/study";
import { readinessDestination } from "@/lib/readinessDestination";
import { itemLinkId, linkIdRange } from "@/lib/validationDiagnostics";
import { FeaturedIconContainer } from "../../ui/FeaturedIconContainer";
import { PublicationFindings } from "./PublicationFindings";

/** The element of the questionnaire form a questionnaire finding concerns. */
const questionnaireTarget = (
  finding: { rule: string; path: string; language?: string },
  collection: boolean,
) => {
  if (collection) return "collection-edit";
  if (finding.rule === "language-approval-missing" && finding.language)
    return `approval-${finding.language}`;
  if (finding.path.endsWith(".administrationLanguages"))
    return "administrationLanguages";
  return "questionnaire-resource";
};

const PublicationDialog = ({
  studyId,
  draftRevision,
  latestRevision,
  onClose,
}: {
  studyId: string;
  draftRevision: string;
  latestRevision: number | undefined;
  onClose: () => void;
}) => {
  const navigate = useNavigate();
  const { group } = useParams({ strict: false });
  const validateStudy = useValidateStudyMutation();
  const publishStudy = usePublishStudyMutation();
  const { data: components } = useQuery(componentListQueryOptions({ studyId }));
  const [report, setReport] = useState<StudyDraftValidation>();
  const [needsReview, setNeedsReview] = useState(false);
  const candidate = report?.candidate;
  const isPending = validateStudy.isPending || publishStudy.isPending;
  const publicationStatus =
    latestRevision === undefined ?
      "No revision has been published."
    : `Current published revision: v${latestRevision}.`;

  const onValidate = () => {
    if (candidate || needsReview || isPending) return;
    setReport(undefined);
    validateStudy.mutate(validationRequest(studyId, draftRevision), {
      onSuccess: setReport,
      onError: (error) => setNeedsReview(publicationNeedsReview(error)),
    });
  };

  const onPublish = () => {
    if (!report || !candidate || needsReview || isPending) return;
    // The server owns expiry checks and recognizes exact accepted retries,
    // including a lost reply whose candidate expired in the meantime.
    publishStudy.mutate(
      publicationRequest(studyId, report.draftRevision, candidate),
      {
        onSuccess: (data) => {
          toast.success(`Study published (v${data.revision})`);
          onClose();
        },
        onError: (error) => setNeedsReview(publicationNeedsReview(error)),
      },
    );
  };

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !isPending) onClose();
      }}
    >
      <DialogContent className="max-h-[calc(100dvh-2rem)] max-w-lg overflow-y-auto">
        <DialogHeader className="items-center sm:items-start">
          <FeaturedIconContainer
            icon={Rocket}
            className="border-border-tertiary mb-4 size-8 rounded-lg shadow-xs"
          />
          <DialogTitle>
            {candidate ?
              "Review publication candidate"
            : "Validate study draft"}
          </DialogTitle>
          <DialogDescription>
            {candidate ?
              "Review this exact candidate before publishing. Publishing does not rebuild or select a newer draft."
            : `${publicationStatus} Only saved changes are included. A valid draft becomes a candidate for review; validation does not publish.`
            }
          </DialogDescription>
        </DialogHeader>
        <dl className="grid gap-1 text-sm">
          <dt className="font-medium">Draft revision</dt>
          <dd className="mb-2 font-mono text-xs break-all">
            {report?.draftRevision ?? draftRevision}
          </dd>
          {candidate && (
            <>
              <dt className="font-medium">Publication revision</dt>
              <dd className="mb-2">v{candidate.publicationRevision}</dd>
              <dt className="font-medium">Validation ID</dt>
              <dd className="mb-2 font-mono text-xs break-all">
                {candidate.id}
              </dd>
              <dt className="font-medium">Archive SHA-256</dt>
              <dd className="mb-2 font-mono text-xs break-all">
                {candidate.bundleSha256}
              </dd>
              <dt className="font-medium">Validated questionnaires</dt>
              <dd className="mb-2">{report.questionnaires.length}</dd>
              <dt className="font-medium">Candidate expires</dt>
              <dd>{new Date(candidate.expiresAt).toLocaleString()}</dd>
            </>
          )}
        </dl>
        {candidate && (
          <details className="text-sm">
            <summary>Validation details</summary>
            <dl className="mt-2 grid gap-1 text-xs break-all">
              <dt className="font-medium">Validator</dt>
              <dd>{candidate.validatorIdentity}</dd>
              <dt className="font-medium">FHIR contract</dt>
              <dd>{candidate.contractRevision}</dd>
              <dt className="font-medium">Execution capability</dt>
              <dd>{candidate.executionCapability}</dd>
            </dl>
          </details>
        )}
        {report?.questionnaires.map((q) => (
          <section key={q.componentId} className="grid gap-1 text-sm">
            <h3>
              {components?.find((value) => value.id === q.componentId)?.name ??
                q.componentId}
            </h3>
            <p className="break-all">
              Reviewed SHA-256 <code>{q.sha256}</code>
            </p>
            {q.administrationLanguages.map((entry) => (
              <p key={entry.language}>
                {entry.language}:{" "}
                {entry.translationComplete ?
                  "Wording complete"
                : "Wording incomplete"}
                , {entry.approved ? "approved" : "approval missing"}
              </p>
            ))}
          </section>
        ))}
        {report && (
          <PublicationFindings
            report={report}
            locate={(finding) => {
              if (!group || isPending) return;
              const params = { group, study: studyId };
              const destination = readinessDestination(finding.path);
              const component = report.questionnaires.find(
                (q) => q.componentId === finding.componentId,
              );
              const collection = /^collectionRequirements\[\d+\]$/.test(
                finding.path,
              );
              if (!destination && !component && !collection) return;
              const hash =
                destination?.hash ?? questionnaireTarget(finding, collection);
              const showFinding = async () => {
                onClose();
                if (destination)
                  await navigate({
                    to: "/$group/$study/configuration/general",
                    params,
                    search: { language: destination.language },
                    hash,
                  });
                else if (collection)
                  await navigate({
                    to: "/$group/$study/configuration/collection",
                    params,
                    hash,
                  });
                else if (component)
                  await navigate({
                    to: "/$group/$study/configuration/components/$componentType/$component",
                    params: {
                      ...params,
                      componentType: "questionnaire",
                      component: component.componentId,
                    },
                    hash,
                  });
                requestAnimationFrame(() => {
                  const element = document.getElementById(hash);
                  const editor =
                    hash === "questionnaire-resource" &&
                    element?.querySelector("textarea");
                  if (!editor) {
                    element?.focus();
                    return;
                  }
                  editor.focus();
                  const link = itemLinkId(editor.value, finding.path);
                  const range = link && linkIdRange(editor.value, link);
                  if (range) editor.setSelectionRange(...range);
                });
              };
              return {
                target: hash,
                label:
                  destination?.label ??
                  (collection ?
                    "Edit collection settings"
                  : "Edit questionnaire"),
                show: () => {
                  void showFinding();
                },
              };
            }}
            componentName={(id) =>
              components?.find((component) => component.id === id)?.name
            }
          />
        )}
        {needsReview && (
          <p role="alert" className="text-sm">
            The draft or validation is no longer current. Reload and review the
            draft, then validate it again before publishing.
          </p>
        )}
        {publishStudy.isError && !needsReview && (
          <p role="alert" className="text-sm">
            No publication confirmation was received. Retrying uses only this
            same candidate.
          </p>
        )}
        <DialogFooter>
          <Button
            variant="outline"
            size="sm"
            onClick={onClose}
            disabled={isPending}
          >
            Cancel
          </Button>
          {needsReview && (
            <Button size="sm" onClick={() => window.location.reload()}>
              Reload and review
            </Button>
          )}
          {!needsReview && candidate && (
            <Button
              size="sm"
              onClick={onPublish}
              disabled={isPending}
              isPending={publishStudy.isPending}
            >
              {publishStudy.isError ?
                "Retry publication"
              : `Publish v${candidate.publicationRevision}`}
            </Button>
          )}
          {!needsReview && !candidate && (
            <Button
              size="sm"
              onClick={onValidate}
              disabled={isPending}
              isPending={validateStudy.isPending}
            >
              {report ? "Validate again" : "Validate draft"}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

const StudyPublishButton = ({ studyId }: { studyId: string }) => {
  const [draftRevision, setDraftRevision] = useState<string>();
  const [isLoading, setIsLoading] = useState(false);
  const { data: published } = useQuery(
    publishedStudiesQueryOptions({ studyId }),
  );
  const latestRevision =
    published?.length ?
      Math.max(...published.map((entry) => entry.revision))
    : undefined;

  const open = async () => {
    setIsLoading(true);
    try {
      const { data } = await getStudiesByStudyId({
        path: { studyId },
        throwOnError: true,
      });
      setDraftRevision(data.draftRevision);
    } catch (error) {
      onMutationError("Error loading study for validation")(error);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <>
      <Button
        size="sm"
        onClick={open}
        isPending={isLoading}
        disabled={isLoading || draftRevision !== undefined}
      >
        Publish
      </Button>
      {draftRevision && (
        <PublicationDialog
          studyId={studyId}
          draftRevision={draftRevision}
          latestRevision={latestRevision}
          onClose={() => setDraftRevision(undefined)}
        />
      )}
    </>
  );
};

export const PublishButton = () => {
  const { study: studyId } = useParams({ strict: false });
  return studyId ?
      <StudyPublishButton key={studyId} studyId={studyId} />
    : null;
};

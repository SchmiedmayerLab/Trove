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
import { useParams } from "@tanstack/react-router";
import { Rocket } from "lucide-react";
import { useState } from "react";
import { getStudiesByStudyId } from "@/lib/api/generated/sdk.gen";
import type { StudyDraftValidation } from "@/lib/api/generated/types.gen";
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
import { FeaturedIconContainer } from "../../ui/FeaturedIconContainer";

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
  const validateStudy = useValidateStudyMutation();
  const publishStudy = usePublishStudyMutation();
  const [candidate, setCandidate] = useState<StudyDraftValidation>();
  const [needsReview, setNeedsReview] = useState(false);
  const isPending = validateStudy.isPending || publishStudy.isPending;
  const publicationStatus =
    latestRevision === undefined ?
      "No revision has been published."
    : `Current published revision: v${latestRevision}.`;

  const onValidate = () => {
    if (candidate || needsReview || isPending) return;
    validateStudy.mutate(validationRequest(studyId, draftRevision), {
      onSuccess: setCandidate,
      onError: (error) => setNeedsReview(publicationNeedsReview(error)),
    });
  };

  const onPublish = () => {
    if (!candidate || needsReview || isPending) return;
    // The server owns expiry checks and recognizes exact accepted retries,
    // including a lost reply whose candidate expired in the meantime.
    publishStudy.mutate(publicationRequest(studyId, candidate), {
      onSuccess: (data) => {
        toast.success(`Study published (v${data.revision})`);
        onClose();
      },
      onError: (error) => setNeedsReview(publicationNeedsReview(error)),
    });
  };

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !isPending) onClose();
      }}
    >
      <DialogContent className="max-w-lg">
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
            : `${publicationStatus} Only saved changes are included. Validation creates a candidate for review; it does not publish.`
            }
          </DialogDescription>
        </DialogHeader>
        <dl className="grid gap-1 text-sm">
          <dt className="font-medium">Draft revision</dt>
          <dd className="mb-2 font-mono text-xs break-all">
            {candidate?.draftRevision ?? draftRevision}
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
              <dt className="font-medium">
                Validated questionnaire localizations
              </dt>
              <dd className="mb-2">{candidate.questionnaires.length}</dd>
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
              Validate draft
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

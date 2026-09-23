//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { toast } from "@schmiedmayerlab/grove-design-system";
import {
  useMutation,
  useQueryClient,
  type UseMutationOptions,
} from "@tanstack/react-query";
import { useRef } from "react";
import { ApiError } from "../api/client";

/**
 * Operation IDs from the generated hey-api query key factories.
 * Add new IDs here as endpoints are used for cache invalidation.
 */
type OperationId =
  | "getGroups"
  | "getGroupsByGroupId"
  | "getGroupsByGroupIdStudies"
  | "getStudiesByStudyId"
  | "getStudiesByStudyIdPublished"
  | "getStudiesByStudyIdInvitationCodes"
  | "getStudiesByStudyIdComponents"
  | "getStudiesByStudyIdComponentsInformationalByComponentId"
  | "getStudiesByStudyIdComponentsQuestionnaireByComponentId"
  | "getStudiesByStudyIdComponentsHealthDataByComponentId"
  | "getStudiesByStudyIdComponentsByComponentIdSchedules";

const getErrorDescription = (error: unknown): string | undefined => {
  if (typeof error !== "object" || error === null) return undefined;
  if ("detail" in error && typeof error.detail === "string")
    return error.detail;
  if ("title" in error && typeof error.title === "string") return error.title;
  if ("message" in error && typeof error.message === "string")
    return error.message;
  return undefined;
};

/**
 * Creates an onError callback that shows a toast with the given message.
 * Handles both backend ProblemDetails ({ title, detail }) and standard Errors.
 */
export const onMutationError = (message: string) => (error: unknown) => {
  if (error instanceof ApiError && error.status === 412) {
    toast.error("The study draft has changed", {
      description:
        "Your changes were not saved. Copy any unsaved work, then reload and review the current draft before trying again.",
      duration: Infinity,
      action: {
        label: "Reload draft",
        onClick: () => window.location.reload(),
      },
    });
    return;
  }
  toast.error(message, {
    description: getErrorDescription(error),
    duration: 5000,
  });
};

/**
 * Hook that returns a callback to invalidate queries by their generated operation IDs.
 * Must be called at the top level of a custom hook (e.g. inside use*Mutation factories).
 */
export const useInvalidateFn = (...ids: OperationId[]) => {
  const queryClient = useQueryClient();
  return () =>
    Promise.all(
      ids.map((id) =>
        queryClient.invalidateQueries({ queryKey: [{ _id: id }] }),
      ),
    );
};

/**
 * Creates a mutation hook with standardized error toasting and query invalidation.
 */
export const createMutationHook =
  <TData, TError, TVariables, TContext>(
    mutation: () => UseMutationOptions<TData, TError, TVariables, TContext>,
    errorMessage: string,
    ...invalidationIds: OperationId[]
  ) =>
  () => {
    const conflictRef = useRef<ApiError | undefined>(undefined);
    const options = mutation();
    return useMutation({
      ...options,
      // A background read must not turn a rejected edit into a fresh write.
      // Reloading the editing session is the explicit conflict-resolution boundary.
      mutationFn: (variables, context) => {
        if (conflictRef.current) return Promise.reject(conflictRef.current);
        if (!options.mutationFn)
          return Promise.reject(new Error("Missing mutation implementation"));
        return options.mutationFn(variables, context);
      },
      retry: false,
      onSuccess: useInvalidateFn(...invalidationIds),
      onError: (error) => {
        if (error instanceof ApiError && error.status === 412)
          conflictRef.current = error;
        onMutationError(errorMessage)(error);
      },
    });
  };

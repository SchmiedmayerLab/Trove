//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { toast, useForm } from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { omit } from "es-toolkit";
import type { ComponentScheduleInput } from "@/lib/api/generated/types.gen";
import { zComponentSchedule } from "@/lib/api/generated/zod.gen";
import {
  componentListQueryOptions,
  scheduleListQueryOptions,
  useCreateScheduleMutation,
  useDeleteScheduleMutation,
  useUpdateScheduleMutation,
} from "@/lib/queries/component";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";
import { SCHEDULE_DEFAULTS } from "./scheduleTransforms";

export const useScheduleForm = () => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/components/$componentType/$component",
  });

  const componentPath = {
    studyId: params.study,
    componentId: params.component,
  };

  const { data: snapshot } = useQuery(scheduleListQueryOptions(componentPath));

  const { data: components } = useQuery(
    componentListQueryOptions({ studyId: params.study }),
  );

  const existingSchedule = snapshot?.value[0];
  const hasExistingSchedule = !!existingSchedule?.id;

  const form = useForm({
    formSchema: zComponentSchedule.omit({ id: true }),
    defaultValues: SCHEDULE_DEFAULTS,
  });

  const getSnapshot = useDraftFormSnapshot(
    snapshot,
    `${params.study}:${params.component}`,
    form.formState.isDirty,
    (loaded) =>
      form.reset(
        loaded.value[0] ? omit(loaded.value[0], ["id"]) : SCHEDULE_DEFAULTS,
      ),
  );

  const createSchedule = useCreateScheduleMutation();
  const updateSchedule = useUpdateScheduleMutation();
  const deleteSchedule = useDeleteScheduleMutation();

  const submitSchedule = (
    data: ComponentScheduleInput,
    onSuccess: () => void,
  ) => {
    const loaded = getSnapshot();
    const scheduleId = loaded.value[0]?.id;
    const headers = draftHeaders(loaded.draftRevision);

    if (scheduleId) {
      updateSchedule.mutate(
        { path: { ...componentPath, scheduleId }, headers, body: data },
        {
          onSuccess: () => {
            toast.success("Schedule updated");
            form.reset(data);
            onSuccess();
          },
        },
      );
    } else {
      createSchedule.mutate(
        { path: componentPath, headers, body: data },
        {
          onSuccess: () => {
            toast.success("Schedule created");
            form.reset(data);
            onSuccess();
          },
        },
      );
    }
  };

  const removeSchedule = (onSuccess: () => void) => {
    const loaded = getSnapshot();
    const scheduleId = loaded.value[0]?.id;
    if (!scheduleId) return;
    deleteSchedule.mutate(
      {
        path: { ...componentPath, scheduleId },
        headers: draftHeaders(loaded.draftRevision),
      },
      {
        onSuccess: () => {
          toast.success("Schedule deleted");
          form.reset(SCHEDULE_DEFAULTS);
          onSuccess();
        },
      },
    );
  };

  return {
    form,
    hasExistingSchedule,
    components: components ?? [],
    submitSchedule,
    removeSchedule,
  };
};

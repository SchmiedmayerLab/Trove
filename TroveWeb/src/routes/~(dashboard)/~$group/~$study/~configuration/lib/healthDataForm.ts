//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { z } from "zod";
import type {
  HealthDataComponentInput,
  HealthDataComponentResponse,
} from "@/lib/api/generated/types.gen";
import {
  zHealthDataComponentData,
  zSampleTypesCollection,
} from "@/lib/api/generated/zod.gen";

export const healthDataSchema = z.object({
  name: z.string().min(1, "Name is required"),
  sampleTypes: zSampleTypesCollection.min(
    1,
    "At least one sample type is required",
  ),
  historicalDataCollection:
    zHealthDataComponentData.shape.historicalDataCollection,
});

export const defaultValues: z.infer<typeof healthDataSchema> = {
  name: "Health Data",
  sampleTypes: [],
};

export const transformResponseToForm = (
  response: HealthDataComponentResponse,
) => ({
  name: response.name,
  sampleTypes: response.data.sampleTypes,
  historicalDataCollection: response.data.historicalDataCollection,
});

export const transformHealthDataFormToInput = (
  formData: z.infer<typeof healthDataSchema>,
): HealthDataComponentInput => ({
  name: formData.name,
  data: {
    sampleTypes: formData.sampleTypes,
    historicalDataCollection: formData.historicalDataCollection,
  },
});

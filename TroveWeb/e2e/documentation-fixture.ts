// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { z } from "zod";
import type {
  StudyCreateInput,
  StudyPatchInput,
  ParticipantProfileInput,
} from "../src/lib/api/generated/types.gen";
import {
  zGroupResponse,
  zStudyListItem,
  zStudyResponse,
  zParticipantProfile,
  // Node's standalone fixture entry point needs an explicit TypeScript extension.
  // eslint-disable-next-line import-x/extensions
} from "../src/lib/api/generated/zod.gen.ts";

export const studyTitle = "Daily Activity Study";
export const consentTitle = "Daily Activity Study — Consent";
export const consent = `## About this study

We are exploring everyday movement and wellbeing. Participation is **voluntary**. You may leave the study at any time.

## Your data

With your permission, this study collects heart rate measurements from Apple Health. You control Health access on your device.

This is a synthetic demonstration, not an active research study.

<toggle id="agree" expected-value="true">I have reviewed this information and agree to participate.</toggle>

<signature id="participant"/>`;

// Deliberately loopback-only endpoints and fixture identities. Never accept a
// production URL, delete an existing study, or log an access token.
export const documentationPort = z.coerce
  .number()
  .int()
  .min(1024)
  .max(65535)
  .parse(process.env.TROVE_DOCUMENTATION_API_PORT ?? 8080);
const api = `http://127.0.0.1:${documentationPort}/api/v0`;
const tokenURL =
  "http://localhost:8180/realms/trove/protocol/openid-connect/token";
const tokenFor = async (username: string): Promise<string> => {
  const password = process.env.KEYCLOAK_DEV_PASSWORD;
  if (!password) throw new Error("KEYCLOAK_DEV_PASSWORD is required");
  const response = await fetch(tokenURL, {
    method: "POST",
    redirect: "error",
    body: new URLSearchParams({
      grant_type: "password",
      client_id: "trove-dev-cli",
      username,
      password,
    }),
  });
  if (!response.ok)
    throw new Error(`Fixture authentication failed (${response.status})`);
  return z
    .object({ access_token: z.string().min(1) })
    .parse(await response.json()).access_token;
};

const request = async <T>(
  token: string,
  path: string,
  schema: z.ZodType<T>,
  method = "GET",
  body?: unknown,
  revision?: string,
): Promise<T> => {
  const response = await fetch(`${api}${path}`, {
    method,
    redirect: "error",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(revision ? { "If-Match": `"${revision}"` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok)
    throw new Error(`Fixture ${method} ${path} failed (${response.status})`);
  return schema.parse(await response.json());
};

export const seedDocumentationStudy = async () => {
  if (process.env.TROVE_DOCUMENTATION_FIXTURE !== "disposable") {
    throw new Error(
      "Set TROVE_DOCUMENTATION_FIXTURE=disposable only for a fresh local screenshot stack",
    );
  }
  const researcher = await tokenFor("leland@example.com");
  const groups = await request(researcher, "/groups", z.array(zGroupResponse));
  const group = groups.find((item) => item.name === "Schmiedmayer Lab");
  if (!group) throw new Error("The development realm group is missing");
  const studies = await request(
    researcher,
    `/groups/${group.id}/studies`,
    z.array(zStudyListItem),
  );
  if (studies.length !== 0)
    throw new Error("Expected an empty disposable group; no data was changed");
  const participant = await tokenFor("alice@example.com");
  const profile: ParticipantProfileInput = {
    firstName: "Alice",
    lastName: "Participant",
    gender: "preferNotToState",
    dateOfBirth: "1990-01-01",
    region: "US",
    language: "en-US",
    phoneNumber: "+16505550123",
  };
  await request(
    participant,
    "/participant/profile",
    zParticipantProfile,
    "POST",
    profile,
  );
  const create: StudyCreateInput = { title: studyTitle, icon: "heart" };
  const created = await request(
    researcher,
    `/groups/${group.id}/studies`,
    zStudyResponse,
    "POST",
    create,
  );
  const patch: StudyPatchInput = {
    details: {
      "en-US": {
        title: studyTitle,
        shortTitle: "Daily Activity",
        explanationText:
          "Help us understand how daily activity supports wellbeing. Review the study information, provide consent, and choose whether to share heart rate data from your device.\n\nThis is a synthetic demonstration, not an active research study.",
        shortExplanationText: "Exploring everyday movement and wellbeing.",
      },
    },
    participationCriterion: {
      type: "all",
      criteria: [{ type: "ageAtLeast", age: 18 }],
    },
    consent: { "en-US": { title: consentTitle, content: consent } },
    collectionRequirements: [
      {
        profile:
          "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate",
        sourceKind: "participant-app",
      },
    ],
  };
  const study = await request(
    researcher,
    `/studies/${created.id}`,
    zStudyResponse,
    "PATCH",
    patch,
    created.draftRevision,
  );
  return { groupId: group.id, studyId: study.id };
};

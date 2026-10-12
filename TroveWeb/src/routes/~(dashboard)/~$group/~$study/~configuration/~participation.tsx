// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { createFileRoute, redirect } from "@tanstack/react-router";

export const Route = createFileRoute(
  "/(dashboard)/$group/$study/configuration/participation",
)({
  beforeLoad: ({ params }) => {
    throw redirect({
      to: "/$group/$study/configuration/enrollment",
      params,
      replace: true,
    });
  },
});

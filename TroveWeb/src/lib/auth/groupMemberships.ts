// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

export type GroupRole = "admin" | "researcher";

export const parseGroupMemberships = (
  groups: unknown,
): Record<string, GroupRole> => {
  if (!Array.isArray(groups)) return {};
  const memberships = new Map<string, GroupRole>();
  for (const path of groups) {
    if (typeof path !== "string" || !path.startsWith("/")) continue;
    const segments = path.slice(1).split("/");
    if (segments.length !== 2) continue;
    const [groupName, role] = segments;
    if (!groupName || (role !== "admin" && role !== "researcher")) continue;
    if (role === "admin" || !memberships.has(groupName)) {
      memberships.set(groupName, role);
    }
  }
  return Object.fromEntries(memberships);
};

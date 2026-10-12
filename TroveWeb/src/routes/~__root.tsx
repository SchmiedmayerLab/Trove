//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { GroveProvider, Toaster } from "@schmiedmayerlab/grove-design-system";
import type { QueryClient } from "@tanstack/react-query";
import {
  createRootRouteWithContext,
  HeadContent,
  Link,
  Outlet,
  type ErrorComponentProps,
} from "@tanstack/react-router";
import type { ComponentProps } from "react";

export interface RouterAppContext {
  queryClient: QueryClient;
}

const routerProps: ComponentProps<typeof GroveProvider>["router"] = {
  Link: ({ href, ...props }) => <Link to={href} {...props} />,
};

const RootComponent = () => {
  return (
    <>
      <HeadContent />
      <GroveProvider router={routerProps} colorScheme="system">
        {/* The colour-scheme tokens live on the provider's element, which sits inside body,
            so the app paints its own background rather than inheriting body's light default. */}
        <div className="bg-bg text-text grid min-h-svh grid-rows-[1fr]">
          <Outlet />
        </div>
        <Toaster position="top-center" />
      </GroveProvider>
    </>
  );
};

/**
 * Minimal standalone error component for the root route.
 * Uses inline styles instead of design system components because this catches
 * errors that occur before GroveProvider mounts.
 */
const RootErrorComponent = ({ error, reset }: ErrorComponentProps) => (
  <div
    style={{
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      height: "100svh",
      fontFamily: "system-ui, sans-serif",
    }}
  >
    <div style={{ textAlign: "center", maxWidth: "24rem" }}>
      <h1
        style={{
          fontSize: "1.25rem",
          fontWeight: 600,
          marginBottom: "0.5rem",
        }}
      >
        Something went wrong
      </h1>
      <p style={{ color: "#666", marginBottom: "1.5rem" }}>{error.message}</p>
      <button
        type="button"
        onClick={reset}
        style={{
          padding: "0.5rem 1rem",
          borderRadius: "0.375rem",
          border: "1px solid #d1d5db",
          background: "white",
          cursor: "pointer",
        }}
      >
        Try again
      </button>
    </div>
  </div>
);

export const Route = createRootRouteWithContext<RouterAppContext>()({
  component: RootComponent,
  errorComponent: RootErrorComponent,
  head: () => ({
    meta: [
      { title: "Trove" },
      {
        name: "description",
        content:
          "Trove is a web application that allows users to create and manage studies.",
      },
    ],
    links: [{ rel: "icon", href: "favicon.ico" }],
  }),
});

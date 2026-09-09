//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  type ReactNode,
  createContext,
  use,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { getKeycloak, initKeycloak } from "./keycloak";
import { bindKeycloakSession, type AuthUser } from "./keycloakSession";
import { queryClient } from "../queryClient";

export type { GroupRole } from "./groupMemberships";
export type { AuthUser } from "./keycloakSession";

interface AuthContextValue {
  isAuthenticated: boolean;
  isInitialized: boolean;
  user: AuthUser | null;
  login: () => Promise<void>;
  logout: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

type AuthState =
  | { status: "loading" | "ended" | "failed" }
  | { status: "ready"; user: AuthUser | null };

const signInURL = () =>
  `${window.location.origin}${import.meta.env.BASE_URL}sign-in`;

export const AuthProvider = ({ children }: { children: ReactNode }) => {
  const [state, setState] = useState<AuthState>({ status: "loading" });
  const sessionRef = useRef<ReturnType<typeof bindKeycloakSession> | null>(
    null,
  );

  useEffect(() => {
    let mounted = true;
    let initialized = false;
    let ended = false;
    let user: AuthUser | null = null;
    const lifecycle = bindKeycloakSession(getKeycloak(), {
      clearCache: () => queryClient.clear(),
      onUser: (current) => {
        user = current;
        if (mounted && initialized && !ended)
          setState({ status: "ready", user });
      },
      onEnded: () => {
        ended = true;
        if (mounted) setState({ status: "ended" });
      },
    });
    sessionRef.current = lifecycle;
    const init = async () => {
      try {
        await initKeycloak();
        if (!mounted) return;
        lifecycle.synchronize();
        initialized = true;
        if (!ended) setState({ status: "ready", user });
      } catch {
        if (!mounted) return;
        lifecycle.end();
        setState({ status: "failed" });
      }
    };
    void init();
    return () => {
      mounted = false;
      lifecycle.dispose();
      if (sessionRef.current === lifecycle) sessionRef.current = null;
    };
  }, []);

  const login = useCallback(async () => {
    await getKeycloak().login();
  }, []);

  const logout = useCallback(async () => {
    try {
      // Let Keycloak capture the ID-token hint before local credentials are cleared.
      const pending = getKeycloak().logout({
        redirectUri: signInURL(),
        logoutMethod: "POST",
      });
      sessionRef.current?.end();
      await pending;
    } catch {
      sessionRef.current?.end();
      setState({ status: "failed" });
    }
  }, []);

  const user = state.status === "ready" ? state.user : null;
  const isInitialized = state.status === "ready";
  const isAuthenticated = user !== null;

  const value = useMemo(
    () => ({ isAuthenticated, isInitialized, user, login, logout }),
    [isAuthenticated, isInitialized, user, login, logout],
  );

  if (state.status === "failed" || state.status === "ended") {
    return (
      <div className="flex-center size-full flex-col gap-4">
        <p>
          {state.status === "failed" ?
            "Unable to connect to the authentication service."
          : "Your session ended or its permissions changed."}
        </p>
        <button
          type="button"
          onClick={() => window.location.replace(signInURL())}
        >
          Continue to sign in
        </button>
      </div>
    );
  }

  // Block rendering until Keycloak has initialized so that synchronous
  // checks like `keycloak.authenticated` in route guards are accurate.
  if (!isInitialized) return null;

  return <AuthContext value={value}>{children}</AuthContext>;
};

/**
 * Hook to access the Keycloak auth context.
 */
export const useAuth = (): AuthContextValue => {
  const context = use(AuthContext);
  if (!context) {
    throw new Error("useAuth must be used within an AuthProvider");
  }
  return context;
};

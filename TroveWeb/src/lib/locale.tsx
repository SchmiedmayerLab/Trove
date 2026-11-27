//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  type Dispatch,
  type ReactNode,
  type SetStateAction,
  createContext,
  use,
  useEffect,
  useMemo,
  useState,
} from "react";

interface LocaleContextValue {
  locale: string;
  setLocale: Dispatch<SetStateAction<string>>;
}

const LocaleContext = createContext<LocaleContextValue | null>(null);

const storageKey = (studyId: string) => `locale:${studyId}`;

interface LocaleProviderProps {
  studyId: string;
  supportedLocales: string[];
  children: ReactNode;
}

export const LocaleProvider = ({
  studyId,
  supportedLocales,
  children,
}: LocaleProviderProps) => {
  const localStorageKey = storageKey(studyId);
  const fallback = supportedLocales[0] ?? "en-US";
  const [locale, setLocale] = useState(() => {
    const storedLocale = localStorage.getItem(localStorageKey);
    return storedLocale && supportedLocales.includes(storedLocale) ?
        storedLocale
      : fallback;
  });

  // A choice the study's locales do not contain, such as a locale that was just
  // removed or one added before the refreshed study arrives, reads as the fallback.
  const activeLocale = supportedLocales.includes(locale) ? locale : fallback;

  useEffect(() => {
    localStorage.setItem(localStorageKey, activeLocale);
  }, [localStorageKey, activeLocale]);

  const contextValue = useMemo(
    () => ({ locale: activeLocale, setLocale }),
    [activeLocale],
  );

  return <LocaleContext value={contextValue}>{children}</LocaleContext>;
};

export const useLocale = (): LocaleContextValue => {
  const context = use(LocaleContext);
  if (!context) {
    throw new Error("useLocale must be used within a LocaleProvider");
  }
  return context;
};

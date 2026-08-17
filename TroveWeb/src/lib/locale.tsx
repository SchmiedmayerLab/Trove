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

  useEffect(() => {
    if (!supportedLocales.includes(locale)) {
      // Falls back when the study's locale list changes underneath a stored choice.
      // eslint-disable-next-line @eslint-react/set-state-in-effect -- reconciling with a changed prop
      setLocale(fallback);
    }
  }, [supportedLocales, locale, fallback]);

  useEffect(() => {
    localStorage.setItem(localStorageKey, locale);
  }, [localStorageKey, locale]);

  const contextValue = useMemo(() => ({ locale, setLocale }), [locale]);

  return <LocaleContext value={contextValue}>{children}</LocaleContext>;
};

export const useLocale = (): LocaleContextValue => {
  const context = use(LocaleContext);
  if (!context) {
    throw new Error("useLocale must be used within a LocaleProvider");
  }
  return context;
};

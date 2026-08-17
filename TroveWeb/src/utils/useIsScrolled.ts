//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { useEffect, useRef, useState } from "react";

export const useIsScrolled = (threshold = 0) => {
  const [isScrolled, setIsScrolled] = useState(false);
  const rafIdRef = useRef<number>(undefined);

  useEffect(() => {
    const handleScroll = () => {
      if (rafIdRef.current) {
        cancelAnimationFrame(rafIdRef.current);
      }
      rafIdRef.current = requestAnimationFrame(() => {
        setIsScrolled(window.scrollY > threshold);
        rafIdRef.current = undefined;
      });
    };

    // eslint-disable-next-line @eslint-react/set-state-in-effect -- seeds from window.scrollY, which is only readable after mount
    setIsScrolled(window.scrollY > threshold);
    window.addEventListener("scroll", handleScroll, { passive: true });

    return () => {
      window.removeEventListener("scroll", handleScroll);
      if (rafIdRef.current) {
        cancelAnimationFrame(rafIdRef.current);
      }
    };
  }, [threshold]);

  return isScrolled;
};

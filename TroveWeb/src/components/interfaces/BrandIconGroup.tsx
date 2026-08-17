//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { FeaturedIconContainer } from "../ui/FeaturedIconContainer";

export const BrandIconGroup = () => {
  return (
    <FeaturedIconContainer>
      <div className="flex-center bg-brand-500 text-brand-50 size-full inset-shadow-sm">
        <div className="scale-y-110 font-serif text-2xl font-semibold text-shadow-xs">
          T
        </div>
      </div>
    </FeaturedIconContainer>
  );
};

//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { Button } from "@schmiedmayerlab/grove-design-system";
import { Check, CircleAlert } from "lucide-react";
import { type ComponentProps, type ReactNode } from "react";
import { cn } from "@/utils/cn";
import { useTimedFlag } from "@/utils/useTimedFlag";

interface SaveButtonProps extends Omit<
  ComponentProps<typeof Button>,
  "children"
> {
  isSuccess?: boolean;
  successTimeout?: number;
  isError?: boolean;
  errorTimeout?: number;
}

export const SaveButton = ({
  className,
  isPending,
  disabled,
  isSuccess,
  successTimeout = 2000,
  isError,
  errorTimeout = 5000,
  ...props
}: SaveButtonProps) => {
  const localIsSuccess = useTimedFlag(isSuccess, successTimeout);
  const localIsError = useTimedFlag(isError, errorTimeout);

  let label: ReactNode = "Save";
  if (localIsSuccess) {
    label = (
      <div className="flex items-center gap-2">
        <span>Saved</span>
        <Check className="top-px size-4" strokeWidth={2.5} />
      </div>
    );
  } else if (localIsError) {
    label = (
      <div className="flex w-full items-center gap-2">
        <CircleAlert className="relative top-[0.5px] size-4.5" />
        Error
      </div>
    );
  }

  return (
    <Button
      disabled={disabled ?? isPending}
      isPending={isPending}
      className={cn(
        "w-20 border-2 border-transparent !transition-all",
        localIsSuccess &&
          "border-fill-success text-text-success-on-fill w-28 shadow-[inset_0_0_16px_--alpha(var(--color-fill-success)_/_50%)]",
        localIsError &&
          "border-fill-critical !bg-fill-critical text-text-critical-on-fill w-28",
        className,
      )}
      {...props}
    >
      {label}
    </Button>
  );
};

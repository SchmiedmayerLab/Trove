//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { Field, RadioGroup } from "@schmiedmayerlab/grove-design-system";
import { Card, CardHeader } from "@/components/ui/Card";
import type { EnrollmentForm as EnrollmentFormType } from "../lib/useEnrollmentForm";

interface RadioOptionProps {
  title: string;
  description: string;
}

const RadioOption = ({ title, description }: RadioOptionProps) => (
  <div className="flex flex-col gap-1">
    <p className="font-medium">{title}</p>
    <p className="text-text-tertiary text-sm">{description}</p>
  </div>
);

interface EnrollmentFormProps {
  form: EnrollmentFormType;
  onSubmit: () => void;
}

export const EnrollmentForm = ({ form, onSubmit }: EnrollmentFormProps) => {
  return (
    <form onSubmit={onSubmit} className="flex flex-col gap-8">
      <Card>
        <CardHeader
          title="Enrollment mode"
          description="Controls how participants gain access to your study."
        />
        <div className="p-(--card-padding)">
          <Field
            control={form.control}
            name="enrollmentConditions"
            render={({ field }) => (
              <RadioGroup
                className="gap-y-6 [&_button]:-mt-px [&>label]:items-start"
                options={[
                  {
                    value: "none",
                    label: (
                      <RadioOption
                        title="Open to anyone"
                        description="Any eligible participant can discover and enroll in this study."
                      />
                    ),
                  },
                  {
                    value: "requiresInvitationCode",
                    label: (
                      <RadioOption
                        title="Requires invitation code"
                        description="Only participants with a valid invitation code can enroll. Manage codes below."
                      />
                    ),
                  },
                ]}
                {...field}
              />
            )}
          />
        </div>
      </Card>
      <Card>
        <CardHeader
          title="Visibility"
          description="Whether the published study appears in the public study marketplace."
        />
        <div className="p-(--card-padding)">
          <Field
            control={form.control}
            name="visibility"
            render={({ field }) => (
              <RadioGroup
                className="gap-y-6 [&_button]:-mt-px [&>label]:items-start"
                options={[
                  {
                    value: "public",
                    label: (
                      <RadioOption
                        title="Public"
                        description="Listed in the marketplace so anyone browsing can find it."
                      />
                    ),
                  },
                  {
                    value: "unlisted",
                    label: (
                      <RadioOption
                        title="Unlisted"
                        description="Hidden from the marketplace. Only reachable by participants who already have a direct link or invitation code."
                      />
                    ),
                  },
                ]}
                {...field}
              />
            )}
          />
        </div>
      </Card>
    </form>
  );
};

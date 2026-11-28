// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { createFileRoute } from "@tanstack/react-router";
import { useHotkeys } from "react-hotkeys-hook";
import { NavigationBlocker } from "@/components/interfaces/NavigationBlocker";
import { RouteHeader, RouteHeaderBackLink } from "@/components/ui/RouteHeader";
import { SaveButton } from "@/components/ui/SaveButton";
import { useUpdateStudyMutation } from "@/lib/queries/study";
import { CollectionForm } from "./components/CollectionForm";
import { useCollectionForm } from "./lib/useCollectionForm";

const CollectionRoute = () => {
  const { study } = Route.useParams();
  const {
    form,
    query,
    capabilities,
    providers,
    measurements,
    isSupported,
    getDraftHeaders,
  } = useCollectionForm(study);
  const updateStudy = useUpdateStudyMutation();
  const loadFailed = query.isError || capabilities.isError || providers.isError;
  const disabled = loadFailed || !isSupported || updateStudy.isPending;
  const handleSubmit = form.handleSubmit((data) => {
    if (disabled) return;
    updateStudy.mutate(
      { path: { studyId: study }, headers: getDraftHeaders(), body: data },
      {
        onSuccess: (updated) =>
          form.reset({
            collectionRequirements: updated.collectionRequirements,
            receivesDeviceUnitIdentifiers:
              updated.receivesDeviceUnitIdentifiers,
          }),
      },
    );
  });
  useHotkeys(
    "meta+enter",
    () => void handleSubmit(),
    { enableOnFormTags: ["input"] },
    [handleSubmit],
  );
  let content = (
    <CollectionForm
      measurements={measurements}
      form={form}
      onSubmit={handleSubmit}
      disabled={disabled}
    />
  );
  if (query.isPending || capabilities.isPending || providers.isPending)
    content = <p role="status">Loading collection settings…</p>;
  else if (loadFailed)
    content = (
      <p role="alert">
        Collection settings could not be loaded. Reload to try again.
      </p>
    );
  else if (!isSupported)
    content = (
      <p role="alert">
        This study has collection settings this editor does not support. They
        have not been changed.
      </p>
    );
  return (
    <div>
      <RouteHeader
        title="Health collection"
        description="Configure the measurement scope participants will be asked to accept."
        accessoryLeft={<RouteHeaderBackLink />}
        accessoryRight={
          <SaveButton
            size="sm"
            disabled={disabled}
            onClick={handleSubmit}
            isPending={updateStudy.isPending}
            isSuccess={updateStudy.isSuccess}
            isError={updateStudy.isError}
          />
        }
      />
      <div
        id="collection-edit"
        tabIndex={-1}
        className="flex max-w-7xl flex-col gap-8 p-6"
      >
        {content}
      </div>
      <NavigationBlocker shouldBlock={form.formState.isDirty} />
    </div>
  );
};

export const Route = createFileRoute(
  "/(dashboard)/$group/$study/configuration/collection",
)({ component: CollectionRoute });

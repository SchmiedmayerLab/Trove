// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

// Follow the site's explicit appearance choice as well as the system preference.
// Without JavaScript, the original picture media queries remain the fallback.
const darkScreenshots = document.querySelectorAll(
  'picture > source[media="(prefers-color-scheme: dark)"]',
);
function updateScreenshots() {
  const dark = document.body.dataset.mdColorScheme === "slate";
  for (const source of darkScreenshots) {
    source.media = dark ? "all" : "not all";
  }
}
new MutationObserver(updateScreenshots).observe(document.body, {
  attributes: true,
  attributeFilter: ["data-md-color-scheme"],
});
updateScreenshots();

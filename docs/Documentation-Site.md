<!--
SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
SPDX-License-Identifier: MIT
-->

# Documentation Site

The website renders the Markdown in `docs/` with Zensical. Edit those files directly; there is no separate copy of the design
documentation. `docs/README.md` is the landing page, `zensical.toml` defines the
navigation, and `docs/stylesheets/trove.css` adds the homepage layout.

## Build and Preview

From the repository root, with Python 3.13:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r documentation/requirements.txt
.venv/bin/zensical build --clean --strict
.venv/bin/python documentation/check_site.py
.venv/bin/zensical serve --dev-addr 127.0.0.1:8000
```

Open the local URL printed by Zensical. Check the homepage, tour and a design page
in both appearances and at a narrow mobile width. Confirm navigation, search,
image loading and keyboard focus. The site uses system fonts and no analytics.

The build fails on invalid documentation links. The additional check verifies
local HTML links, anchors and image paths in the generated site, including raw
HTML images that Markdown validation may not cover. Repository files outside
`docs/` should use full GitHub URLs; those files are not part of the static site.

## Publishing

The Documentation workflow builds pull requests without deploying them. After
merge to `main`, it uploads the exact checked `site/` output and deploys through
the `github-pages` environment. GitHub Pages must use **GitHub Actions** as its
source in the repository settings. The site is served at
`https://schmiedmayerlab.github.io/Trove/` once the first deployment completes.

Only the deployment job receives Pages write and identity-token permissions.
This publishes public documentation, not application images or study services;
it does not bypass the independent candidate-image approval boundary.

## Maintaining Content

- Document working interfaces in the [tour](Platform-Tour.md), design decisions
  in the design pages, and delivery scope and status in
  [GitHub milestones](https://github.com/SchmiedmayerLab/Trove/milestones) and issues.
  Do not copy milestone checklists or progress reports into the site.
- Describe supported behavior and identify planned capabilities explicitly.
  Keep API instructions aligned with the documented revision.
- Keep the component diagrams in the root README and architecture page identical.
- Use only synthetic study and participant data. Follow the
  [capture instructions](images/README.md) when refreshing screenshots.
- Keep light and dark screenshots together. Do not replace them with fabricated UI.
- Update `documentation/requirements.in`, then regenerate the complete hashed
  dependency set with `uv pip compile --python-version 3.13 --generate-hashes
  documentation/requirements.in -o documentation/requirements.txt`. Run the shared
  dependency vulnerability check before publishing a dependency update.

The repository remains the source of truth. The generated `site/` directory is
ignored and should not be committed.

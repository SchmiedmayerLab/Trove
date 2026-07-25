<!--

This source file is part of the StudyPlatform open-source project

SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# StudyPlatform iOS

[![CI](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/ios.yml/badge.svg)](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/ios.yml)

> **StudyPlatform** is an open-source, end-to-end platform for running research studies: researchers author studies in the [web portal](../web), those definitions configure the participant iOS app, and a [Vapor server](../server) with a shared [OpenAPI contract](../api) ties it together, deployed via [GitOps infrastructure](../infrastructure). See the [monorepo overview](../README.md) for the full picture.

**This package** is the participant-facing iOS app. Built on the [Stanford Spezi](https://github.com/StanfordSpezi) ecosystem, it fetches study definitions authored in the web portal and renders them as informational screens, questionnaires, and HealthKit data-collection flows. It consumes the generated `StudyPlatformAPIClient` from the shared [`api/`](../api) package.

## Getting Started

Open `StudyPlatform.xcodeproj` in Xcode and run the `StudyPlatform` scheme. Swift package dependencies resolve on first build.

## License

This project is licensed under the MIT License. See [LICENSE.md](../LICENSE.md) for details, and [CONTRIBUTORS.md](../CONTRIBUTORS.md) for the list of contributors.

This package is based on the [`SpeziStudyPlatform-iOS`](https://github.com/StanfordSpezi/SpeziStudyPlatform-iOS) repository, published under the MIT License.


## Our Research

For more information, visit the [Schmiedmayer Lab GitHub organization](https://github.com/SchmiedmayerLab).

![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-light.png#gh-light-mode-only)
![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-dark.png#gh-dark-mode-only)

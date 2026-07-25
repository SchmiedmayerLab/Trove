<!--

This source file is part of the StudyPlatform open-source project

SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# StudyPlatform API

[![CI](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/api.yml/badge.svg)](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/api.yml)

> **StudyPlatform** is an open-source, end-to-end platform for running research studies: researchers author studies in the [web portal](../web), those definitions configure the participant [iOS app](../ios), and a [Vapor server](../server) with a shared OpenAPI contract ties it together, deployed via [GitOps infrastructure](../infrastructure). See the [monorepo overview](../README.md) for the full picture.

**This package** is the shared OpenAPI contract (`openapi.yaml`) and the Swift libraries generated from it: `StudyPlatformAPITypes`, `StudyPlatformAPIClient`, and `StudyPlatformAPIServer`. It is the single source of truth consumed by the server, the iOS app, and (via a generated TypeScript client) the web portal.

## Code Generation

The generated `Types.swift`, `Client.swift`, and `Server.swift` are committed to the repo. To regenerate them after updating `openapi.yaml`, run:

```bash
swift run StudyPlatformAPIGenerator
```

You can also generate specific targets only:

```bash
swift run StudyPlatformAPIGenerator --types --client
```

## Installation

The package can be added to your Xcode project or Swift package using the [Swift Package Manager](https://github.com/apple/swift-package-manager).

**Xcode:** For an Xcode project, follow the instructions on [adding package dependencies to your app](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app).

**Swift Package:** You can follow the [Swift Package Manager documentation about defining dependencies](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/) to add this package as a dependency.

## License

This project is licensed under the MIT License. See [LICENSE.md](../LICENSE.md) for details, and [CONTRIBUTORS.md](../CONTRIBUTORS.md) for the list of contributors.

This package is based on the [`SpeziStudyPlatform-API`](https://github.com/StanfordSpezi/SpeziStudyPlatform-API) repository, published under the MIT License.


## Our Research

For more information, visit the [Schmiedmayer Lab GitHub organization](https://github.com/SchmiedmayerLab).

![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-light.png#gh-light-mode-only)
![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-dark.png#gh-dark-mode-only)

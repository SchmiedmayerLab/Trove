<!--

This source file is part of the StudyPlatform open-source project

SPDX-FileCopyrightText: 2025 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# StudyPlatform Web

[![Build and Test](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/web.yml/badge.svg)](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/web.yml)

> **StudyPlatform** is an open-source, end-to-end platform for running research studies: researchers author studies in the web portal, those definitions configure the participant [iOS app](../ios), and a [Vapor server](../server) with a shared [OpenAPI contract](../api) ties it together, deployed via [GitOps infrastructure](../infrastructure). See the [monorepo overview](../README.md) for the full picture.

**This package** is the researcher-facing frontend. Users define studies by specifying metadata, participant criteria, and app components; those study definitions then configure the companion mobile apps that participants use.

<img width="1618" height="939" alt="StudyPlatform Web interface overview" src="./images/hero.webp" />

## Getting Started

To get started with the project, follow these steps:

1. Clone the repository:
   ```bash
   git clone https://github.com/SchmiedmayerLab/StudyPlatform.git
   cd StudyPlatform/web
   ```
2. Install the dependencies:
   ```bash
   npm install
   ```
3. Create a `.env` file:
   ```bash
   cp .env.example .env
   ```
4. Start the supporting services (API server, Keycloak) using the Docker Compose setup in [`infrastructure/docker`](../infrastructure/docker).
5. Start the development server:
   ```bash
   npm run dev
   ```

## API Documentation

The API is defined using OpenAPI. The specification lives in the shared [`api/`](../api) package at the monorepo root (`../api/openapi.yaml`), and the TypeScript client is regenerated with `npm run generate:api`.

## License

This project is licensed under the MIT License. See [LICENSE.md](../LICENSE.md) for details, and [CONTRIBUTORS.md](../CONTRIBUTORS.md) for the list of contributors.

This package is based on the [`SpeziStudyPlatform-Web`](https://github.com/StanfordSpezi/SpeziStudyPlatform-Web) repository, published under the MIT License.


## Our Research

For more information, visit the [Schmiedmayer Lab GitHub organization](https://github.com/SchmiedmayerLab).

![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-light.png#gh-light-mode-only)
![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-dark.png#gh-dark-mode-only)

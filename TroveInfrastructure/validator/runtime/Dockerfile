# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

# Networked runtime base for the offline validator build. Keep these pins equal to
# runtimeImages in ../manifest.json; the validator identity changes with them.
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:2c12da5496e21e99003b3db3b9246f025e53d533c4df334205391260f1e8f85b
RUN apk add --no-cache \
        openjdk-21-default-jvm=21.0.13.1-r0 \
        openjdk-21-jre=21.0.13.1-r0 \
        python-3.15=3.15.2_git20261113-r0

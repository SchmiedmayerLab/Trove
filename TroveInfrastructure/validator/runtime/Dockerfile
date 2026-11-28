# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

# Networked runtime base for the offline validator build. Keep these pins equal to
# runtimeImages in ../manifest.json; the validator identity changes with them.
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:5172a213d2bba8b1c9ca11957db65562b52b0f9844583a0347318ea5fd8e3aa5
RUN apk add --no-cache \
        openjdk-21-default-jvm=21.0.13.1-r1 \
        openjdk-21-jre=21.0.13.1-r1 \
        python-3.15=3.15.2_git20261127-r0

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

# Networked runtime base for the offline validator build. Keep these pins equal to
# runtimeImages in ../manifest.json; the validator identity changes with them.
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:be019c1c74fe69204a42c4e10bc4d886a49bf5403ffa74374ef7baa408fc9a26
RUN apk add --no-cache \
        openjdk-21-default-jvm=21.0.13.1-r1 \
        openjdk-21-jre=21.0.13.1-r1 \
        python-3.15=3.15.2_git20261127-r0

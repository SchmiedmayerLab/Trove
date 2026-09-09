#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

# ================================
# Build image
# ================================
FROM swift:6.3.0-noble@sha256:9949aac363e63fe96c44d08e3d00878fecbad7f50cb5450067c702012d6990e4 AS build
ARG TARGETARCH

# Install OS updates
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y libjemalloc-dev

# Set up a build area
WORKDIR /build

# This Dockerfile is built from the monorepo root as the context.
# Copy the inlined API package first; the server references it via `../TroveAPI`.
COPY TroveAPI ./TroveAPI

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
COPY TroveServer/Package.* ./TroveServer/
WORKDIR /build/TroveServer
RUN --mount=type=cache,id=trove-server-${TARGETARCH},target=/build/TroveServer/.build,sharing=locked \
    swift package resolve --force-resolved-versions

# Copy the server sources into the build area
COPY TroveServer ./

RUN mkdir /staging

# Build the application, with optimizations, with static linking, and using jemalloc
# N.B.: The static version of jemalloc is incompatible with the static Swift runtime.
RUN --mount=type=cache,id=trove-server-${TARGETARCH},target=/build/TroveServer/.build,sharing=locked \
    swift build -c release --force-resolved-versions --jobs 4 \
        --product TroveServer \
        --static-swift-stdlib \
        -Xlinker -ljemalloc && \
    # Copy main executable to staging area
    cp "$(swift build -c release --show-bin-path)/TroveServer" /staging && \
    # Copy resources bundled by SPM to staging area
    find -L "$(swift build -c release --show-bin-path)" -regex '.*\.resources$' -exec cp -Ra {} /staging \;


# Switch to the staging area
WORKDIR /staging

# Copy static swift backtracer binary to staging area
RUN cp "/usr/libexec/swift/linux/swift-backtrace-static" ./

# Copy any resources from the public directory and views directory if the directories exist
# Ensure that by default, neither the directory nor any of its contents are writable.
RUN if [ -d /build/TroveServer/Public ]; then mv /build/TroveServer/Public ./Public && chmod -R a-w ./Public; fi
RUN if [ -d /build/TroveServer/Resources ]; then mv /build/TroveServer/Resources ./Resources && chmod -R a-w ./Resources; fi

# ================================
# Run image
# ================================
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:918a593b8268c222afd4e2c4f06860ac984e60719b4697e4c71d796bc8fcd042

# Keep the Swift toolchain in the build stage. The serving image needs only the
# binary's dynamic libraries, certificate roots and time-zone data.
RUN apk add --no-cache glibc libstdc++ libgcc jemalloc zlib ca-certificates tzdata \
    && addgroup -S -g 999 vapor \
    && adduser -S -D -H -u 999 -G vapor -h /app vapor

# Switch to the new home directory
WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=build --chown=vapor:vapor /staging /app

# Provide configuration needed by the built-in crash reporter and some sensible default behaviors.
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Let Docker bind to port 8080
EXPOSE 8080

# Start the Vapor service when the image is run, default to listening on 8080 in production environment
ENTRYPOINT ["./TroveServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]

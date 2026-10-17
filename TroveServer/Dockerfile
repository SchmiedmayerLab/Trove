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
FROM swift:6.4.0-noble@sha256:31d14d727f4451f25e29bac9c42563a098c39ac66415e8bad970f48038e38aca AS build
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
# Swift 6.4 SwiftBuild omits Foundation static-link dependencies, including for host macros.
# Keep this native-backend workaround scoped to the static release image build.
RUN --mount=type=cache,id=trove-server-${TARGETARCH},target=/build/TroveServer/.build,sharing=locked \
    swift build --build-system native -c release --force-resolved-versions --jobs 4 \
        --product TroveServer \
        --static-swift-stdlib \
        -Xlinker -ljemalloc && \
    # Copy main executable to staging area
    cp "$(swift build --build-system native -c release --show-bin-path)/TroveServer" /staging && \
    # Copy resources bundled by SPM to staging area
    find -L "$(swift build --build-system native -c release --show-bin-path)" -regex '.*\.resources$' -exec cp -Ra {} /staging \;


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
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:256c88bb066424045021090932d50be93c8e3f2ce3586707702a401b146f3e43

# Keep the Swift toolchain in the build stage. The serving image needs only the
# binary's dynamic libraries, certificate roots and time-zone data.
# Refresh the base digest for security fixes: apk upgrade preserves its exact world pins.
RUN apk upgrade --no-cache \
    && apk add --no-cache glibc libstdc++ libgcc jemalloc zlib ca-certificates tzdata \
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

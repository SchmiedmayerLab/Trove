#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

# ---- Build stage ----
FROM node:26-alpine@sha256:6bd9ab43c0ec0190ca7b2d193906cb8b7edf6e7f4afa43ddeccd6452710bffb5 AS builder

WORKDIR /app

# This Dockerfile is built from the monorepo root as the context.
COPY TroveWeb/package*.json ./
RUN npm ci --ignore-scripts

COPY TroveWeb ./

# The OpenAPI client is generated from the inlined API spec, which
# openapi-ts.config.ts reads ../TroveAPI/openapi.yaml, which is /TroveAPI from /app.
COPY TroveAPI/openapi.yaml /TroveAPI/openapi.yaml

RUN npm run generate:api && npm run build

# ---- Serve stage ----
FROM nginx:alpine@sha256:fed7e14be83cbd2661a75cdc5b872d936cf155d46c327084d30b8df19ae88d72

ENV APP_ENVIRONMENT=production

COPY --from=builder /app/dist /usr/share/nginx/html
COPY TroveWeb/nginx-main.conf /etc/nginx/nginx.conf
COPY TroveWeb/nginx.conf /etc/nginx/conf.d/default.conf
COPY TroveWeb/nginx-transport /etc/nginx/trove-transport
COPY --chmod=755 TroveWeb/docker-entrypoint.sh /usr/local/bin/trove-web-entrypoint

# Run as non-root for defense in depth
RUN apk upgrade --no-cache \
    && chown nginx:nginx /var/cache/nginx

USER nginx

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/trove-web-entrypoint"]
CMD ["nginx", "-g", "daemon off;"]

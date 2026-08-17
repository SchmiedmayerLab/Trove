#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

# ---- Build stage ----
FROM node:24-alpine AS builder

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
FROM nginx:alpine

COPY --from=builder /app/dist /usr/share/nginx/html
COPY TroveWeb/nginx.conf /etc/nginx/conf.d/default.conf
COPY TroveWeb/docker-entrypoint.sh /docker-entrypoint.d/10-generate-env-js.sh
RUN chmod +x /docker-entrypoint.d/10-generate-env-js.sh

# Run as non-root for defense in depth
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    chown -R nginx:nginx /var/cache/nginx && \
    chown -R nginx:nginx /var/log/nginx && \
    touch /var/run/nginx.pid && \
    chown nginx:nginx /var/run/nginx.pid

USER nginx

EXPOSE 8080

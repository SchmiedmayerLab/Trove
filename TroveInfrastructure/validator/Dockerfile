# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

# Build runtime/Dockerfile first, with network access, and pass its tag here. This
# build itself needs no network: it only adds the verified validator assets.
ARG RUNTIME_IMAGE=trove-fhir-validator-runtime:local
FROM ${RUNTIME_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY assets /opt/validator
USER 10001:10001
ENTRYPOINT ["python3", "/opt/validator/worker.py"]

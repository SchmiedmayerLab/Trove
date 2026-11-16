# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

FROM eclipse-temurin:21-jre-noble@sha256:0d57a8e90c2bb844c5a8e1b2b71e11eff06dad7edcfd803cd21ed4ae203b2515 AS java
FROM python:3.15-slim-trixie@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928
COPY --from=java /opt/java/openjdk /opt/java/openjdk
# The worker uses only the standard library; pip and its vendored packages are not needed at runtime.
RUN python3 -m pip uninstall --yes --no-input pip && rm -rf /usr/local/lib/python3*/ensurepip
ENV JAVA_HOME=/opt/java/openjdk PATH=/opt/java/openjdk/bin:$PATH PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY assets /opt/validator
USER 10001:10001
ENTRYPOINT ["python3", "/opt/validator/worker.py"]

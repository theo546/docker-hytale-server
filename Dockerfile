# Multi-stage Hytale Server
# Stage 1: Build custom minimal JRE using jlink
FROM eclipse-temurin:25-jdk-alpine AS jre-builder

# Create minimal JRE with modules needed by Hytale server
RUN $JAVA_HOME/bin/jlink \
    --add-modules java.base,java.desktop,java.naming,java.net.http,jdk.management,jdk.net,jdk.unsupported,jdk.zipfs \
    --strip-debug \
    --no-man-pages \
    --no-header-files \
    --compress=zip-9 \
    --dedup-legal-notices=error-if-not-same-content \
    --output /custom-jre

# Manually strip native libraries and remove unused desktop libs
RUN find /custom-jre/lib -name "*.so" -exec strip -p --strip-unneeded {} \; && \
    rm -f \
    /custom-jre/lib/libfontmanager.so \
    /custom-jre/lib/libjavajpeg.so \
    /custom-jre/lib/liblcms.so \
    /custom-jre/lib/libfreetype.so \
    /custom-jre/lib/libmlib_image.so

# Stage 2: Final runtime image (Alpine for shell/tools support)
FROM alpine:edge

# Install runtime dependencies and tools, then remove package manager
RUN apk add --no-cache \
    libc6-compat libstdc++ \
    curl jq unzip dbus bash coreutils \
    && rm -rf /sbin/apk /etc/apk /lib/apk /usr/share/apk /var/cache/apk/* /usr/lib/libapk.so*

# Create hytale user with UID/GID 1000
RUN adduser -D -u 1000 -h /home/hytale hytale

# Copy custom JRE from builder stage
COPY --from=jre-builder /custom-jre /opt/java

# Set environment variables
ENV JAVA_HOME=/opt/java \
    PATH="/opt/java/bin:$PATH"

# Create server and app directories with correct permissions
RUN mkdir -p /server /app /var/lib/dbus && \
    chown -R hytale:hytale /server /app /var/lib/dbus

# Copy entrypoint script
COPY --chown=hytale:hytale --chmod=0755 entrypoint.sh /app/entrypoint.sh

# Labels
LABEL maintainer="theo546" \
    author="theo546" \
    description="An easy to use Hytale server for Docker!"

ARG BUILD_DATE=""
ARG VCS_REF=""
ARG VCS_URL=""

LABEL org.label-schema.schema-version="1.0" \
    org.label-schema.build-date="${BUILD_DATE}" \
    org.label-schema.name="docker-hytale-server" \
    org.label-schema.description="An easy to use Hytale server for Docker!" \
    org.label-schema.vendor="theo546" \
    org.label-schema.url="https://github.com/theo546/docker-hytale-server" \
    org.label-schema.vcs-url="${VCS_URL}" \
    org.label-schema.vcs-ref="${VCS_REF}"

# CurseForge API Key
ARG CF_API_KEY
ENV CF_API_KEY=${CF_API_KEY}

# Set working directory
WORKDIR /server

# Default environment variables
ENV HYTALE_ACCEPT_EARLY_PLUGINS=false \
    HYTALE_ALLOW_OP=false \
    HYTALE_AUTH_MODE=AUTHENTICATED \
    HYTALE_BACKUP_DIR=/server/backups \
    HYTALE_BACKUP_ENABLED=true \
    HYTALE_BACKUP_FREQ=30 \
    HYTALE_BACKUP_MAX_COUNT=5 \
    HYTALE_BIND=0.0.0.0:5520 \
    HYTALE_CURSEFORGE_MODS= \
    HYTALE_DISABLE_SENTRY=false \
    HYTALE_IDENTITY_TOKEN= \
    HYTALE_PATCHLINE_PRE_RELEASE= \
    HYTALE_SERVER_MAX_PLAYERS=100 \
    HYTALE_SERVER_MAX_VIEW_RADIUS=32 \
    HYTALE_SERVER_MOTD= \
    HYTALE_SERVER_NAME="Hytale Server" \
    HYTALE_SERVER_OWNER_NAME= \
    HYTALE_SERVER_OWNER_UUID= \
    HYTALE_SERVER_PASSWORD= \
    HYTALE_SESSION_TOKEN=

# Expose UDP port
EXPOSE 5520/udp

# Run as hytale user
USER hytale

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]

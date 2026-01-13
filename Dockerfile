# Use eclipse-temurin as base image
FROM eclipse-temurin:25-jdk

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    unzip \
    dbus \
    && rm -rf /var/lib/apt/lists/*

# Create hytale user and group with specific UID
RUN if getent passwd 1000; then userdel -f $(getent passwd 1000 | cut -d: -f1); fi && \
    if getent group 1000; then groupdel $(getent group 1000 | cut -d: -f1); fi && \
    groupadd -g 1000 hytale && \
    useradd -u 1000 -g hytale -s /bin/bash -m hytale

# Create server directory and set permissions
RUN mkdir -p /server && chown -R hytale:hytale /server

# Prepare /var/lib/dbus for runtime persistence (writable by hytale user)
RUN mkdir -p /var/lib/dbus && chown -R hytale:hytale /var/lib/dbus

# Create script directory
RUN mkdir -p /app

# Copy entrypoint script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh && chown hytale:hytale /app/entrypoint.sh

# Set working directory to /server
WORKDIR /server

# Default environment variables
ENV HYTALE_BIND=0.0.0.0:5520 \
    HYTALE_AUTH_MODE=AUTHENTICATED \
    HYTALE_ALLOW_OP=false \
    HYTALE_BACKUP_ENABLED=true \
    HYTALE_BACKUP_DIR=/server/backups \
    HYTALE_BACKUP_FREQ=30 \
    HYTALE_ACCEPT_EARLY_PLUGINS=false \
    HYTALE_PATCHLINE_PRE_RELEASE= \
    HYTALE_SERVER_NAME="Hytale Server" \
    HYTALE_SERVER_MOTD= \
    HYTALE_SERVER_PASSWORD= \
    HYTALE_SERVER_MAX_PLAYERS=100 \
    HYTALE_SERVER_MAX_VIEW_RADIUS=32 \
    HYTALE_SERVER_OWNER_NAME=

# Expose UDP port
EXPOSE 5520/udp

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]

# Run as hytale user
USER hytale

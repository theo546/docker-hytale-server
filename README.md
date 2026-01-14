<p align="center">
  <img src="https://raw.githubusercontent.com/theo546/docker-hytale-server/refs/heads/main/logo.svg" height="125" alt="Docker Hytale Server Logo"><br>
  A Docker setup for running a Hytale server. Dead simple. Downloads, updates, authentication, configuration, it just handles all of it. You point it at a directory, run it, and it works.
</p>

## Quick Start

Ideally, use the `compose.yml` below to get started immediately.

### GitHub Container Registry (Recommended)
```yaml
services:
  hytale-server:
    image: ghcr.io/theo546/docker-hytale-server:latest
    restart: always
    read_only: true
    volumes:
      - ./data:/server
    tmpfs:
      - /tmp:size=100M,uid=1000,gid=1000,mode=1777,exec
      - /var/lib/dbus:size=5M,uid=1000,gid=1000,mode=0755
    ports:
      - "5520:5520/udp"
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges
    environment:
      # Server configuration
      - HYTALE_BIND=0.0.0.0:5520
      - HYTALE_AUTH_MODE=AUTHENTICATED
      - HYTALE_ALLOW_OP=false

      # Backup
      - HYTALE_BACKUP_ENABLED=true
      - HYTALE_BACKUP_DIR=/server/backups
      - HYTALE_BACKUP_FREQ=30

      # Experimental
      - HYTALE_ACCEPT_EARLY_PLUGINS=false

      # Downloader
      # Patchline to use (e.g. "pre-release")
      - HYTALE_PATCHLINE_PRE_RELEASE=

      # Game Config
      - HYTALE_SERVER_NAME=Hytale Server
      - HYTALE_SERVER_MOTD=
      - HYTALE_SERVER_PASSWORD=
      - HYTALE_SERVER_MAX_PLAYERS=100
      - HYTALE_SERVER_MAX_VIEW_RADIUS=32
      - HYTALE_SERVER_OWNER_NAME=
```

### Docker Hub
```yaml
services:
  hytale-server:
    image: theo546/docker-hytale-server:latest 
    # ... rest of the configuration is identical
```

## How to run

1. Copy the `compose.yml` exemple from above in a dedicated directory.
2. Create the data directory with the correct permissions:
   ```bash
   mkdir data
   sudo chown 1000:1000 data
   ```
3. Run the server:
   ```bash
   docker compose up -d
   ```
4. Check the logs to authenticate:
   ```bash
   docker compose logs -f
   ```
   You will need to authenticate twice:
   1. First, when the system downloads the game assets.
   2. Second, when the game server starts up and connects to the session service.

   Look for a log line containing a URL like this:
   `https://oauth.accounts.hytale.com/oauth2/device/verify?user_code=AAAAAAAA`

   Copy and paste that URL into your browser to authorize the server. Once the logs say "Authentication successful", you are good to go.

## Configuration

Configure the server by editing the `compose.yml` file.

| Variable | Description | Default |
|----------|-------------|---------|
| HYTALE_ACCEPT_EARLY_PLUGINS | Allow early plugins | false |
| HYTALE_ALLOW_OP | Enable operator commands | false |
| HYTALE_AUTH_MODE | Authentication mode (AUTHENTICATED/OFFLINE/INSECURE) | AUTHENTICATED |
| HYTALE_BACKUP_DIR | Directory to store backups | /server/backups |
| HYTALE_BACKUP_ENABLED | Enable automatic backups | true |
| HYTALE_BACKUP_FREQ | Frequency of backups in minutes | 30 |
| HYTALE_BACKUP_MAX_COUNT | Maximum number of backups to keep | 5 |
| HYTALE_BIND | Port binding | 0.0.0.0:5520 |
| HYTALE_DISABLE_SENTRY | Disable Sentry reporting | false |
| HYTALE_IDENTITY_TOKEN | Identity Token (JWT) | (empty) |
| HYTALE_PATCHLINE_PRE_RELEASE | Patchline to download (e.g. "pre-release") | (empty) |
| HYTALE_SERVER_MAX_PLAYERS | Maximum player count | 100 |
| HYTALE_SERVER_MAX_VIEW_RADIUS | View distance in chunks | 32 |
| HYTALE_SERVER_MOTD | Message of the day | (empty) |
| HYTALE_SERVER_NAME | Server name | Hytale Server |
| HYTALE_SERVER_OWNER_NAME | Owner name | (empty) |
| HYTALE_SERVER_OWNER_UUID | Owner UUID | (empty) |
| HYTALE_SERVER_PASSWORD | Server password | (empty) |
| HYTALE_SESSION_TOKEN | Session Token | (empty) |

## Data Storage

All server data (save files, logs, config, and your persistent machine ID) is stored in the `./data` directory.

## Authentication and Machine ID

Hytale servers use a unique "machine ID" to encrypt your login credentials. In a standard Docker environment, this ID changes every time you recreate the container, which would normally force you to re-login after every update.

This setup solves that problem. On the first run, it generates a unique machine ID and saves it to your `data` folder. On every subsequent boot, it injects this saved ID back into the system. This tricks the server into believing it is always running on the same machine, keeping your encrypted credentials valid indefinitely.

## Source Code

This project is open source!  
**[View on GitHub](https://github.com/theo546/docker-hytale-server)**
# Hytale Docker Server  
<p align="center">
  <img src="logo.svg" width="200" height="200" alt="Hytale Docker Server Logo">
</p>


This is a fully managed Docker setup for running a Hytale server. It automatically handles game updates, configuration management, and authentication persistence.

## Features

### Automated Updates
The container checks for and downloads the latest Hytale server version on every startup.

### Simple Configuration
Server settings are automatically mapped from environment variables to the game's configuration files. You don't need to manually edit any JSON files.

### Persistent Authentication
The setup automatically saves your machine ID to the data directory. This ensures you only need to authenticate once, even if you recreate the container.

## How to run

1. Install Docker and Docker Compose.
2. Run the server:
   ```bash
   docker compose up -d
   ```
3. Check the logs to authenticate:
   ```bash
   docker compose logs -f
   ```
   You will need to authenticate twice:
   1. First, when the system downloads the game assets.
   2. Second, when the Game Server starts up and connects to the session service.

   Look for a log line containing a URL like this:
   `https://oauth.accounts.hytale.com/oauth2/device/verify?user_code=AAAAAAAA`

   Copy and paste that URL into your browser to authorize the server. Once the logs say "Authentication successful", you are good to go.

## Configuration

Configure the server by editing the `compose.yml` file.

| Variable | Description | Default |
|----------|-------------|---------|
| HYTALE_SERVER_NAME | Display name of the server | Hytale Server |
| HYTALE_SERVER_OWNER_NAME | Account name of the server admin | (empty) |
| HYTALE_SERVER_PASSWORD | Server password (leave empty for none) | (empty) |
| HYTALE_SERVER_MOTD | Message of the day | (empty) |
| HYTALE_SERVER_MAX_PLAYERS | Maximum player count | 100 |
| HYTALE_SERVER_MAX_VIEW_RADIUS | View distance in chunks | 32 |
| HYTALE_AUTH_MODE | Authentication mode (AUTHENTICATED/OFFLINE) | AUTHENTICATED |
| HYTALE_BIND | Port binding | 0.0.0.0:5520 |
| HYTALE_ALLOW_OP | Enable operator commands | false |
| HYTALE_BACKUP_ENABLED | Enable automatic backups | true |
| HYTALE_BACKUP_DIR | Directory to store backups | /server/backups |
| HYTALE_BACKUP_FREQ | Backup frequency in minutes | 30 |
| HYTALE_ACCEPT_EARLY_PLUGINS | Allow early plugins | false |
| HYTALE_PATCHLINE_PRE_RELEASE | Set to "true" to download pre-release versions | (empty) |

## Data Storage

All server data (save files, logs, config, and your persistent machine ID) is stored in the `./data` directory.

## Authentication and Machine ID

Hytale servers use a unique "machine ID" to encrypt your login credentials. In a standard Docker environment, this ID changes every time you recreate the container, which would normally force you to re-login after every update.

This setup solves that problem. On the first run, it generates a unique machine ID and saves it to your `data` folder. On every subsequent boot, it injects this saved ID back into the system. This tricks the server into believing it is always running on the same machine, keeping your encrypted credentials valid indefinitely.

# mc-grazing-kangaroos

Self-hosted Minecraft server on Google Cloud Platform (GCP) with auto-shutdown to minimize costs.

## Features

- **Paper 1.21.11** Minecraft server
- **Auto-shutdown** when no players connected (saves money!)
- **One-click start** via web interface or Cloud Function
- **Dynamic DNS** with Duck DNS (stable hostname)
- **GitHub Pages** status/start page

## Quick Start

### Start the Server

Visit the [status page](https://sgilroy.github.io/mc-grazing-kangaroos/) and click "Start Server", or:

```bash
curl "https://us-east1-mc-grazing-kangaroos.cloudfunctions.net/mc-start?action=start"
```

### Check Status

```bash
curl "https://us-east1-mc-grazing-kangaroos.cloudfunctions.net/mc-start?action=status"
```

## Server Details

| Setting      | Value                       |
| ------------ | --------------------------- |
| Zone         | us-east1-b                  |
| Machine Type | e2-medium (2 vCPU, 4GB RAM) |
| OS           | Ubuntu 24.04 LTS            |
| Minecraft    | Paper 1.21.11               |
| Port         | 25565                       |

**Note:** Use your Duck DNS hostname (e.g., `your-subdomain.duckdns.org:25565`) to connect. The DNS is automatically updated when the server starts.

## Setup Guide

This repo contains a complete setup for a cost-optimized Minecraft server on GCP.

### Deploy Your Own Server

1. **Configure environment:**

   ```bash
   cp .env.example .env.local
   # Edit .env.local with your GCP project and settings
   ```

2. **Run setup script:**

   ```bash
   ./scripts/setup-gcp.sh
   ```

3. **Deploy Cloud Function:**

   ```bash
   cd cloud-function && ./deploy.sh
   ```

4. **Enable GitHub Pages** (optional):
   - Push to GitHub
   - Enable Pages with "GitHub Actions" source in repo settings

### Key Components

### 1. GCP Resources

- Compute Engine VM (`e2-medium`)
- Firewall rule for port 25565
- Cloud Function for remote start

### 2. Server Configuration

Located in `/opt/minecraft/server/server.properties`:

| Setting               | Value | Description                      |
| --------------------- | ----- | -------------------------------- |
| `view-distance`       | 12    | Chunk render distance            |
| `simulation-distance` | 12    | Entity/redstone simulation range |
| `max-players`         | 20    | Maximum concurrent players       |

### 3. Auto-Shutdown System

The server monitors player count via RCON and shuts down the VM after 1 minute of inactivity.

Files on VM:

- `/usr/local/bin/mc-idle-shutdown.sh` - Checks player count
- `/etc/systemd/system/mc-idle-shutdown.timer` - Runs check every 30 seconds

### 4. Dynamic DNS (Duck DNS)

Free dynamic DNS that updates automatically when the server starts:

- DNS update service runs on boot via systemd
- Updates `your-subdomain.duckdns.org` with the current IP
- Setup: Get a free account at [duckdns.org](https://www.duckdns.org/)

Files on VM:

- `/usr/local/bin/update-dns.sh` - Updates Duck DNS
- `/etc/systemd/system/update-dns.service` - Runs on boot

### 5. Remote Start

Cloud Function at `https://us-east1-mc-grazing-kangaroos.cloudfunctions.net/mc-start`

Query parameters:

- `?action=status` - Check status only (default)
- `?action=start` - Start if stopped

## Managing the Server

### SSH into the VM

```bash
gcloud compute ssh mc --zone us-east1-b
```

### View Logs

```bash
sudo journalctl -u minecraft -f
```

### Manual Stop/Start

```bash
# Stop VM
gcloud compute instances stop mc --zone us-east1-b

# Start VM
gcloud compute instances start mc --zone us-east1-b
```

### Get Current IP

```bash
gcloud compute instances describe mc --zone us-east1-b \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

## Performance Tuning

### Check TPS (in-game)

Use `/spark tps` as an operator.

### Adjust View Distance

```bash
gcloud compute ssh mc --zone us-east1-b --command \
  "sudo sed -i 's/view-distance=[0-9]*/view-distance=10/' /opt/minecraft/server/server.properties && sudo systemctl restart minecraft"
```

### Upgrade VM (if CPU-bound)

```bash
gcloud compute instances stop mc --zone us-east1-b
gcloud compute instances set-machine-type mc --zone us-east1-b --machine-type e2-standard-4
gcloud compute instances start mc --zone us-east1-b
```

## Cost Estimate

| Machine Type  | vCPUs      | RAM  | ~Monthly (24/7) | ~Monthly (4hr/day) |
| ------------- | ---------- | ---- | --------------- | ------------------ |
| e2-medium     | 2 (shared) | 4GB  | ~$24            | ~$4                |
| e2-standard-4 | 4          | 16GB | ~$98            | ~$16               |

With auto-shutdown, you only pay for actual play time!

## Troubleshooting

- **Can't connect:** Server may be stopped. Use status page to start it.
- **Lag:** Try reducing `view-distance` or upgrading VM.
- **Version mismatch:** Clients must use Minecraft 1.21.11.

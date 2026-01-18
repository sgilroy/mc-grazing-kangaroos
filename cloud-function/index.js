const functions = require("@google-cloud/functions-framework");
const { InstancesClient } = require("@google-cloud/compute").v1;
const net = require("net");

// Configuration from environment variables (set in Cloud Function or .env.local)
const PROJECT = process.env.GCP_PROJECT || "mc-grazing-kangaroos";
const ZONE = process.env.GCP_ZONE || "us-east1-b";
const INSTANCE = process.env.GCP_INSTANCE || "mc";
const DUCKDNS_DOMAIN = process.env.DUCKDNS_DOMAIN || "";

const instancesClient = new InstancesClient();

/**
 * Query Minecraft server using Server List Ping protocol
 * Returns server status including player count
 * @param {string} host - IP address or hostname
 * @param {number} timeout - Connection timeout in milliseconds
 * @returns {Promise<{online: boolean, players?: {online: number, max: number}, version?: string, motd?: string}>}
 */
function queryMinecraftServer(host, timeout = 5000) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let buffer = Buffer.alloc(0);

    socket.setTimeout(timeout);

    socket.on("connect", () => {
      // Build handshake packet
      const hostBuffer = Buffer.from(host, "utf8");
      const handshakeData = Buffer.concat([
        Buffer.from([0x00]), // Packet ID
        Buffer.from([0xff, 0xff, 0xff, 0xff, 0x0f]), // Protocol version (-1 as varint)
        Buffer.from([hostBuffer.length]), // Host string length
        hostBuffer, // Host
        Buffer.from([0x63, 0xdd]), // Port 25565 as unsigned short
        Buffer.from([0x01]), // Next state: status
      ]);

      // Send handshake with length prefix
      const handshakePacket = Buffer.concat([
        Buffer.from([handshakeData.length]),
        handshakeData,
      ]);

      // Status request packet (empty, just packet ID 0x00)
      const statusRequest = Buffer.from([0x01, 0x00]);

      socket.write(Buffer.concat([handshakePacket, statusRequest]));
    });

    socket.on("data", (data) => {
      buffer = Buffer.concat([buffer, data]);

      // Try to parse the response
      try {
        // Skip packet length varint and packet ID
        let offset = 0;
        // Read packet length varint
        while (offset < buffer.length && (buffer[offset] & 0x80) !== 0)
          offset++;
        offset++; // Skip last byte of varint

        if (offset >= buffer.length) return; // Need more data

        // Skip packet ID (0x00)
        offset++;

        // Read JSON string length varint
        let jsonLength = 0;
        let shift = 0;
        while (offset < buffer.length) {
          const byte = buffer[offset++];
          jsonLength |= (byte & 0x7f) << shift;
          if ((byte & 0x80) === 0) break;
          shift += 7;
        }

        if (offset + jsonLength > buffer.length) return; // Need more data

        const jsonString = buffer
          .slice(offset, offset + jsonLength)
          .toString("utf8");
        const response = JSON.parse(jsonString);

        socket.destroy();
        resolve({
          online: true,
          players: response.players || { online: 0, max: 20 },
          version: response.version?.name,
          motd:
            typeof response.description === "string"
              ? response.description
              : response.description?.text,
        });
      } catch (e) {
        // Keep waiting for more data or timeout
      }
    });

    socket.on("timeout", () => {
      socket.destroy();
      resolve({ online: false });
    });

    socket.on("error", () => {
      socket.destroy();
      resolve({ online: false });
    });

    socket.connect(25565, host);
  });
}

functions.http("startServer", async (req, res) => {
  // Set CORS headers for browser requests
  res.set("Access-Control-Allow-Origin", "*");

  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Methods", "GET, POST");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    res.status(204).send("");
    return;
  }

  // Check for action parameter: ?action=status (default) or ?action=start
  const action = req.query.action || "status";

  try {
    // Get current instance status
    const [instance] = await instancesClient.get({
      project: PROJECT,
      zone: ZONE,
      instance: INSTANCE,
    });

    const status = instance.status;
    console.log(`Instance status: ${status}, action: ${action}`);

    if (status === "RUNNING") {
      const ip = instance.networkInterfaces[0].accessConfigs[0].natIP;
      const hostname = DUCKDNS_DOMAIN ? `${DUCKDNS_DOMAIN}.duckdns.org` : null;
      const address = hostname ? `${hostname}:25565` : `${ip}:25565`;

      // Query Minecraft server for status and player count
      const serverInfo = await queryMinecraftServer(ip);

      if (serverInfo.online) {
        res.json({
          status: "running",
          message: "Server is online!",
          ip: ip,
          hostname: hostname,
          address: address,
          players: serverInfo.players,
          version: serverInfo.version,
        });
      } else {
        // VM is running but Minecraft server is still starting
        res.json({
          status: "minecraft_starting",
          message: "VM is online, Minecraft server is starting...",
          ip: ip,
          hostname: hostname,
          address: address,
        });
      }
      return;
    }

    if (status === "TERMINATED" || status === "STOPPED") {
      // Only start if action=start
      if (action === "start") {
        const [operation] = await instancesClient.start({
          project: PROJECT,
          zone: ZONE,
          instance: INSTANCE,
        });

        console.log(`Starting instance, operation: ${operation.name}`);
        const hostname = DUCKDNS_DOMAIN
          ? `${DUCKDNS_DOMAIN}.duckdns.org`
          : null;

        res.json({
          status: "starting",
          message: "Server is starting! It will be ready in ~60 seconds.",
          hostname: hostname,
          note: "Refresh to check status.",
        });
        return;
      }

      // Status check only - don't start
      const hostname = DUCKDNS_DOMAIN ? `${DUCKDNS_DOMAIN}.duckdns.org` : null;
      res.json({
        status: "stopped",
        message: "Server is offline.",
        canStart: true,
        hostname: hostname,
        address: hostname ? `${hostname}:25565` : null,
      });
      return;
    }

    // Instance is in a transitional state (STAGING, STOPPING, etc.)
    const hostname = DUCKDNS_DOMAIN ? `${DUCKDNS_DOMAIN}.duckdns.org` : null;
    res.json({
      status: status.toLowerCase(),
      message: `Server is ${status.toLowerCase()}. Please wait...`,
      hostname: hostname,
      address: hostname ? `${hostname}:25565` : null,
    });
  } catch (error) {
    console.error("Error:", error);
    res.status(500).json({
      status: "error",
      message: error.message,
    });
  }
});

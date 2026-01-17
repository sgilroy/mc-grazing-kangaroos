const functions = require("@google-cloud/functions-framework");
const { InstancesClient } = require("@google-cloud/compute").v1;

// Configuration from environment variables (set in Cloud Function or .env.local)
const PROJECT = process.env.GCP_PROJECT || "mc-grazing-kangaroos";
const ZONE = process.env.GCP_ZONE || "us-east1-b";
const INSTANCE = process.env.GCP_INSTANCE || "mc";
const DUCKDNS_DOMAIN = process.env.DUCKDNS_DOMAIN || "";

const instancesClient = new InstancesClient();

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
      res.json({
        status: "running",
        message: "Server is online!",
        ip: ip,
        hostname: hostname,
        address: hostname ? `${hostname}:25565` : `${ip}:25565`,
      });
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
      res.json({
        status: "stopped",
        message: "Server is offline.",
        canStart: true,
      });
      return;
    }

    // Instance is in a transitional state (STAGING, STOPPING, etc.)
    res.json({
      status: status.toLowerCase(),
      message: `Server is ${status.toLowerCase()}. Please wait...`,
    });
  } catch (error) {
    console.error("Error:", error);
    res.status(500).json({
      status: "error",
      message: error.message,
    });
  }
});

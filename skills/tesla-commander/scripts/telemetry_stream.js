#!/usr/bin/env node
/**
 * Tesla Fleet Telemetry Streaming Client
 * Uses Node.js native WebSocket to stream live telemetry from Tessie.
 */

const fs = require('fs');
const path = require('path');

function getEnv(name) {
  if (process.env[name]) return process.env[name].trim();

  const home = process.env.HOME || '';
  const candidateFiles = [
    path.join(process.cwd(), '.env'),
    path.join(__dirname, '.env'),
    path.join(__dirname, '..', '.env'),
    path.join(home, '.zshenv'),
    path.join(home, '.zshrc'),
    path.join(home, '.bashrc'),
    path.join(home, '.bash_profile'),
    path.join(home, '.profile'),
    path.join(home, '.config', 'fish', 'config.fish'),
  ];

  for (const fpath of candidateFiles) {
    if (!fs.existsSync(fpath)) continue;
    try {
      const content = fs.readFileSync(fpath, 'utf8');
      const lines = content.split('\n');
      for (let line of lines) {
        line = line.trim();
        if (!line || line.startsWith('#')) continue;

        // POSIX / Sh / Bash / Zsh
        const match = line.match(new RegExp(`^(?:export\\s+)?${name}=["']?([^"'#\\r\\n]+)`));
        if (match) return match[1].trim();

        // Fish shell
        const matchFish = line.match(new RegExp(`^set\\s+(?:-[a-zA-Z]+\\s+)*${name}\\s+["']?([^"'#\\r\\n]+)`));
        if (matchFish) return matchFish[1].trim();
      }
    } catch (_) {}
  }
  return null;
}

const args = process.argv.slice(2);
let vin = null;
let duration = 15;
let outputJson = false;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--vin' && args[i + 1]) {
    vin = args[i + 1];
    i++;
  } else if (args[i] === '--duration' && args[i + 1]) {
    duration = parseInt(args[i + 1], 10);
    i++;
  } else if (args[i] === '--json') {
    outputJson = true;
  }
}

const token = getEnv('TESSIE_ACCESS_TOKEN');
if (!token) {
  console.error('Error: TESSIE_ACCESS_TOKEN not found in environment, .env, or shell profiles');
  process.exit(1);
}

if (!vin) {
  vin = getEnv('MY_TESLA_VIN') || process.env.TESLA_VIN;
}

if (!vin) {
  console.error('Error: Vehicle VIN not specified. Please set MY_TESLA_VIN or pass --vin <VIN>');
  process.exit(1);
}

const url = `wss://streaming.tessie.com/${vin}?access_token=${token}`;
console.log(`[Telemetry] Connecting to wss://streaming.tessie.com/${vin}...`);
console.log(`[Telemetry] Will stream for ${duration} seconds.`);

const ws = new WebSocket(url);

const timer = setTimeout(() => {
  console.log(`\n[Telemetry] Stream duration reached (${duration}s). Closing.`);
  ws.close();
  process.exit(0);
}, duration * 1000);

ws.onopen = () => {
  console.log(`[Telemetry] Connected! Listening for real-time vehicle events...\n`);
};

ws.onmessage = (event) => {
  if (outputJson) {
    console.log(event.data);
    return;
  }

  try {
    const msg = JSON.parse(event.data);
    const time = msg.createdAt ? new Date(msg.createdAt).toLocaleTimeString() : new Date().toLocaleTimeString();

    if (msg.data && Array.isArray(msg.data)) {
      msg.data.forEach((item) => {
        const key = item.key;
        const valObj = item.value || {};
        const val = valObj.doubleValue ?? valObj.stringValue ?? valObj.intValue ?? JSON.stringify(valObj);
        console.log(`[${time}] [DATA] ${key.padEnd(22)} : ${val}`);
      });
    } else if (msg.alerts && Array.isArray(msg.alerts)) {
      msg.alerts.forEach((alert) => {
        console.log(`[${time}] [ALERT] ${alert.name} (Started: ${alert.startedAt || 'N/A'})`);
      });
    } else if (msg.status) {
      console.log(`[${time}] [STATUS] Vehicle connection: ${msg.status}`);
    } else {
      console.log(`[${time}] [RAW] ${event.data}`);
    }
  } catch (err) {
    console.log(`[MSG] ${event.data}`);
  }
};

ws.onerror = (err) => {
  console.error('[Telemetry] WebSocket error:', err.message || err);
};

ws.onclose = (event) => {
  clearTimeout(timer);
  if (event.code !== 1000 && event.code !== 1005) {
    console.log(`[Telemetry] Disconnected (code: ${event.code}, reason: ${event.reason || 'None'})`);
  }
};

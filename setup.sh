#!/usr/bin/env bash
#
# setup.sh — scaffolds the complete Hearth3D project.
#
# Hearth3D is a self-contained, Dockerized dashboard for Home Assistant:
#   * Node.js backend that mirrors the HA area/device/entity/floor registries
#     and streams live state changes to the browser over WebSocket.
#   * React + Tailwind frontend rendering a dark-mode isometric floor plan,
#     with click-to-toggle devices, light brightness/color controls, camera
#     tiles, sensor sparklines, floor tabs, and a full customization edit
#     mode (rename/move/hide devices, rename rooms, assign floors, reorder).
#   * Layout & customization persist server-side on a Docker volume and are
#     shared by every browser.
#   * Multi-stage Dockerfile + docker-compose.yml (port 8080).
#
# Usage:
#   ./setup.sh [target-directory]     # default: ./hearth3d
#   cd hearth3d
#   cp .env.example .env              # then set HA_URL and HA_TOKEN
#   docker compose up --build
#
set -euo pipefail

PROJECT_DIR="${1:-hearth3d}"

if [ -e "$PROJECT_DIR" ]; then
  echo "Error: '$PROJECT_DIR' already exists. Remove it or pass a different directory name." >&2
  exit 1
fi

echo "Creating Hearth3D project in ./$PROJECT_DIR ..."
mkdir -p "$PROJECT_DIR/server" \
         "$PROJECT_DIR/frontend/src/components" \
         "$PROJECT_DIR/frontend/src/hooks" \
         "$PROJECT_DIR/frontend/src/utils"
cd "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# Backend: server/package.json
# ---------------------------------------------------------------------------
cat > server/package.json <<'EOF'
{
  "name": "hearth3d-server",
  "private": true,
  "version": "1.1.0",
  "description": "Hearth3D backend: Home Assistant bridge and static frontend host",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "ws": "^8.18.0"
  }
}
EOF

# ---------------------------------------------------------------------------
# Backend: server/server.js
# ---------------------------------------------------------------------------
cat > server/server.js <<'EOF'
'use strict';

/**
 * Hearth3D backend.
 *
 * Connects to the Home Assistant WebSocket API, mirrors the
 * area/device/entity/floor registries into a room -> devices topology,
 * streams state changes to browser clients over a local WebSocket (path /ws
 * on the same port), relays toggle / light commands back to Home Assistant,
 * proxies camera snapshots, and persists the shared dashboard customization
 * (positions, renames, hidden items, floors, room order) to DATA_DIR.
 *
 * Runs standalone (HA_URL + HA_TOKEN) or inside a Home Assistant add-on
 * sandbox (SUPERVISOR_TOKEN, no HA_URL needed).
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');

const RAW_HA_URL = (process.env.HA_URL || '').replace(/\/+$/, '');
const SUPERVISOR_TOKEN = process.env.SUPERVISOR_TOKEN || '';
const IS_ADDON = !RAW_HA_URL && !!SUPERVISOR_TOKEN;
const HA_URL = RAW_HA_URL || 'http://homeassistant.local:8123';
const TOKEN = process.env.HA_TOKEN || SUPERVISOR_TOKEN;
const WS_URL = IS_ADDON ? 'ws://supervisor/core/websocket' : HA_URL.replace(/^http/, 'ws') + '/api/websocket';
const REST_BASE = IS_ADDON ? 'http://supervisor/core/api' : `${HA_URL}/api`;
const PORT = parseInt(process.env.PORT || '8080', 10);
const PUBLIC_DIR = path.join(__dirname, 'public');
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const LAYOUT_FILE = path.join(DATA_DIR, 'layout.json');

// Entity domains shown on the dashboard. Override with e.g.
// DOMAINS=light,switch,sensor in the environment.
const DISPLAY_DOMAINS = (process.env.DOMAINS || 'light,switch,media_player,fan,cover,lock,climate,vacuum,camera')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

if (!TOKEN) {
  console.error('[hearth3d] FATAL: no credentials. Set HA_TOKEN (create a long-lived access');
  console.error('[hearth3d] token in Home Assistant: Profile -> Security) in your .env file.');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

const registry = { areas: [], devices: [], entities: [], floors: [] };
const states = new Map(); // entity_id -> { state, attributes, last_changed }
const history = new Map(); // sensor entity_id -> [{ t, v }] (last 60 points)
let topology = []; // [{ area_id, name, floor_id, devices: [{ entity_id, domain, name }] }]
let displayedEntities = new Set();
let registryRefreshTimer = null;

// Dashboard customization, persisted to disk and shared by all browsers:
// { devices: { id: { x, y, room, hidden, name } },
//   rooms:   { id: { hidden, floor, name } },
//   roomOrder: [area_id], floors: [{ id, name }],
//   settings: { background } }
let layout = { devices: {}, rooms: {}, roomOrder: [], floors: [], settings: {} };
let layoutSaveTimer = null;

try {
  layout = sanitizeLayout(JSON.parse(fs.readFileSync(LAYOUT_FILE, 'utf8')));
  console.log(`[hearth3d] Loaded saved layout from ${LAYOUT_FILE}`);
} catch {
  // First run or unreadable file — start with the empty layout.
}

function sanitizeLayout(input) {
  const out = { devices: {}, rooms: {}, roomOrder: [], floors: [], settings: {} };
  if (!input || typeof input !== 'object') return out;
  const str = (v, max = 80) => (typeof v === 'string' && v.length > 0 ? v.slice(0, max) : undefined);
  if (input.devices && typeof input.devices === 'object') {
    for (const [id, o] of Object.entries(input.devices)) {
      if (!o || typeof o !== 'object') continue;
      const d = {};
      if (Number.isFinite(o.x)) d.x = Math.min(100, Math.max(0, o.x));
      if (Number.isFinite(o.y)) d.y = Math.min(100, Math.max(0, o.y));
      if (str(o.room, 120)) d.room = str(o.room, 120);
      if (o.hidden === true) d.hidden = true;
      if (str(o.name)) d.name = str(o.name);
      if (Object.keys(d).length > 0) out.devices[id.slice(0, 120)] = d;
    }
  }
  if (input.rooms && typeof input.rooms === 'object') {
    for (const [id, o] of Object.entries(input.rooms)) {
      if (!o || typeof o !== 'object') continue;
      const r = {};
      if (o.hidden === true) r.hidden = true;
      if (str(o.floor, 120)) r.floor = str(o.floor, 120);
      if (str(o.name)) r.name = str(o.name);
      if (Object.keys(r).length > 0) out.rooms[id.slice(0, 120)] = r;
    }
  }
  if (Array.isArray(input.roomOrder)) {
    out.roomOrder = input.roomOrder
      .filter((v) => typeof v === 'string')
      .map((v) => v.slice(0, 120))
      .slice(0, 500);
  }
  if (Array.isArray(input.floors)) {
    out.floors = input.floors
      .filter((f) => f && typeof f === 'object' && typeof f.id === 'string' && typeof f.name === 'string')
      .map((f) => ({ id: f.id.slice(0, 60), name: f.name.slice(0, 60) }))
      .slice(0, 50);
  }
  if (input.settings && typeof input.settings === 'object') {
    const background = str(input.settings.background, 40);
    if (background) out.settings.background = background;
  }
  return out;
}

function saveLayoutSoon() {
  clearTimeout(layoutSaveTimer);
  layoutSaveTimer = setTimeout(() => {
    fs.mkdir(DATA_DIR, { recursive: true }, (dirErr) => {
      if (dirErr) return console.error(`[hearth3d] Cannot create ${DATA_DIR}: ${dirErr.message}`);
      fs.writeFile(LAYOUT_FILE, JSON.stringify(layout), (err) => {
        if (err) console.error(`[hearth3d] Failed to save layout: ${err.message}`);
      });
    });
  }, 500);
}

function pickState(s) {
  const a = s.attributes || {};
  return {
    state: s.state,
    attributes: {
      friendly_name: a.friendly_name,
      brightness: a.brightness,
      rgb_color: a.rgb_color,
      media_title: a.media_title,
      current_temperature: a.current_temperature,
      temperature: a.temperature,
      unit_of_measurement: a.unit_of_measurement,
      device_class: a.device_class,
    },
    last_changed: s.last_changed,
  };
}

function recordHistory(entityId, stateStr, lastChanged) {
  if (!entityId.startsWith('sensor.')) return;
  const value = parseFloat(stateStr);
  if (!Number.isFinite(value)) return;
  const points = history.get(entityId) || [];
  points.push({ t: Date.parse(lastChanged) || Date.now(), v: value });
  if (points.length > 60) points.shift();
  history.set(entityId, points);
}

function rebuildTopology() {
  const deviceById = new Map(registry.devices.map((d) => [d.id, d]));
  const rooms = new Map();
  for (const area of registry.areas) {
    rooms.set(area.area_id, {
      area_id: area.area_id,
      name: area.name,
      floor_id: area.floor_id || null,
      devices: [],
    });
  }
  const unassigned = { area_id: '_unassigned', name: 'Unassigned', floor_id: null, devices: [] };

  for (const entity of registry.entities) {
    if (entity.disabled_by || entity.hidden_by) continue;
    const domain = entity.entity_id.split('.')[0];
    if (!DISPLAY_DOMAINS.includes(domain)) continue;

    // An entity's own area assignment overrides the area of its parent device.
    let areaId = entity.area_id;
    if (!areaId && entity.device_id) {
      const device = deviceById.get(entity.device_id);
      if (device) areaId = device.area_id;
    }

    const st = states.get(entity.entity_id);
    const room = (areaId && rooms.get(areaId)) || unassigned;
    room.devices.push({
      entity_id: entity.entity_id,
      domain,
      name:
        entity.name ||
        entity.original_name ||
        (st && st.attributes.friendly_name) ||
        entity.entity_id,
    });
  }

  if (unassigned.devices.length > 0) rooms.set(unassigned.area_id, unassigned);

  // Empty rooms are included so users can move devices into them; the
  // frontend hides them outside edit mode.
  topology = [...rooms.values()].sort((a, b) => a.name.localeCompare(b.name));
  displayedEntities = new Set(topology.flatMap((room) => room.devices.map((d) => d.entity_id)));
}

function topologyMessage() {
  const visibleStates = {};
  const visibleHistory = {};
  for (const entityId of displayedEntities) {
    const s = states.get(entityId);
    if (s) visibleStates[entityId] = s;
    const h = history.get(entityId);
    if (h && h.length > 0) visibleHistory[entityId] = h;
  }
  const floors = registry.floors
    .map((f) => ({ floor_id: f.floor_id, name: f.name, level: f.level ?? 0 }))
    .sort((a, b) => a.level - b.level);
  return { type: 'topology', rooms: topology, floors, states: visibleStates, history: visibleHistory };
}

// ---------------------------------------------------------------------------
// Home Assistant connection
// ---------------------------------------------------------------------------

class HomeAssistant {
  constructor(wsUrl, token) {
    this.wsUrl = wsUrl;
    this.token = token;
    this.ws = null;
    this.msgId = 0;
    this.pending = new Map();
    this.connected = false;
    this.reconnectDelay = 1000;
    this.pingTimer = null;
  }

  connect() {
    console.log(`[hearth3d] Connecting to Home Assistant at ${this.wsUrl}`);
    this.ws = new WebSocket(this.wsUrl);
    this.ws.on('message', (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        return;
      }
      this.handleMessage(msg);
    });
    this.ws.on('error', (err) => console.error(`[hearth3d] HA socket error: ${err.message}`));
    this.ws.on('close', () => this.handleClose());
  }

  handleClose() {
    const wasConnected = this.connected;
    this.connected = false;
    clearInterval(this.pingTimer);
    for (const { reject } of this.pending.values()) reject(new Error('HA connection closed'));
    this.pending.clear();
    if (wasConnected) broadcast({ type: 'ha_status', connected: false });
    console.warn(`[hearth3d] HA connection closed; retrying in ${this.reconnectDelay / 1000}s`);
    setTimeout(() => this.connect(), this.reconnectDelay);
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000);
  }

  send(payload) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error('not connected to Home Assistant'));
    }
    const id = ++this.msgId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, ...payload }));
    });
  }

  async handleMessage(msg) {
    switch (msg.type) {
      case 'auth_required':
        this.ws.send(JSON.stringify({ type: 'auth', access_token: this.token }));
        break;

      case 'auth_invalid':
        console.error('[hearth3d] FATAL: Home Assistant rejected the access token (auth_invalid).');
        process.exit(1);
        break;

      case 'auth_ok':
        console.log(`[hearth3d] Authenticated with Home Assistant ${msg.ha_version || ''}`);
        this.connected = true;
        this.reconnectDelay = 1000;
        this.startPing();
        try {
          await this.bootstrap();
        } catch (err) {
          console.error(`[hearth3d] Bootstrap failed: ${err.message}`);
          this.ws.close();
        }
        break;

      case 'result':
      case 'pong': {
        const request = this.pending.get(msg.id);
        if (!request) break;
        this.pending.delete(msg.id);
        if (msg.type === 'pong' || msg.success) {
          request.resolve(msg.result);
        } else {
          request.reject(new Error(msg.error ? msg.error.message : 'unknown HA error'));
        }
        break;
      }

      case 'event':
        handleHaEvent(msg.event);
        break;
    }
  }

  async fetchRegistries() {
    const [areas, devices, entities] = await Promise.all([
      this.send({ type: 'config/area_registry/list' }),
      this.send({ type: 'config/device_registry/list' }),
      this.send({ type: 'config/entity_registry/list' }),
    ]);
    // Floor registry requires HA 2024.4+; tolerate its absence.
    const floors = await this.send({ type: 'config/floor_registry/list' }).catch(() => []);
    registry.areas = areas;
    registry.devices = devices;
    registry.entities = entities;
    registry.floors = Array.isArray(floors) ? floors : [];
  }

  async bootstrap() {
    await this.fetchRegistries();
    const allStates = await this.send({ type: 'get_states' });
    states.clear();
    history.clear();
    for (const s of allStates) {
      states.set(s.entity_id, pickState(s));
      recordHistory(s.entity_id, s.state, s.last_changed);
    }
    rebuildTopology();

    await this.send({ type: 'subscribe_events', event_type: 'state_changed' });
    for (const eventType of [
      'area_registry_updated',
      'device_registry_updated',
      'entity_registry_updated',
      'floor_registry_updated',
    ]) {
      await this.send({ type: 'subscribe_events', event_type: eventType }).catch(() => {});
    }

    console.log(
      `[hearth3d] Topology ready: ${topology.length} rooms, ${registry.floors.length} floors, ${displayedEntities.size} devices`
    );
    broadcast({ type: 'ha_status', connected: true });
    broadcast(topologyMessage());
  }

  async refreshRegistries() {
    await this.fetchRegistries();
    rebuildTopology();
    broadcast(topologyMessage());
    console.log(`[hearth3d] Registries refreshed: ${topology.length} rooms`);
  }

  startPing() {
    clearInterval(this.pingTimer);
    this.pingTimer = setInterval(() => {
      const timeout = new Promise((_, reject) =>
        setTimeout(() => reject(new Error('ping timeout')), 10000)
      );
      Promise.race([this.send({ type: 'ping' }), timeout]).catch(() => {
        console.warn('[hearth3d] HA ping timed out; forcing reconnect');
        if (this.ws) this.ws.terminate();
      });
    }, 30000);
  }
}

function handleHaEvent(event) {
  if (event.event_type === 'state_changed') {
    const { entity_id: entityId, new_state: newState } = event.data;
    if (!newState) {
      states.delete(entityId);
      return;
    }
    const s = pickState(newState);
    states.set(entityId, s);
    recordHistory(entityId, newState.state, newState.last_changed);
    if (displayedEntities.has(entityId)) {
      broadcast({ type: 'state', entity_id: entityId, ...s });
    }
  } else if (event.event_type.endsWith('_registry_updated')) {
    // HA fires a burst of these while you edit areas/devices; debounce the refetch.
    clearTimeout(registryRefreshTimer);
    registryRefreshTimer = setTimeout(() => {
      ha.refreshRegistries().catch((err) =>
        console.error(`[hearth3d] Registry refresh failed: ${err.message}`)
      );
    }, 1000);
  }
}

// ---------------------------------------------------------------------------
// HTTP server (static frontend + health + camera proxy) and browser WebSocket
// ---------------------------------------------------------------------------

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.map': 'application/json',
};

function handleHttp(req, res) {
  const { pathname } = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        ok: true,
        ha_connected: ha.connected,
        rooms: topology.length,
        devices: displayedEntities.size,
      })
    );
    return;
  }

  // Camera snapshot proxy — the token never reaches the browser.
  if (pathname.startsWith('/api/camera/')) {
    const entityId = decodeURIComponent(pathname.slice('/api/camera/'.length));
    if (!entityId.startsWith('camera.') || !displayedEntities.has(entityId)) {
      res.writeHead(404);
      res.end('Unknown camera');
      return;
    }
    fetch(`${REST_BASE}/camera_proxy/${entityId}`, {
      headers: { Authorization: `Bearer ${TOKEN}` },
    })
      .then((upstream) => {
        if (!upstream.ok) throw new Error(`upstream ${upstream.status}`);
        res.writeHead(200, {
          'Content-Type': upstream.headers.get('content-type') || 'image/jpeg',
          'Cache-Control': 'no-store',
        });
        return upstream.arrayBuffer();
      })
      .then((buf) => res.end(Buffer.from(buf)))
      .catch((err) => {
        res.writeHead(502);
        res.end(`Camera proxy failed: ${err.message}`);
      });
    return;
  }

  const requested = path.normalize(path.join(PUBLIC_DIR, pathname));
  if (!requested.startsWith(PUBLIC_DIR + path.sep) && requested !== PUBLIC_DIR) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  const filePath =
    pathname === '/' || !path.extname(requested)
      ? path.join(PUBLIC_DIR, 'index.html')
      : requested;

  fs.readFile(filePath, (err, data) => {
    if (err) {
      // Single-page app fallback.
      fs.readFile(path.join(PUBLIC_DIR, 'index.html'), (indexErr, index) => {
        if (indexErr) {
          res.writeHead(404);
          res.end('Not found');
          return;
        }
        res.writeHead(200, { 'Content-Type': MIME_TYPES['.html'] });
        res.end(index);
      });
      return;
    }
    const type = MIME_TYPES[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': type });
    res.end(data);
  });
}

const server = http.createServer(handleHttp);
const wss = new WebSocket.Server({ server, path: '/ws' });

function broadcast(message) {
  const data = JSON.stringify(message);
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) client.send(data);
  }
}

wss.on('connection', (client) => {
  client.send(JSON.stringify({ type: 'ha_status', connected: ha.connected }));
  client.send(JSON.stringify({ type: 'layout', layout }));
  if (topology.length > 0) client.send(JSON.stringify(topologyMessage()));

  client.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    handleClientMessage(client, msg);
  });
});

function logServiceError(err) {
  console.error(`[hearth3d] call_service failed: ${err.message}`);
}

function handleClientMessage(sender, msg) {
  switch (msg.type) {
    case 'toggle': {
      if (typeof msg.entity_id !== 'string' || !displayedEntities.has(msg.entity_id)) return;
      const domain = msg.entity_id.split('.')[0];
      let serviceDomain = 'homeassistant';
      let service = 'toggle';
      if (domain === 'lock') {
        const current = states.get(msg.entity_id);
        serviceDomain = 'lock';
        service = current && current.state === 'locked' ? 'unlock' : 'lock';
      }
      ha.send({
        type: 'call_service',
        domain: serviceDomain,
        service,
        target: { entity_id: msg.entity_id },
      }).catch(logServiceError);
      return;
    }

    case 'light_set': {
      if (typeof msg.entity_id !== 'string' || !displayedEntities.has(msg.entity_id)) return;
      if (msg.entity_id.split('.')[0] !== 'light') return;
      const data = {};
      if (Number.isFinite(msg.brightness)) {
        data.brightness = Math.min(255, Math.max(0, Math.round(msg.brightness)));
      }
      if (
        Array.isArray(msg.rgb_color) &&
        msg.rgb_color.length === 3 &&
        msg.rgb_color.every((v) => Number.isFinite(v))
      ) {
        data.rgb_color = msg.rgb_color.map((v) => Math.min(255, Math.max(0, Math.round(v))));
      }
      if (data.brightness === 0) {
        ha.send({
          type: 'call_service',
          domain: 'light',
          service: 'turn_off',
          target: { entity_id: msg.entity_id },
        }).catch(logServiceError);
      } else if (Object.keys(data).length > 0) {
        ha.send({
          type: 'call_service',
          domain: 'light',
          service: 'turn_on',
          service_data: data,
          target: { entity_id: msg.entity_id },
        }).catch(logServiceError);
      }
      return;
    }

    case 'layout_set': {
      layout = sanitizeLayout(msg.layout);
      saveLayoutSoon();
      // Keep other browsers in sync; the sender already has this state.
      const data = JSON.stringify({ type: 'layout', layout });
      for (const client of wss.clients) {
        if (client !== sender && client.readyState === WebSocket.OPEN) client.send(data);
      }
      return;
    }
  }
}

const ha = new HomeAssistant(WS_URL, TOKEN);

server.listen(PORT, () => {
  console.log(`[hearth3d] Dashboard listening on http://0.0.0.0:${PORT}`);
  ha.connect();
});

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/package.json
# ---------------------------------------------------------------------------
cat > frontend/package.json <<'EOF'
{
  "name": "hearth3d-frontend",
  "private": true,
  "version": "1.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "@react-three/drei": "^9.114.3",
    "@react-three/fiber": "^8.17.10",
    "@react-three/postprocessing": "^2.16.3",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "three": "^0.169.0"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.2",
    "autoprefixer": "^10.4.20",
    "postcss": "^8.4.47",
    "tailwindcss": "^3.4.13",
    "vite": "^5.4.8"
  }
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/vite.config.js
# ---------------------------------------------------------------------------
cat > frontend/vite.config.js <<'EOF'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The proxy lets `npm run dev` talk to a locally running backend
// (node server/server.js) during development outside Docker.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/ws': { target: 'ws://localhost:8080', ws: true },
      '/health': 'http://localhost:8080',
      '/api': 'http://localhost:8080',
    },
  },
});
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/tailwind.config.js
# ---------------------------------------------------------------------------
cat > frontend/tailwind.config.js <<'EOF'
/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {},
  },
  plugins: [],
};
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/postcss.config.js
# ---------------------------------------------------------------------------
cat > frontend/postcss.config.js <<'EOF'
export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
};
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/index.html
# ---------------------------------------------------------------------------
cat > frontend/index.html <<'EOF'
<!doctype html>
<html lang="en" class="dark">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Hearth3D</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/index.css
# ---------------------------------------------------------------------------
cat > frontend/src/index.css <<'EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

html,
body,
#root {
  height: 100%;
}

body {
  @apply bg-slate-950 text-slate-100 antialiased;
  background-image: radial-gradient(circle at 20% 0%, rgba(56, 189, 248, 0.06), transparent 40%),
    radial-gradient(circle at 80% 100%, rgba(251, 191, 36, 0.05), transparent 40%);
}

/* Anchors a device chip to its saved position in the flat edit-mode plan.
   The live view renders rooms in a real 3D scene (see Scene3D.jsx). */
.device-billboard {
  transform: translate(-50%, -50%);
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/main.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/main.jsx <<'EOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import './index.css';

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/hooks/useHearthSocket.js
# ---------------------------------------------------------------------------
cat > frontend/src/hooks/useHearthSocket.js <<'EOF'
import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Maintains the WebSocket connection to the Hearth3D backend.
 * Exposes the room topology, floors, live entity states, sensor history,
 * the server-persisted layout config, connection flags, and command senders.
 * Reconnects with backoff.
 */
export default function useHearthSocket() {
  const [rooms, setRooms] = useState([]);
  const [floors, setFloors] = useState([]);
  const [states, setStates] = useState({});
  const [history, setHistory] = useState({});
  const [serverConfig, setServerConfig] = useState(null);
  const [haConnected, setHaConnected] = useState(false);
  const [wsConnected, setWsConnected] = useState(false);
  const wsRef = useRef(null);
  const retryRef = useRef(1000);

  useEffect(() => {
    let closed = false;
    let reconnectTimer;

    function connect() {
      const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
      const ws = new WebSocket(`${proto}://${window.location.host}/ws`);
      wsRef.current = ws;

      ws.onopen = () => {
        setWsConnected(true);
        retryRef.current = 1000;
      };

      ws.onmessage = (event) => {
        let msg;
        try {
          msg = JSON.parse(event.data);
        } catch {
          return;
        }
        if (msg.type === 'topology') {
          setRooms(msg.rooms);
          setFloors(msg.floors || []);
          setStates(msg.states);
          setHistory(msg.history || {});
        } else if (msg.type === 'state') {
          setStates((prev) => ({
            ...prev,
            [msg.entity_id]: {
              state: msg.state,
              attributes: msg.attributes,
              last_changed: msg.last_changed,
            },
          }));
          if (msg.entity_id.startsWith('sensor.')) {
            const value = parseFloat(msg.state);
            if (Number.isFinite(value)) {
              setHistory((prev) => {
                const points = [...(prev[msg.entity_id] || []), { t: Date.now(), v: value }];
                if (points.length > 60) points.shift();
                return { ...prev, [msg.entity_id]: points };
              });
            }
          }
        } else if (msg.type === 'layout') {
          setServerConfig(msg.layout);
        } else if (msg.type === 'ha_status') {
          setHaConnected(msg.connected);
        }
      };

      ws.onclose = () => {
        setWsConnected(false);
        if (closed) return;
        reconnectTimer = setTimeout(connect, retryRef.current);
        retryRef.current = Math.min(retryRef.current * 2, 15000);
      };
    }

    connect();
    return () => {
      closed = true;
      clearTimeout(reconnectTimer);
      if (wsRef.current) wsRef.current.close();
    };
  }, []);

  const sendJson = useCallback((obj) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
  }, []);

  const toggle = useCallback((entityId) => sendJson({ type: 'toggle', entity_id: entityId }), [sendJson]);
  const lightSet = useCallback(
    (entityId, payload) => sendJson({ type: 'light_set', entity_id: entityId, ...payload }),
    [sendJson]
  );
  const sendConfig = useCallback((layout) => sendJson({ type: 'layout_set', layout }), [sendJson]);

  return {
    rooms,
    floors,
    states,
    history,
    serverConfig,
    haConnected,
    wsConnected,
    toggle,
    lightSet,
    sendConfig,
  };
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/Icon.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/Icon.jsx <<'EOF'
const PATHS = {
  light: (
    <>
      <circle cx="12" cy="9.5" r="5.5" />
      <path d="M9.5 14.5v2.5h5v-2.5" />
      <path d="M10.5 20.5h3" />
    </>
  ),
  switch: (
    <>
      <path d="M12 3v8" />
      <path d="M6.6 6.6a7.5 7.5 0 1 0 10.8 0" />
    </>
  ),
  media_player: (
    <>
      <rect x="7" y="3.5" width="10" height="17" rx="2" />
      <circle cx="12" cy="14.5" r="3" />
      <circle cx="12" cy="7.5" r="1" />
    </>
  ),
  fan: (
    <>
      <circle cx="12" cy="12" r="1.8" />
      <path d="M12 10.2c-.5-3.8 1-6.2 3-6.2 1.8 0 2.6 1.8 1.4 3.4-1 1.4-2.8 2.3-4.4 2.8z" />
      <path d="M13.8 12c3.8-.5 6.2 1 6.2 3 0 1.8-1.8 2.6-3.4 1.4-1.4-1-2.3-2.8-2.8-4.4z" />
      <path d="M12 13.8c.5 3.8-1 6.2-3 6.2-1.8 0-2.6-1.8-1.4-3.4 1-1.4 2.8-2.3 4.4-2.8z" />
      <path d="M10.2 12c-3.8.5-6.2-1-6.2-3 0-1.8 1.8-2.6 3.4-1.4 1.4 1 2.3 2.8 2.8 4.4z" />
    </>
  ),
  cover: (
    <>
      <rect x="5" y="4" width="14" height="16" rx="1.5" />
      <path d="M5 8.5h14" />
      <path d="M5 13h14" />
      <path d="M12 16.5v1.5" />
    </>
  ),
  lock: (
    <>
      <rect x="6" y="11" width="12" height="9" rx="2" />
      <path d="M9 11V8a3 3 0 0 1 6 0v3" />
    </>
  ),
  climate: (
    <>
      <circle cx="12" cy="17" r="3.5" />
      <rect x="10.5" y="3.5" width="3" height="10.5" rx="1.5" />
    </>
  ),
  vacuum: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M3.5 12h17" />
      <circle cx="12" cy="8" r="1.5" />
    </>
  ),
  camera: (
    <>
      <rect x="3" y="7" width="12.5" height="10" rx="2" />
      <path d="M15.5 10.5 21 8v8l-5.5-2.5z" />
    </>
  ),
  binary_sensor: (
    <>
      <path d="M3 12s3.5-6 9-6 9 6 9 6-3.5 6-9 6-9-6-9-6z" />
      <circle cx="12" cy="12" r="2.5" />
    </>
  ),
  sensor: <path d="M3 12h4l2.5-6.5 4 13 2.5-6.5H21" />,
  default: <circle cx="12" cy="12" r="7" />,
};

export default function Icon({ domain, className }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      {PATHS[domain] || PATHS.default}
    </svg>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/Sparkline.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/Sparkline.jsx <<'EOF'
export default function Sparkline({ points, className }) {
  if (!points || points.length < 2) return null;
  const w = 64;
  const h = 18;
  const pad = 2;
  const values = points.map((p) => p.v);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const step = (w - pad * 2) / (points.length - 1);
  const d = points
    .map(
      (p, i) =>
        `${i === 0 ? 'M' : 'L'}${(pad + i * step).toFixed(1)} ${(
          h - pad - ((p.v - min) / span) * (h - pad * 2)
        ).toFixed(1)}`
    )
    .join(' ');
  return (
    <svg viewBox={`0 0 ${w} ${h}`} className={className} aria-hidden="true">
      <path d={d} fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/utils/layout.js
# ---------------------------------------------------------------------------
cat > frontend/src/utils/layout.js <<'EOF'
// Arranges devices without a saved position into a padded grid inside their
// room. Alternate rows are offset (hex-style packing) so chips don't stack.
// Coordinates are percentages of the room card / floor slab.
export function defaultPos(index, count) {
  const cols = Math.max(1, Math.ceil(Math.sqrt(count)));
  const rows = Math.max(1, Math.ceil(count / cols));
  const col = index % cols;
  const row = Math.floor(index / cols);
  return {
    x: 12 + ((col + (row % 2 ? 0.65 : 0.35)) / cols) * 76,
    y: 24 + ((row + 0.5) / rows) * 64,
  };
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/utils/themes.js
# ---------------------------------------------------------------------------
cat > frontend/src/utils/themes.js <<'EOF'
/**
 * Scene background themes. `swatch` is a CSS preview gradient for the picker;
 * the remaining fields drive the Three.js stage (background/fog color, ground
 * plane, grid line colors, ambient level, particle field, star dome).
 */
export const THEMES = [
  {
    id: 'midnight',
    name: 'Midnight',
    swatch: 'linear-gradient(135deg, #020617 0%, #10233f 100%)',
    bg: '#020617',
    floor: '#040a16',
    ambient: 0.65,
    grid: ['#12203a', '#0a1424'],
    sparkles: { color: '#7dd3fc', count: 140, size: 1.6, speed: 0.25, opacity: 0.35 },
  },
  {
    id: 'starfield',
    name: 'Starfield',
    swatch: 'radial-gradient(circle at 30% 30%, #16204a 0%, #01030d 70%)',
    bg: '#01030d',
    floor: '#02040c',
    ambient: 0.6,
    grid: ['#0d1830', '#070f20'],
    stars: true,
  },
  {
    id: 'synthwave',
    name: 'Synthwave',
    swatch: 'linear-gradient(135deg, #2a0a4a 0%, #0d0221 55%, #ff2d95 130%)',
    bg: '#0d0221',
    floor: '#08021a',
    ambient: 0.6,
    grid: ['#ff2d95', '#2a0a4a'],
    sparkles: { color: '#f472b6', count: 120, size: 1.8, speed: 0.35, opacity: 0.4 },
  },
  {
    id: 'aurora',
    name: 'Aurora',
    swatch: 'linear-gradient(135deg, #02100e 0%, #0b4f3d 100%)',
    bg: '#02100e',
    floor: '#03130f',
    ambient: 0.62,
    grid: ['#0e3b2e', '#06231c'],
    sparkles: { color: '#34d399', count: 160, size: 1.7, speed: 0.2, opacity: 0.4 },
  },
  {
    id: 'ember',
    name: 'Ember',
    swatch: 'linear-gradient(135deg, #140803 0%, #7c2d12 130%)',
    bg: '#140803',
    floor: '#0d0502',
    ambient: 0.55,
    grid: ['#3b1a0e', '#241008'],
    sparkles: { color: '#fb923c', count: 130, size: 1.5, speed: 0.45, opacity: 0.4 },
  },
  {
    id: 'snowfall',
    name: 'Snowfall',
    swatch: 'linear-gradient(135deg, #0a1220 0%, #3a4f6e 130%)',
    bg: '#0a1220',
    floor: '#0c1526',
    ambient: 0.7,
    grid: ['#1e2f4a', '#14213a'],
    sparkles: { color: '#e2e8f0', count: 220, size: 2.2, speed: 0.12, opacity: 0.5 },
  },
  {
    id: 'matrix',
    name: 'Matrix',
    swatch: 'linear-gradient(135deg, #010401 0%, #14532d 130%)',
    bg: '#010401',
    floor: '#020a04',
    ambient: 0.55,
    grid: ['#0f3d1a', '#07230e'],
    sparkles: { color: '#22c55e', count: 180, size: 1.4, speed: 0.5, opacity: 0.45 },
  },
  {
    id: 'void',
    name: 'Void',
    swatch: 'linear-gradient(135deg, #000000 0%, #17181c 100%)',
    bg: '#000000',
    floor: '#050505',
    ambient: 0.7,
    grid: null,
  },
];

export function getTheme(id) {
  return THEMES.find((t) => t.id === id) || THEMES[0];
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/ScenePanel.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/ScenePanel.jsx <<'EOF'
import Sheet from './Sheet';
import { THEMES } from '../utils/themes';

export default function ScenePanel({ current, onPick, onClose }) {
  return (
    <Sheet title="Scene background" onClose={onClose}>
      <div className="grid grid-cols-2 gap-2">
        {THEMES.map((theme) => (
          <button
            key={theme.id}
            type="button"
            onClick={() => onPick(theme.id)}
            className={`relative h-16 overflow-hidden rounded-lg ring-2 transition-all ${
              current === theme.id
                ? 'ring-sky-400'
                : 'ring-slate-700/60 hover:ring-slate-500'
            }`}
            style={{ background: theme.swatch }}
          >
            <span className="absolute bottom-1 left-2 text-[11px] font-medium text-slate-100 drop-shadow">
              {theme.name}
            </span>
            {current === theme.id && (
              <span className="absolute right-1.5 top-1 text-[11px] text-sky-300">✓</span>
            )}
          </button>
        ))}
      </div>
      <p className="mt-2 text-[10px] text-slate-500">
        Shared with everyone viewing this dashboard.
      </p>
    </Sheet>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/DeviceChip.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/DeviceChip.jsx <<'EOF'
import { useEffect, useRef, useState } from 'react';
import Icon from './Icon';
import Sparkline from './Sparkline';

export const ACTIVE_STATES = [
  'on',
  'playing',
  'open',
  'opening',
  'unlocked',
  'heat',
  'cool',
  'heat_cool',
  'auto',
  'dry',
  'fan_only',
  'cleaning',
];

const TOGGLABLE_DOMAINS = ['light', 'switch', 'fan', 'media_player', 'cover', 'lock'];

const ACTIVE_STYLES = {
  light: 'bg-amber-400/25 text-amber-300 ring-amber-400/80 shadow-[0_0_26px_5px_rgba(251,191,36,0.5)]',
  switch: 'bg-emerald-400/20 text-emerald-300 ring-emerald-400/70 shadow-[0_0_20px_2px_rgba(52,211,153,0.4)]',
  media_player: 'bg-sky-400/20 text-sky-300 ring-sky-400/70 shadow-[0_0_20px_2px_rgba(56,189,248,0.4)]',
  fan: 'bg-cyan-400/20 text-cyan-300 ring-cyan-400/70 shadow-[0_0_20px_2px_rgba(34,211,238,0.4)]',
  cover: 'bg-violet-400/20 text-violet-300 ring-violet-400/70 shadow-[0_0_20px_2px_rgba(167,139,250,0.4)]',
  lock: 'bg-red-400/20 text-red-300 ring-red-400/70 shadow-[0_0_20px_2px_rgba(248,113,113,0.4)]',
  default: 'bg-emerald-400/20 text-emerald-300 ring-emerald-400/70 shadow-[0_0_20px_2px_rgba(52,211,153,0.4)]',
};

function CameraImage({ entityId }) {
  const [tick, setTick] = useState(0);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const timer = setInterval(() => setTick((v) => v + 1), 10000);
    return () => clearInterval(timer);
  }, []);

  if (failed) {
    return (
      <span className="flex h-11 w-11 items-center justify-center">
        <Icon domain="camera" className="h-5 w-5" />
      </span>
    );
  }
  return (
    <img
      src={`/api/camera/${entityId}?t=${tick}`}
      onError={() => setFailed(true)}
      alt=""
      className="h-16 w-24 object-cover"
      draggable="false"
    />
  );
}

/**
 * The presentational device chip (icon or camera tile, label, detail line,
 * sparkline) plus its interactions: click to toggle, long-press/right-click
 * a light for its control panel, drag passthrough in edit mode. Shared by
 * the flat edit-mode plan (DeviceNode) and the 3D scene (Device3D).
 */
export default function DeviceChip({
  device,
  state,
  history,
  editMode,
  onDragStart,
  onEditClick,
  onToggle,
  onOpenLight,
}) {
  const pressRef = useRef(null);
  const stateStr = state ? state.state : 'unknown';
  const isActive = ACTIVE_STATES.includes(stateStr);
  const canToggle = TOGGLABLE_DOMAINS.includes(device.domain);

  let detail = null;
  if (device.domain === 'sensor' && state) {
    const unit = state.attributes.unit_of_measurement;
    detail = `${state.state}${unit ? ` ${unit}` : ''}`;
  } else if (device.domain === 'climate' && state && state.attributes.current_temperature != null) {
    detail = `${state.attributes.current_temperature}°`;
  } else if (device.domain === 'media_player' && stateStr === 'playing' && state.attributes.media_title) {
    detail = state.attributes.media_title;
  } else if (device.domain === 'light' && isActive && state.attributes.brightness != null) {
    detail = `${Math.round((state.attributes.brightness / 255) * 100)}%`;
  }

  const clearPress = () => {
    if (pressRef.current && pressRef.current !== 'fired') {
      clearTimeout(pressRef.current);
      pressRef.current = null;
    }
  };

  const handlePointerDown = (e) => {
    if (editMode) {
      if (onDragStart) onDragStart(e);
      return;
    }
    if (device.domain === 'light') {
      pressRef.current = setTimeout(() => {
        pressRef.current = 'fired';
        onOpenLight();
      }, 500);
    }
  };

  const handleClick = () => {
    if (pressRef.current === 'fired') {
      pressRef.current = null;
      return;
    }
    clearPress();
    if (editMode) {
      onEditClick();
      return;
    }
    if (canToggle) onToggle();
  };

  const handleContextMenu = (e) => {
    if (!editMode && device.domain === 'light') {
      e.preventDefault();
      onOpenLight();
    }
  };

  const isCamera = device.domain === 'camera';
  const chipClass = isCamera
    ? `overflow-hidden rounded-xl bg-slate-800/90 ring-1 ring-slate-600/70 transition-all duration-300 ${
        editMode ? 'cursor-grab active:cursor-grabbing' : 'cursor-default'
      }`
    : `flex h-11 w-11 select-none items-center justify-center rounded-full ring-1 transition-all duration-300 ${
        isActive
          ? ACTIVE_STYLES[device.domain] || ACTIVE_STYLES.default
          : 'bg-slate-800/90 text-slate-300 ring-slate-500/70'
      } ${
        editMode
          ? 'cursor-grab active:cursor-grabbing'
          : canToggle
            ? 'cursor-pointer hover:scale-110'
            : 'cursor-default'
      }`;

  return (
    <div className="flex w-max max-w-[120px] flex-col items-center gap-1">
      <button
        type="button"
        onPointerDown={handlePointerDown}
        onPointerLeave={clearPress}
        onClick={handleClick}
        onContextMenu={handleContextMenu}
        title={`${device.name} — ${stateStr}`}
        className={chipClass}
      >
        {isCamera ? (
          <CameraImage entityId={device.entity_id} />
        ) : (
          <Icon domain={device.domain} className="h-5 w-5" />
        )}
      </button>
      <span className="pointer-events-none max-w-[96px] truncate rounded-md bg-slate-900/90 px-1.5 py-0.5 text-[11px] font-medium leading-tight text-slate-100 ring-1 ring-slate-700/60">
        {device.name}
      </span>
      {detail && (
        <span className="pointer-events-none max-w-[96px] truncate text-[10px] text-slate-300">
          {detail}
        </span>
      )}
      {device.domain === 'sensor' && history && history.length > 1 && (
        <Sparkline points={history} className="pointer-events-none h-4 w-16 text-sky-400/80" />
      )}
    </div>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/Device3D.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/Device3D.jsx <<'EOF'
import { Html } from '@react-three/drei';
import DeviceChip, { ACTIVE_STATES } from './DeviceChip';

const DOMAIN_COLORS = {
  light: '#fbbf24',
  switch: '#34d399',
  media_player: '#38bdf8',
  fan: '#22d3ee',
  cover: '#a78bfa',
  lock: '#f87171',
  default: '#34d399',
};

/**
 * A device in the 3D scene: a pedestal puck, a glowing orb + floor light
 * pool when active (lit lights cast a real point light so rooms visibly
 * illuminate), and the interactive DOM chip floating above.
 */
export default function Device3D({ device, state, history, position, onToggle, onOpenLight }) {
  const stateStr = state ? state.state : 'unknown';
  const isActive = ACTIVE_STATES.includes(stateStr);
  const isLight = device.domain === 'light';
  let color = DOMAIN_COLORS[device.domain] || DOMAIN_COLORS.default;
  if (isLight && state && state.attributes.rgb_color) {
    color = `rgb(${state.attributes.rgb_color.map((v) => Math.round(v)).join(',')})`;
  }
  const brightness =
    isLight && state && state.attributes.brightness != null ? state.attributes.brightness / 255 : 1;

  return (
    <group position={position}>
      <mesh position={[0, 0.07, 0]} castShadow>
        <cylinderGeometry args={[0.15, 0.19, 0.14, 24]} />
        <meshStandardMaterial color="#2c3a52" roughness={0.55} metalness={0.35} />
      </mesh>
      {isActive && (
        <>
          <mesh rotation={[-Math.PI / 2, 0, 0]} position={[0, 0.011, 0]}>
            <circleGeometry args={[0.28 + (isLight ? brightness * 0.35 : 0), 32]} />
            <meshBasicMaterial color={color} transparent opacity={0.22} depthWrite={false} />
          </mesh>
          <mesh position={[0, 0.22, 0]}>
            <sphereGeometry args={[0.075, 16, 16]} />
            <meshStandardMaterial color={color} emissive={color} emissiveIntensity={2.6} toneMapped={false} />
          </mesh>
        </>
      )}
      {isLight && isActive && (
        <pointLight position={[0, 0.7, 0]} color={color} intensity={0.6 + brightness * 2} distance={3.4} decay={2} />
      )}
      <Html position={[0, 0.95, 0]} center distanceFactor={12} zIndexRange={[15, 0]}>
        <DeviceChip
          device={device}
          state={state}
          history={history}
          editMode={false}
          onToggle={onToggle}
          onOpenLight={onOpenLight}
          onEditClick={() => {}}
        />
      </Html>
    </group>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/Room3D.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/Room3D.jsx <<'EOF'
import { useRef, useState } from 'react';
import { useFrame } from '@react-three/fiber';
import { RoundedBox, Html } from '@react-three/drei';
import Device3D from './Device3D';
import { defaultPos } from '../utils/layout';

const WALL_HEIGHT = 1.15;
const WALL_T = 0.12;
const SLAB_T = 0.3;

/**
 * One room: a rounded floor slab with two low back walls, a floating name
 * plate, and its devices. Hovering gently lifts the whole room.
 */
export default function Room3D({ room, position, size, states, history, positions, onToggle, onOpenLight }) {
  const group = useRef();
  const [hovered, setHovered] = useState(false);
  const visibleDevices = room.devices.filter((d) => !d.hidden);
  const lightsOn = visibleDevices.some((d) => {
    const s = states[d.entity_id];
    return d.domain === 'light' && s && s.state === 'on';
  });

  useFrame((_, dt) => {
    if (!group.current) return;
    const target = hovered ? 0.22 : 0;
    group.current.position.y += (target - group.current.position.y) * Math.min(1, dt * 7);
  });

  return (
    <group ref={group} position-x={position[0]} position-z={position[2]}>
      <RoundedBox
        args={[size, SLAB_T, size]}
        radius={0.09}
        position={[0, -SLAB_T / 2, 0]}
        castShadow
        receiveShadow
        onPointerOver={(e) => {
          e.stopPropagation();
          setHovered(true);
        }}
        onPointerOut={() => setHovered(false)}
      >
        <meshStandardMaterial color={lightsOn ? '#1d2a45' : '#16203a'} roughness={0.85} metalness={0.15} />
      </RoundedBox>
      <mesh position={[0, WALL_HEIGHT / 2, -size / 2 + WALL_T / 2]} castShadow receiveShadow>
        <boxGeometry args={[size, WALL_HEIGHT, WALL_T]} />
        <meshStandardMaterial color="#283452" roughness={0.9} />
      </mesh>
      <mesh position={[-size / 2 + WALL_T / 2, WALL_HEIGHT / 2, 0]} castShadow receiveShadow>
        <boxGeometry args={[WALL_T, WALL_HEIGHT, size]} />
        <meshStandardMaterial color="#222d48" roughness={0.9} />
      </mesh>
      <Html
        position={[-size / 2 + 0.35, WALL_HEIGHT + 0.18, -size / 2 + 0.35]}
        center
        distanceFactor={13}
        zIndexRange={[14, 0]}
      >
        <div className="pointer-events-none w-max max-w-[160px] truncate rounded-md bg-slate-900/85 px-2 py-0.5 text-xs font-medium text-slate-100 ring-1 ring-slate-700/60">
          {room.name}
          <span className="ml-1.5 text-[10px] text-slate-400">{visibleDevices.length}</span>
        </div>
      </Html>
      {visibleDevices.map((device, i) => {
        const saved = positions[device.entity_id];
        const p =
          saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)
            ? saved
            : defaultPos(i, visibleDevices.length);
        const inset = size * 0.84;
        return (
          <Device3D
            key={device.entity_id}
            device={device}
            state={states[device.entity_id]}
            history={history[device.entity_id]}
            position={[(p.x / 100 - 0.5) * inset, 0, (p.y / 100 - 0.5) * inset]}
            onToggle={() => onToggle(device.entity_id)}
            onOpenLight={() => onOpenLight(device.entity_id)}
          />
        );
      })}
    </group>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/Scene3D.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/Scene3D.jsx <<'EOF'
import { Component } from 'react';
import { Canvas } from '@react-three/fiber';
import { OrbitControls, Sparkles, Stars, Html } from '@react-three/drei';
import { EffectComposer, Bloom } from '@react-three/postprocessing';
import Room3D from './Room3D';
import { getTheme } from '../utils/themes';

const ROOM_SIZE = 4;
const GAP = 1.4;
const LEVEL_HEIGHT = 4.3;

function levelLayout(count) {
  const cols = Math.min(4, Math.max(2, Math.ceil(Math.sqrt(count || 1))));
  const rows = Math.max(1, Math.ceil(count / cols));
  return {
    cols,
    rows,
    width: cols * ROOM_SIZE + (cols - 1) * GAP,
    depth: rows * ROOM_SIZE + (rows - 1) * GAP,
  };
}

// If WebGL can't start (old browser, blocked GPU), show a hint instead of
// letting the whole app crash — the 2D edit-mode plan still works.
class WebGLBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { failed: false };
  }

  static getDerivedStateFromError() {
    return { failed: true };
  }

  render() {
    if (this.state.failed) {
      return (
        <div className="flex h-full items-center justify-center px-6 text-center text-slate-500">
          <p className="text-sm">
            The 3D view could not start (WebGL unavailable in this browser).
            <br />
            The 2D plan in <span className="text-slate-300">Edit layout</span> still works.
          </p>
        </div>
      );
    }
    return this.props.children;
  }
}

/**
 * The live 3D floor plan: rooms laid out on a dark stage with real lighting,
 * bloom on active devices, floating dust, and an orbitable camera that slowly
 * auto-rotates until the user grabs it.
 */
function Stage({ levels, theme, states, history, positions, onToggle, onOpenLight }) {
  const layouts = levels.map((level) => levelLayout(level.rooms.length));
  const width = Math.max(...layouts.map((l) => l.width));
  const depth = Math.max(...layouts.map((l) => l.depth));
  const height = (levels.length - 1) * LEVEL_HEIGHT;
  const radius = Math.max(width, depth, height + ROOM_SIZE, ROOM_SIZE * 2);
  const targetY = height / 2;

  return (
    <Canvas
      shadows
      dpr={[1, 2]}
      camera={{ position: [radius * 0.95, targetY + radius * 0.9, radius * 0.95], fov: 38 }}
      className="!absolute !inset-0"
    >
      <color attach="background" args={[theme.bg]} />
      <fog attach="fog" args={[theme.bg, radius * 2, radius * 4.5]} />
      <ambientLight intensity={theme.ambient} />
      <directionalLight
        position={[radius * 0.8, radius * 1.4, radius * 0.6]}
        intensity={0.8}
        castShadow
        shadow-mapSize-width={2048}
        shadow-mapSize-height={2048}
        shadow-camera-left={-radius * 1.5}
        shadow-camera-right={radius * 1.5}
        shadow-camera-top={radius * 1.5}
        shadow-camera-bottom={-radius * 1.5}
        shadow-camera-near={0.5}
        shadow-camera-far={radius * 5}
      />
      {theme.grid && (
        <gridHelper args={[radius * 5, 50, theme.grid[0], theme.grid[1]]} position={[0, -0.42, 0]} />
      )}
      <mesh rotation={[-Math.PI / 2, 0, 0]} position={[0, -0.45, 0]} receiveShadow>
        <planeGeometry args={[radius * 8, radius * 8]} />
        <meshStandardMaterial color={theme.floor} roughness={1} />
      </mesh>
      {theme.stars && (
        <Stars radius={radius * 3} depth={radius} count={2500} factor={4} saturation={0} fade speed={0.6} />
      )}
      {theme.sparkles && (
        <Sparkles
          count={theme.sparkles.count}
          scale={[width * 1.8, 5 + height, depth * 1.8]}
          position={[0, 2 + height / 2, 0]}
          size={theme.sparkles.size}
          speed={theme.sparkles.speed}
          opacity={theme.sparkles.opacity}
          color={theme.sparkles.color}
        />
      )}
      {levels.map((level, li) => {
        const { cols, rows, width: levelWidth, depth: levelDepth } = layouts[li];
        return (
          <group key={level.id} position-y={li * LEVEL_HEIGHT}>
            {levels.length > 1 && level.name && (
              <Html
                position={[-levelWidth / 2 - 0.9, 0.7, levelDepth / 2]}
                center
                distanceFactor={14}
                zIndexRange={[13, 0]}
              >
                <div className="pointer-events-none w-max rounded-md bg-slate-900/85 px-2 py-0.5 text-xs font-semibold uppercase tracking-wider text-slate-300 ring-1 ring-slate-700/60">
                  {level.name}
                </div>
              </Html>
            )}
            {level.rooms.map((room, i) => {
              const col = i % cols;
              const row = Math.floor(i / cols);
              const x = (col - (cols - 1) / 2) * (ROOM_SIZE + GAP);
              const z = (row - (rows - 1) / 2) * (ROOM_SIZE + GAP);
              return (
                <Room3D
                  key={room.area_id}
                  room={room}
                  position={[x, 0, z]}
                  size={ROOM_SIZE}
                  states={states}
                  history={history}
                  positions={positions}
                  onToggle={onToggle}
                  onOpenLight={onOpenLight}
                />
              );
            })}
          </group>
        );
      })}
      <EffectComposer>
        <Bloom intensity={0.85} luminanceThreshold={0.4} luminanceSmoothing={0.25} mipmapBlur />
      </EffectComposer>
      <OrbitControls
        enableDamping
        dampingFactor={0.08}
        enablePan={false}
        minPolarAngle={0.35}
        maxPolarAngle={1.32}
        minDistance={radius * 0.5}
        maxDistance={radius * 2.4}
        target={[0, targetY, 0]}
        autoRotate
        autoRotateSpeed={0.35}
        onStart={(e) => {
          if (e && e.target) e.target.autoRotate = false;
        }}
      />
    </Canvas>
  );
}

export default function Scene3D({ themeId, ...props }) {
  return (
    <WebGLBoundary>
      <Stage theme={getTheme(themeId)} {...props} />
    </WebGLBoundary>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/Sheet.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/Sheet.jsx <<'EOF'
export default function Sheet({ title, onClose, children }) {
  return (
    <>
      <div className="fixed inset-0 z-30 bg-slate-950/40" onClick={onClose} />
      <div className="fixed bottom-6 left-1/2 z-40 w-[22rem] max-w-[calc(100vw-2rem)] -translate-x-1/2 rounded-2xl border border-slate-700 bg-slate-900/95 p-4 shadow-2xl backdrop-blur">
        <div className="mb-3 flex items-center justify-between gap-2">
          <span className="truncate text-sm font-medium text-slate-100">{title}</span>
          <button
            type="button"
            onClick={onClose}
            className="rounded px-2 text-slate-400 hover:text-slate-200"
            aria-label="Close"
          >
            ✕
          </button>
        </div>
        {children}
      </div>
    </>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/LightPanel.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/LightPanel.jsx <<'EOF'
import { useEffect, useRef, useState } from 'react';
import Sheet from './Sheet';
import Icon from './Icon';

function rgbToHex(rgb) {
  return (
    '#' +
    rgb
      .map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0'))
      .join('')
  );
}

function hexToRgb(hex) {
  return [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
}

export default function LightPanel({ device, state, onClose, onToggle, onSet }) {
  const isOn = state && state.state === 'on';
  const [brightness, setBrightness] = useState(state?.attributes?.brightness ?? 255);
  const [color, setColor] = useState(
    state?.attributes?.rgb_color ? rgbToHex(state.attributes.rgb_color) : '#ffd28a'
  );
  const timerRef = useRef(null);

  // Follow external changes (another client, a physical switch).
  useEffect(() => {
    if (state?.attributes?.brightness != null) setBrightness(state.attributes.brightness);
  }, [state?.attributes?.brightness]);

  const queue = (payload) => {
    clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => onSet(payload), 180);
  };

  return (
    <Sheet
      onClose={onClose}
      title={
        <span className="flex items-center gap-2">
          <Icon domain="light" className={`h-5 w-5 ${isOn ? 'text-amber-300' : 'text-slate-500'}`} />
          {device.name}
        </span>
      }
    >
      <div className="flex items-center gap-3">
        <button
          type="button"
          onClick={onToggle}
          className={`rounded-lg border px-3 py-1.5 text-xs ${
            isOn
              ? 'border-amber-500/60 bg-amber-500/20 text-amber-300'
              : 'border-slate-700 text-slate-300 hover:bg-slate-800'
          }`}
        >
          {isOn ? 'On' : 'Off'}
        </button>
        <input
          type="range"
          min="0"
          max="255"
          value={brightness}
          onChange={(e) => {
            const v = Number(e.target.value);
            setBrightness(v);
            queue({ brightness: v });
          }}
          className="flex-1 accent-amber-400"
          aria-label="Brightness"
        />
        <input
          type="color"
          value={color}
          onChange={(e) => {
            setColor(e.target.value);
            queue({ rgb_color: hexToRgb(e.target.value) });
          }}
          className="h-8 w-8 cursor-pointer rounded border border-slate-700 bg-transparent"
          aria-label="Color"
        />
      </div>
      <p className="mt-2 text-[10px] text-slate-500">
        Brightness {Math.round((brightness / 255) * 100)}%
      </p>
    </Sheet>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/DevicePanel.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/DevicePanel.jsx <<'EOF'
import { useState } from 'react';
import Sheet from './Sheet';

export default function DevicePanel({ device, roomId, rooms, onClose, onApply, onHide }) {
  const [name, setName] = useState(device.name);

  return (
    <Sheet title="Edit device" onClose={onClose}>
      <div className="space-y-3">
        <label className="block text-xs text-slate-400">
          Name <span className="text-slate-600">(clear to restore the Home Assistant name)</span>
          <input
            value={name}
            onChange={(e) => {
              setName(e.target.value);
              onApply({ name: e.target.value.trim() });
            }}
            className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-800/80 px-2 py-1.5 text-sm text-slate-100 outline-none focus:border-amber-500/60"
          />
        </label>
        <label className="block text-xs text-slate-400">
          Room
          <select
            value={roomId}
            onChange={(e) => onApply({ room: e.target.value === device.home ? '' : e.target.value })}
            className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-800/80 px-2 py-1.5 text-sm text-slate-100 outline-none focus:border-amber-500/60"
          >
            {rooms.map((room) => (
              <option key={room.area_id} value={room.area_id}>
                {room.name}
              </option>
            ))}
          </select>
        </label>
        <div className="flex items-center justify-between pt-1">
          <span className="max-w-[55%] truncate text-[10px] text-slate-500">{device.entity_id}</span>
          <button
            type="button"
            onClick={onHide}
            className="rounded-lg border border-red-500/50 px-3 py-1.5 text-xs text-red-300 hover:bg-red-500/10"
          >
            Hide device
          </button>
        </div>
      </div>
    </Sheet>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/RoomPanel.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/RoomPanel.jsx <<'EOF'
import { useState } from 'react';
import Sheet from './Sheet';

export default function RoomPanel({ room, floors, onClose, onApply, onHide }) {
  const [name, setName] = useState(room.name);

  const handleFloorChange = (value) => {
    if (value === (room.ha_floor || '')) {
      onApply({ floor: '' }); // matches the HA assignment — drop the override
    } else if (value === '') {
      onApply({ floor: room.ha_floor ? '_none' : '' }); // explicit "no floor"
    } else {
      onApply({ floor: value });
    }
  };

  return (
    <Sheet title="Edit room" onClose={onClose}>
      <div className="space-y-3">
        <label className="block text-xs text-slate-400">
          Name <span className="text-slate-600">(clear to restore the Home Assistant name)</span>
          <input
            value={name}
            onChange={(e) => {
              setName(e.target.value);
              onApply({ name: e.target.value.trim() });
            }}
            className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-800/80 px-2 py-1.5 text-sm text-slate-100 outline-none focus:border-amber-500/60"
          />
        </label>
        <label className="block text-xs text-slate-400">
          Floor
          <select
            value={room.floor_id || ''}
            onChange={(e) => handleFloorChange(e.target.value)}
            className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-800/80 px-2 py-1.5 text-sm text-slate-100 outline-none focus:border-amber-500/60"
          >
            <option value="">No floor</option>
            {floors.map((floor) => (
              <option key={floor.id} value={floor.id}>
                {floor.name}
              </option>
            ))}
          </select>
        </label>
        <div className="flex justify-end pt-1">
          <button
            type="button"
            onClick={onHide}
            className="rounded-lg border border-red-500/50 px-3 py-1.5 text-xs text-red-300 hover:bg-red-500/10"
          >
            Hide room
          </button>
        </div>
      </div>
    </Sheet>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/HiddenPanel.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/HiddenPanel.jsx <<'EOF'
import Sheet from './Sheet';

export default function HiddenPanel({ hiddenRooms, hiddenDevices, onShowRoom, onShowDevice, onClose }) {
  const empty = hiddenRooms.length === 0 && hiddenDevices.length === 0;

  return (
    <Sheet title="Hidden items" onClose={onClose}>
      {empty && (
        <p className="text-xs text-slate-500">
          Nothing is hidden. Hide rooms or devices from their edit panels.
        </p>
      )}
      {hiddenRooms.length > 0 && (
        <>
          <p className="mb-1 text-[10px] uppercase tracking-wide text-slate-500">Rooms</p>
          <ul className="mb-3 space-y-1.5">
            {hiddenRooms.map((room) => (
              <li key={room.area_id} className="flex items-center justify-between gap-2 text-xs text-slate-300">
                <span className="truncate">{room.name}</span>
                <button
                  type="button"
                  onClick={() => onShowRoom(room.area_id)}
                  className="shrink-0 text-emerald-400 hover:underline"
                >
                  Show
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
      {hiddenDevices.length > 0 && (
        <>
          <p className="mb-1 text-[10px] uppercase tracking-wide text-slate-500">Devices</p>
          <ul className="space-y-1.5">
            {hiddenDevices.map((device) => (
              <li key={device.entity_id} className="flex items-center justify-between gap-2 text-xs text-slate-300">
                <span className="truncate">
                  {device.name} <span className="text-slate-600">· {device.roomName}</span>
                </span>
                <button
                  type="button"
                  onClick={() => onShowDevice(device.entity_id)}
                  className="shrink-0 text-emerald-400 hover:underline"
                >
                  Show
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </Sheet>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/DeviceNode.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/DeviceNode.jsx <<'EOF'
import DeviceChip from './DeviceChip';

/**
 * Positions a DeviceChip on the flat edit-mode room card at its saved
 * (or default) percentage coordinates. The live view uses Device3D instead.
 */
export default function DeviceNode({
  device,
  state,
  history,
  pos,
  editMode,
  onDragStart,
  onEditClick,
  onToggle,
  onOpenLight,
}) {
  return (
    <div className="device-node absolute z-10" style={{ left: `${pos.x}%`, top: `${pos.y}%` }}>
      <div className="device-billboard">
        <DeviceChip
          device={device}
          state={state}
          history={history}
          editMode={editMode}
          onDragStart={onDragStart}
          onEditClick={onEditClick}
          onToggle={onToggle}
          onOpenLight={onOpenLight}
        />
      </div>
    </div>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/RoomCard.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/RoomCard.jsx <<'EOF'
import { useRef } from 'react';
import DeviceNode from './DeviceNode';
import { defaultPos } from '../utils/layout';

const ACTIVE_STATES = ['on', 'playing', 'open', 'unlocked'];

export default function RoomCard({
  room,
  states,
  history,
  positions,
  editMode,
  onMove,
  onToggle,
  onOpenLight,
  onOpenDeviceSettings,
  onOpenRoomSettings,
  onReorder,
}) {
  const cardRef = useRef(null);
  const movedRef = useRef(false);
  const visibleDevices = room.devices.filter((d) => !d.hidden);

  const activeCount = visibleDevices.filter((d) => {
    const s = states[d.entity_id];
    return s && ACTIVE_STATES.includes(s.state);
  }).length;

  const startDrag = (e, entityId) => {
    if (!editMode) return;
    e.preventDefault();
    movedRef.current = false;
    const startX = e.clientX;
    const startY = e.clientY;
    const rect = cardRef.current.getBoundingClientRect();
    const move = (ev) => {
      if (!movedRef.current && Math.abs(ev.clientX - startX) + Math.abs(ev.clientY - startY) < 5) {
        return;
      }
      movedRef.current = true;
      onMove(entityId, {
        x: Math.min(94, Math.max(6, ((ev.clientX - rect.left) / rect.width) * 100)),
        y: Math.min(92, Math.max(10, ((ev.clientY - rect.top) / rect.height) * 100)),
      });
    };
    const stop = () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', stop);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', stop);
  };

  return (
    <div
      ref={cardRef}
      className={`room-card relative aspect-square rounded-2xl border bg-gradient-to-br from-slate-900 to-slate-800/90
        ${
          activeCount > 0
            ? 'border-amber-500/30 shadow-[0_0_45px_-12px_rgba(251,191,36,0.35)]'
            : 'border-slate-700/60 shadow-[0_25px_50px_-20px_rgba(0,0,0,0.8)]'
        }
        ${editMode ? 'outline-dashed outline-1 outline-slate-500/60' : ''}`}
    >
      <div
        className="pointer-events-none absolute inset-0 overflow-hidden rounded-2xl"
        style={{
          backgroundImage:
            'linear-gradient(rgba(148,163,184,0.07) 1px, transparent 1px), linear-gradient(90deg, rgba(148,163,184,0.07) 1px, transparent 1px)',
          backgroundSize: '28px 28px',
        }}
      />
      <div className="absolute left-3 right-3 top-3 z-20 flex items-baseline justify-between gap-2">
        <button
          type="button"
          onClick={() => editMode && onOpenRoomSettings(room.area_id)}
          className={`truncate text-sm font-medium text-slate-100 ${
            editMode
              ? 'cursor-pointer underline decoration-dotted underline-offset-4 hover:text-amber-300'
              : 'pointer-events-none'
          }`}
        >
          {room.name}
        </button>
        <span className="pointer-events-none shrink-0 text-[10px] text-slate-400">
          {visibleDevices.length} device{visibleDevices.length === 1 ? '' : 's'}
        </span>
      </div>
      {editMode && (
        <div className="absolute bottom-2 right-2 z-20 flex gap-1">
          <button
            type="button"
            onClick={() => onReorder(room.area_id, -1)}
            className="h-6 w-6 rounded bg-slate-800/90 text-xs text-slate-300 ring-1 ring-slate-600/60 hover:bg-slate-700"
            aria-label="Move room earlier"
          >
            ‹
          </button>
          <button
            type="button"
            onClick={() => onReorder(room.area_id, 1)}
            className="h-6 w-6 rounded bg-slate-800/90 text-xs text-slate-300 ring-1 ring-slate-600/60 hover:bg-slate-700"
            aria-label="Move room later"
          >
            ›
          </button>
        </div>
      )}
      {visibleDevices.map((device, i) => {
        const saved = positions[device.entity_id];
        const pos =
          saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)
            ? { x: saved.x, y: saved.y }
            : defaultPos(i, visibleDevices.length);
        return (
          <DeviceNode
            key={device.entity_id}
            device={device}
            state={states[device.entity_id]}
            history={history[device.entity_id]}
            pos={pos}
            editMode={editMode}
            onDragStart={(e) => startDrag(e, device.entity_id)}
            onEditClick={() => {
              if (!movedRef.current) onOpenDeviceSettings(device.entity_id);
            }}
            onToggle={() => onToggle(device.entity_id)}
            onOpenLight={() => onOpenLight(device.entity_id)}
          />
        );
      })}
      {editMode && visibleDevices.length === 0 && (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center text-[11px] text-slate-600">
          Empty room
        </div>
      )}
    </div>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/App.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/App.jsx <<'EOF'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import useHearthSocket from './hooks/useHearthSocket';
import RoomCard from './components/RoomCard';
import Scene3D from './components/Scene3D';
import LightPanel from './components/LightPanel';
import DevicePanel from './components/DevicePanel';
import RoomPanel from './components/RoomPanel';
import HiddenPanel from './components/HiddenPanel';
import ScenePanel from './components/ScenePanel';

const LAYOUT_KEY = 'hearth3d-layout';
const EMPTY_CONFIG = { devices: {}, rooms: {}, roomOrder: [], floors: [], settings: {} };

function normalizeConfig(raw) {
  if (!raw || typeof raw !== 'object') return { ...EMPTY_CONFIG };
  if (!raw.devices && !raw.rooms && !raw.roomOrder && !raw.floors && !raw.settings) {
    // Legacy flat format: { entity_id: { x, y } }
    return { ...EMPTY_CONFIG, devices: raw };
  }
  return {
    devices: raw.devices || {},
    rooms: raw.rooms || {},
    roomOrder: raw.roomOrder || [],
    floors: raw.floors || [],
    settings: raw.settings || {},
  };
}

function loadLocalConfig() {
  try {
    return normalizeConfig(JSON.parse(localStorage.getItem(LAYOUT_KEY)));
  } catch {
    return { ...EMPTY_CONFIG };
  }
}

function configHasData(c) {
  return (
    Object.keys(c.devices).length > 0 ||
    Object.keys(c.rooms).length > 0 ||
    c.roomOrder.length > 0 ||
    c.floors.length > 0 ||
    Object.keys(c.settings || {}).length > 0
  );
}

export default function App() {
  const {
    rooms,
    floors: haFloors,
    states,
    history,
    serverConfig,
    haConnected,
    wsConnected,
    toggle,
    lightSet,
    sendConfig,
  } = useHearthSocket();
  // ?edit in the URL opens the dashboard in edit mode (handy for docs/tests).
  const [editMode, setEditMode] = useState(() => new URLSearchParams(window.location.search).has('edit'));
  const [config, setConfig] = useState(loadLocalConfig);
  const [activeFloor, setActiveFloor] = useState('all');
  const [sheet, setSheet] = useState(null); // { type: 'light'|'device'|'room'|'hidden', id? }
  const [newFloorName, setNewFloorName] = useState(null); // null = closed, string = input open
  const dirtyRef = useRef(false);
  const syncedRef = useRef(false);

  // Adopt the server-persisted config (shared across browsers). On first
  // contact with an empty server, migrate this browser's local copy up.
  useEffect(() => {
    if (serverConfig == null) return;
    const server = normalizeConfig(serverConfig);
    if (configHasData(server)) {
      setConfig(server);
    } else if (!syncedRef.current) {
      setConfig((local) => {
        if (configHasData(local)) sendConfig(local);
        return local;
      });
    }
    syncedRef.current = true;
  }, [serverConfig, sendConfig]);

  // Persist locally always; push to the server only for changes made here
  // (server-applied updates must not echo back, or two browsers ping-pong).
  useEffect(() => {
    const timer = setTimeout(() => {
      localStorage.setItem(LAYOUT_KEY, JSON.stringify(config));
      if (dirtyRef.current) {
        dirtyRef.current = false;
        sendConfig(config);
      }
    }, 300);
    return () => clearTimeout(timer);
  }, [config, sendConfig]);

  useEffect(() => setSheet(null), [editMode]);

  const update = useCallback((fn) => {
    dirtyRef.current = true;
    setConfig((prev) => fn(prev));
  }, []);

  // Merges a patch into an override map entry; empty-string/false/undefined
  // values delete the key so cleared overrides fall back to HA data.
  const patchOverride = (map, id, patch) => {
    const cur = { ...(map[id] || {}), ...patch };
    for (const k of Object.keys(cur)) {
      if (cur[k] === undefined || cur[k] === '' || cur[k] === false) delete cur[k];
    }
    const next = { ...map };
    if (Object.keys(cur).length > 0) next[id] = cur;
    else delete next[id];
    return next;
  };

  const setDeviceOverride = useCallback(
    (entityId, patch) => update((prev) => ({ ...prev, devices: patchOverride(prev.devices, entityId, patch) })),
    [update]
  );
  const setRoomOverride = useCallback(
    (areaId, patch) => update((prev) => ({ ...prev, rooms: patchOverride(prev.rooms, areaId, patch) })),
    [update]
  );
  const moveDevice = useCallback((entityId, pos) => setDeviceOverride(entityId, pos), [setDeviceOverride]);

  const resetConfig = () => {
    if (!window.confirm('Reset all customizations (positions, renames, hidden items, floors, background)?')) return;
    update(() => ({ devices: {}, rooms: {}, roomOrder: [], floors: [], settings: {} }));
  };

  const sceneThemeId = config.settings.background || 'midnight';
  const setBackground = (id) =>
    update((prev) => ({ ...prev, settings: { ...prev.settings, background: id } }));

  // ---- derived data ----

  const allFloors = useMemo(() => {
    const list = haFloors.map((f) => ({ id: f.floor_id, name: f.name, custom: false }));
    for (const f of config.floors) list.push({ id: f.id, name: f.name, custom: true });
    return list;
  }, [haFloors, config.floors]);

  const mergedRooms = useMemo(() => {
    const byId = new Map();
    for (const room of rooms) {
      const o = config.rooms[room.area_id] || {};
      byId.set(room.area_id, {
        ...room,
        name: o.name || room.name,
        ha_floor: room.floor_id || null,
        floor_id: o.floor === '_none' ? null : o.floor || room.floor_id || null,
        hidden: !!o.hidden,
        devices: [],
      });
    }
    for (const room of rooms) {
      for (const device of room.devices) {
        const o = config.devices[device.entity_id] || {};
        const target = o.room && byId.has(o.room) ? o.room : room.area_id;
        byId.get(target).devices.push({
          ...device,
          name: o.name || device.name,
          hidden: !!o.hidden,
          home: room.area_id,
        });
      }
    }
    return [...byId.values()];
  }, [rooms, config.rooms, config.devices]);

  const orderedRooms = useMemo(() => {
    const idx = new Map(config.roomOrder.map((id, i) => [id, i]));
    return [...mergedRooms].sort((a, b) => {
      const ai = idx.has(a.area_id) ? idx.get(a.area_id) : Infinity;
      const bi = idx.has(b.area_id) ? idx.get(b.area_id) : Infinity;
      if (ai !== bi) return ai - bi;
      return a.name.localeCompare(b.name);
    });
  }, [mergedRooms, config.roomOrder]);

  const hasFloors = allFloors.length > 0;
  const hasFloorless = orderedRooms.some((r) => !r.hidden && !r.floor_id);

  const visibleRooms = useMemo(
    () =>
      orderedRooms.filter((room) => {
        if (room.hidden) return false;
        if (!editMode && room.devices.filter((d) => !d.hidden).length === 0) return false;
        if (hasFloors && activeFloor !== 'all') {
          if (activeFloor === '_none') return !room.floor_id;
          return room.floor_id === activeFloor;
        }
        return true;
      }),
    [orderedRooms, editMode, hasFloors, activeFloor]
  );

  // Rooms grouped by floor for the 3D scene: "All floors" stacks each floor
  // as its own storey; a specific floor renders as a single ground level.
  const sceneLevels = useMemo(() => {
    if (!hasFloors || activeFloor !== 'all') {
      return [{ id: activeFloor || 'all', name: null, rooms: visibleRooms }];
    }
    const buckets = allFloors.map((floor) => ({
      id: floor.id,
      name: floor.name,
      rooms: visibleRooms.filter((room) => room.floor_id === floor.id),
    }));
    const floorless = visibleRooms.filter((room) => !room.floor_id);
    if (floorless.length > 0) buckets.push({ id: '_none', name: 'Other', rooms: floorless });
    return buckets.filter((bucket) => bucket.rooms.length > 0);
  }, [visibleRooms, allFloors, hasFloors, activeFloor]);

  const hiddenRooms = orderedRooms.filter((r) => r.hidden);
  const hiddenDevices = useMemo(() => {
    const list = [];
    for (const room of mergedRooms) {
      for (const d of room.devices) if (d.hidden) list.push({ ...d, roomName: room.name });
    }
    return list;
  }, [mergedRooms]);
  const hiddenCount = hiddenRooms.length + hiddenDevices.length;

  const [sheetDevice, sheetRoomId] = useMemo(() => {
    if (!sheet || (sheet.type !== 'light' && sheet.type !== 'device')) return [null, null];
    for (const room of mergedRooms) {
      for (const d of room.devices) if (d.entity_id === sheet.id) return [d, room.area_id];
    }
    return [null, null];
  }, [sheet, mergedRooms]);
  const sheetRoom =
    sheet && sheet.type === 'room' ? mergedRooms.find((r) => r.area_id === sheet.id) : null;

  // ---- actions ----

  const reorderRoom = (areaId, dir) => {
    const visibleIds = visibleRooms.map((r) => r.area_id);
    const vi = visibleIds.indexOf(areaId);
    const targetId = visibleIds[vi + dir];
    if (!targetId) return;
    const ids = orderedRooms.map((r) => r.area_id);
    const i = ids.indexOf(areaId);
    const j = ids.indexOf(targetId);
    [ids[i], ids[j]] = [ids[j], ids[i]];
    update((prev) => ({ ...prev, roomOrder: ids }));
  };

  const addFloor = (name) => {
    const clean = name.trim();
    if (!clean) return;
    const id = `custom-${Date.now().toString(36)}`;
    update((prev) => ({ ...prev, floors: [...prev.floors, { id, name: clean }] }));
    setActiveFloor(id);
  };

  const removeFloor = (id) => {
    update((prev) => {
      const roomsCfg = { ...prev.rooms };
      for (const [rid, o] of Object.entries(roomsCfg)) {
        if (o.floor === id) {
          const { floor, ...rest } = o;
          if (Object.keys(rest).length > 0) roomsCfg[rid] = rest;
          else delete roomsCfg[rid];
        }
      }
      return { ...prev, rooms: roomsCfg, floors: prev.floors.filter((f) => f.id !== id) };
    });
    if (activeFloor === id) setActiveFloor('all');
  };

  const floorTabs = [
    { id: 'all', name: 'All floors', custom: false },
    ...allFloors,
    ...(hasFloorless && hasFloors ? [{ id: '_none', name: 'Other', custom: false }] : []),
  ];

  // Column count for the flat edit-mode plan (roughly square reads best).
  const gridCols = Math.min(4, Math.max(2, Math.ceil(Math.sqrt(visibleRooms.length || 1))));

  return (
    <div className="flex h-screen flex-col">
      <header className="sticky top-0 z-20 flex items-center justify-between border-b border-slate-800/80 bg-slate-950/80 px-6 py-4 backdrop-blur">
        <div className="flex items-center gap-3">
          <span className="text-2xl">🏠</span>
          <h1 className="text-lg font-semibold tracking-wide">Hearth3D</h1>
          <span
            className={`ml-2 inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs ${
              haConnected ? 'bg-emerald-500/10 text-emerald-400' : 'bg-red-500/10 text-red-400'
            }`}
          >
            <span
              className={`h-1.5 w-1.5 rounded-full ${haConnected ? 'bg-emerald-400' : 'bg-red-400'}`}
            />
            {haConnected ? 'Home Assistant connected' : 'Home Assistant offline'}
          </span>
        </div>
        <div className="flex items-center gap-2">
          {!editMode && (
            <button
              type="button"
              onClick={() => setSheet({ type: 'scene' })}
              className="rounded-lg border border-slate-700 px-3 py-1.5 text-xs text-slate-300 hover:bg-slate-800"
            >
              Scene
            </button>
          )}
          {editMode && (
            <>
              <button
                type="button"
                onClick={() => setSheet({ type: 'hidden' })}
                className="rounded-lg border border-slate-700 px-3 py-1.5 text-xs text-slate-300 hover:bg-slate-800"
              >
                Hidden ({hiddenCount})
              </button>
              <button
                type="button"
                onClick={resetConfig}
                className="rounded-lg border border-slate-700 px-3 py-1.5 text-xs text-slate-300 hover:bg-slate-800"
              >
                Reset all
              </button>
            </>
          )}
          <button
            type="button"
            onClick={() => setEditMode((v) => !v)}
            className={`rounded-lg border px-3 py-1.5 text-xs ${
              editMode
                ? 'border-amber-500/60 bg-amber-500/20 text-amber-300'
                : 'border-slate-700 text-slate-300 hover:bg-slate-800'
            }`}
          >
            {editMode ? 'Done editing' : 'Edit layout'}
          </button>
        </div>
      </header>

      {(hasFloors || editMode) && (
        <div className="flex flex-wrap items-center justify-center gap-2 border-b border-slate-800/60 bg-slate-950/50 px-6 py-2">
          {floorTabs.map((tab) => (
            <span key={tab.id} className="inline-flex items-center">
              <button
                type="button"
                onClick={() => setActiveFloor(tab.id)}
                className={`rounded-full px-3 py-1 text-xs transition-colors ${
                  activeFloor === tab.id
                    ? 'bg-sky-500/20 text-sky-300 ring-1 ring-sky-500/50'
                    : 'text-slate-400 hover:bg-slate-800 hover:text-slate-200'
                }`}
              >
                {tab.name}
              </button>
              {editMode && tab.custom && (
                <button
                  type="button"
                  onClick={() => removeFloor(tab.id)}
                  className="ml-0.5 rounded px-1 text-xs text-slate-600 hover:text-red-400"
                  aria-label={`Delete floor ${tab.name}`}
                >
                  ✕
                </button>
              )}
            </span>
          ))}
          {editMode &&
            (newFloorName === null ? (
              <button
                type="button"
                onClick={() => setNewFloorName('')}
                className="rounded-full border border-dashed border-slate-600 px-3 py-1 text-xs text-slate-400 hover:border-slate-400 hover:text-slate-200"
              >
                + Floor
              </button>
            ) : (
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  addFloor(newFloorName);
                  setNewFloorName(null);
                }}
              >
                <input
                  autoFocus
                  value={newFloorName}
                  onChange={(e) => setNewFloorName(e.target.value)}
                  onBlur={() => setNewFloorName(null)}
                  placeholder="Floor name…"
                  className="w-28 rounded-full border border-slate-600 bg-slate-800/80 px-3 py-1 text-xs text-slate-100 outline-none focus:border-sky-500/60"
                />
              </form>
            ))}
        </div>
      )}

      {!wsConnected && (
        <div className="border-b border-red-500/20 bg-red-500/10 px-6 py-2 text-center text-xs text-red-300">
          Connection to Hearth3D server lost — reconnecting…
        </div>
      )}
      {wsConnected && !haConnected && (
        <div className="border-b border-amber-500/20 bg-amber-500/10 px-6 py-2 text-center text-xs text-amber-300">
          Waiting for Home Assistant connection…
        </div>
      )}
      {editMode && (
        <div className="border-b border-sky-500/20 bg-sky-500/10 px-6 py-2 text-center text-xs text-sky-300">
          Edit mode — drag devices to reposition · click a device to rename, move, or hide it ·
          click a room name to rename it or change its floor · use ‹ › to reorder rooms. Changes
          save automatically for everyone.
        </div>
      )}

      <main className={`relative flex-1 ${editMode ? 'overflow-y-auto' : 'overflow-hidden'}`}>
        {visibleRooms.length === 0 ? (
          <div className="flex h-full items-center justify-center px-6 text-center text-slate-500">
            <div>
              <div className="mb-3 animate-pulse text-4xl">🏠</div>
              <p className="text-sm">
                {haConnected
                  ? 'No rooms to show. Assign devices to areas in Home Assistant, or check the Hidden panel in edit mode.'
                  : 'Waiting for room and device topology…'}
              </p>
            </div>
          </div>
        ) : editMode ? (
          <div className="flex justify-center px-6 py-10">
            <div
              className="grid w-full gap-8"
              style={{
                gridTemplateColumns: `repeat(${gridCols}, minmax(0, 1fr))`,
                maxWidth: `min(92vw, ${gridCols * 420}px)`,
              }}
            >
              {visibleRooms.map((room) => (
                <RoomCard
                  key={room.area_id}
                  room={room}
                  states={states}
                  history={history}
                  positions={config.devices}
                  editMode={editMode}
                  onMove={moveDevice}
                  onToggle={toggle}
                  onOpenLight={(id) => setSheet({ type: 'light', id })}
                  onOpenDeviceSettings={(id) => setSheet({ type: 'device', id })}
                  onOpenRoomSettings={(id) => setSheet({ type: 'room', id })}
                  onReorder={reorderRoom}
                />
              ))}
            </div>
          </div>
        ) : (
          <>
            <Scene3D
              levels={sceneLevels}
              themeId={sceneThemeId}
              states={states}
              history={history}
              positions={config.devices}
              onToggle={toggle}
              onOpenLight={(id) => setSheet({ type: 'light', id })}
            />
            <div className="pointer-events-none absolute bottom-3 right-4 z-10 text-[11px] text-slate-500">
              Drag to orbit · scroll to zoom · click a device to toggle · hold a light for controls
            </div>
          </>
        )}
      </main>

      {sheet && sheet.type === 'light' && sheetDevice && (
        <LightPanel
          key={sheet.id}
          device={sheetDevice}
          state={states[sheetDevice.entity_id]}
          onClose={() => setSheet(null)}
          onToggle={() => toggle(sheetDevice.entity_id)}
          onSet={(payload) => lightSet(sheetDevice.entity_id, payload)}
        />
      )}
      {sheet && sheet.type === 'device' && sheetDevice && (
        <DevicePanel
          key={sheet.id}
          device={sheetDevice}
          roomId={sheetRoomId}
          rooms={orderedRooms.filter((r) => !r.hidden)}
          onClose={() => setSheet(null)}
          onApply={(patch) => setDeviceOverride(sheetDevice.entity_id, patch)}
          onHide={() => {
            setDeviceOverride(sheetDevice.entity_id, { hidden: true });
            setSheet(null);
          }}
        />
      )}
      {sheet && sheet.type === 'room' && sheetRoom && (
        <RoomPanel
          key={sheet.id}
          room={sheetRoom}
          floors={allFloors}
          onClose={() => setSheet(null)}
          onApply={(patch) => setRoomOverride(sheetRoom.area_id, patch)}
          onHide={() => {
            setRoomOverride(sheetRoom.area_id, { hidden: true });
            setSheet(null);
          }}
        />
      )}
      {sheet && sheet.type === 'hidden' && (
        <HiddenPanel
          hiddenRooms={hiddenRooms}
          hiddenDevices={hiddenDevices}
          onShowRoom={(id) => setRoomOverride(id, { hidden: false })}
          onShowDevice={(id) => setDeviceOverride(id, { hidden: false })}
          onClose={() => setSheet(null)}
        />
      )}
      {sheet && sheet.type === 'scene' && (
        <ScenePanel current={sceneThemeId} onPick={setBackground} onClose={() => setSheet(null)} />
      )}
    </div>
  );
}
EOF

# ---------------------------------------------------------------------------
# Dockerfile (multi-stage)
# ---------------------------------------------------------------------------
cat > Dockerfile <<'EOF'
# ---------- Stage 1: build the React frontend ----------
FROM node:20-alpine AS frontend-build
WORKDIR /build
COPY frontend/package.json ./
RUN npm install --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

# ---------- Stage 2: Node.js runtime serving API + static assets ----------
FROM node:20-alpine
ENV NODE_ENV=production
ENV DATA_DIR=/data
WORKDIR /app
COPY server/package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server/server.js ./
COPY --from=frontend-build /build/dist ./public
RUN mkdir -p /data && chown node:node /data
EXPOSE 8080
USER node
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -qO- http://127.0.0.1:8080/health >/dev/null 2>&1 || exit 1
CMD ["node", "server.js"]
EOF

# ---------------------------------------------------------------------------
# docker-compose.yml
# ---------------------------------------------------------------------------
cat > docker-compose.yml <<'EOF'
services:
  hearth3d:
    build: .
    image: hearth3d:latest
    container_name: hearth3d
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      HA_URL: ${HA_URL:-http://homeassistant.local:8123}
      HA_TOKEN: ${HA_TOKEN:?Set HA_TOKEN in a .env file next to docker-compose.yml}
    volumes:
      # Shared dashboard customization (positions, renames, hidden items,
      # floors, room order) survives container rebuilds here.
      - hearth3d-data:/data
    # NOTE: mDNS names like `homeassistant.local` usually do NOT resolve inside
    # a container. Prefer setting HA_URL in .env to your Home Assistant host's
    # IP address (e.g. http://192.168.1.50:8123). On Linux you can instead
    # uncomment host networking below and remove the `ports:` section:
    # network_mode: host

volumes:
  hearth3d-data:
EOF

# ---------------------------------------------------------------------------
# .env.example
# ---------------------------------------------------------------------------
cat > .env.example <<'EOF'
# URL of your Home Assistant instance.
# IMPORTANT: mDNS names like homeassistant.local usually do not resolve inside
# Docker containers — use the IP address of your Home Assistant host instead.
HA_URL=http://192.168.1.50:8123

# Long-Lived Access Token.
# Create one in Home Assistant: your profile (bottom-left) -> Security ->
# Long-lived access tokens -> Create token.
HA_TOKEN=

# Optional: comma-separated entity domains to show on the dashboard.
# Add `sensor` to get live sparkline charts for numeric sensors.
# DOMAINS=light,switch,media_player,fan,cover,lock,climate,vacuum,camera
EOF

# ---------------------------------------------------------------------------
# .dockerignore / .gitignore
# ---------------------------------------------------------------------------
cat > .dockerignore <<'EOF'
**/node_modules
**/dist
.git
.env
*.md
EOF

cat > .gitignore <<'EOF'
node_modules/
dist/
.env
data/
EOF

# ---------------------------------------------------------------------------
# README.md
# ---------------------------------------------------------------------------
cat > README.md <<'EOF'
# Hearth3D

A self-contained, real-time 3D dashboard for Home Assistant. Rooms are
discovered automatically from your Home Assistant areas and rendered as a
live Three.js scene — orbit the camera, watch lit bulbs cast real light into
their rooms — with devices placed by area assignment, updating live, and
controllable with a click. Everything about the view — positions, names, rooms,
floors, visibility — can be customized in edit mode, and the customization is
stored server-side so every browser sees the same dashboard.

```
Browser ◄── WebSocket (port 8080) ──► Node.js backend ◄── HA WebSocket API ──► Home Assistant
   ▲                                        │
   └───────── static React frontend ◄──────┘
```

## Quick start

1. Create a Long-Lived Access Token in Home Assistant:
   your profile (bottom-left avatar) → **Security** → **Long-lived access
   tokens** → **Create token**.

2. Configure the environment:

   ```sh
   cp .env.example .env
   # edit .env: set HA_URL and HA_TOKEN
   ```

   > **Important:** use your Home Assistant host's IP address in `HA_URL`
   > (e.g. `http://192.168.1.50:8123`). mDNS names like
   > `homeassistant.local` usually do not resolve inside Docker containers.
   > On Linux you can alternatively enable `network_mode: host` in
   > `docker-compose.yml`.

3. Build and run:

   ```sh
   docker compose up --build     # or: docker-compose up --build
   ```

4. Open <http://localhost:8080> (or `http://<docker-host-ip>:8080` from
   another machine on your LAN).

## Using the dashboard

### Everyday control

- **Orbit the home** — drag to rotate, scroll to zoom. The camera slowly
  auto-rotates until you grab it. (If WebGL is unavailable the app falls back
  to a notice; the 2D edit-mode plan always works.)
- **Stacked storeys** — the *All floors* tab renders each floor as its own
  level, stacked like a real multi-storey house with floor name plates.
  Selecting a single floor lays it out flat.
- **Scene backgrounds** — the **Scene** button in the header offers eight
  backdrops (Midnight, Starfield, Synthwave, Aurora, Ember, Snowfall, Matrix,
  Void). The choice is saved server-side and shared with every browser.
- **Toggle a device** — click a light, switch, fan, media player, cover, or
  lock. Active devices glow in their domain color, and lit bulbs cast real
  light into their room.
- **Dim / recolor a light** — long-press (or right-click) a light to open its
  control panel with a brightness slider and color picker.
- **Floors** — if your Home Assistant areas are assigned to floors (or you
  created custom floors in edit mode), tabs above the floor plan filter rooms
  by floor.
- **Cameras** — camera entities render a live snapshot tile (refreshed every
  10 s, proxied through the backend so the HA token never reaches the
  browser).
- **Sensors** — add `sensor` to the `DOMAINS` environment variable and
  numeric sensors show their value plus a live sparkline.

### Customization (edit mode)

Click **Edit layout** in the header. The view flattens to a top-down plan and
everything becomes editable:

| What | How |
|---|---|
| Move a device on its card | Drag it |
| Rename a device / move it to another room / hide it | Click the device |
| Rename a room / change its floor / hide it | Click the room name |
| Reorder rooms | ‹ › buttons on each card |
| Create or delete custom floors | **+ Floor** button / ✕ on a custom floor tab |
| Restore hidden rooms & devices | **Hidden (n)** button in the header |
| Start over | **Reset all** |

All customization is stored on the server (in the `hearth3d-data` Docker
volume) and shared by every browser. Renames and layout changes are pure
overlays — nothing is ever written back to Home Assistant, and clearing a
field restores the Home Assistant original. Rooms and devices update
automatically when you rename areas or reassign devices in Home Assistant.

## Configuration

All configuration is via environment variables (set them in `.env`):

| Variable   | Default                            | Description                                    |
|------------|------------------------------------|------------------------------------------------|
| `HA_URL`   | `http://homeassistant.local:8123`  | Base URL of Home Assistant                     |
| `HA_TOKEN` | *(required)*                       | Long-lived access token                        |
| `PORT`     | `8080`                             | Dashboard HTTP/WebSocket port                  |
| `DOMAINS`  | `light,switch,media_player,fan,cover,lock,climate,vacuum,camera` | Entity domains to display |
| `DATA_DIR` | `/data` (in Docker)                | Where the shared layout/customization is saved |

The backend also runs unmodified inside a Home Assistant add-on sandbox: when
`SUPERVISOR_TOKEN` is present and `HA_URL` is not set, it talks to
`ws://supervisor/core/websocket` automatically.

## Local development (without Docker)

```sh
# Terminal 1 — backend
cd server && npm install
HA_URL=http://192.168.1.50:8123 HA_TOKEN=... node server.js

# Terminal 2 — frontend with hot reload (proxies /ws and /api to the backend)
cd frontend && npm install
npm run dev
```

## Troubleshooting

- **`auth_invalid` in the logs** — the token is wrong or was revoked. Create a
  new one.
- **`HA connection closed; retrying…` forever** — the container cannot reach
  `HA_URL`. Use the IP address, verify port 8123, and check firewalls.
- **Dashboard is empty** — your entities have no areas. Assign devices to
  areas in Home Assistant (Settings → Devices & services → Devices). Also
  check the **Hidden** panel in edit mode.
- **Only some devices appear** — only domains in `DOMAINS` are shown, and
  disabled/hidden entities are skipped.
- **Camera tiles show the camera icon instead of an image** — the backend
  could not fetch `/api/camera_proxy` from Home Assistant; check the logs.

## Security notes

- The HA token stays server-side; the browser never sees it (camera snapshots
  are proxied).
- The dashboard itself has **no authentication** — anyone on your LAN who can
  reach port 8080 can view and control the exposed devices. Do not
  port-forward it to the internet; put it behind a reverse proxy with auth if
  you need remote access.
- Browser clients can only toggle displayed entities and adjust light
  brightness/color; arbitrary Home Assistant service calls are not relayed.
EOF

echo ""
echo "✓ Hearth3D project created in ./$PROJECT_DIR"
echo ""
cat <<'NEXT'
Next steps:
  1. cd into the project directory
  2. cp .env.example .env
  3. Edit .env — set HA_URL (use your HA host's IP address!) and HA_TOKEN
  4. docker compose up --build
  5. Open http://localhost:8080
NEXT

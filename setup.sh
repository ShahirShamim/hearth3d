#!/usr/bin/env bash
#
# setup.sh — scaffolds the complete Hearth3D project.
#
# Hearth3D is a self-contained, Dockerized dashboard for Home Assistant:
#   * Node.js backend that mirrors the HA area/device/entity registries and
#     streams live state changes to the browser over WebSocket.
#   * React + Tailwind frontend rendering a dark-mode isometric floor plan,
#     with click-to-toggle devices and a drag-to-arrange edit mode.
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
         "$PROJECT_DIR/frontend/src/hooks"
cd "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# Backend: server/package.json
# ---------------------------------------------------------------------------
cat > server/package.json <<'EOF'
{
  "name": "hearth3d-server",
  "private": true,
  "version": "1.0.0",
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
 * Connects to the Home Assistant WebSocket API, mirrors the area/device/entity
 * registries into a room -> devices topology, streams state changes to browser
 * clients over a local WebSocket (path /ws on the same port), and relays
 * toggle commands back to Home Assistant. Also serves the built React
 * frontend from ./public.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');

const HA_URL = (process.env.HA_URL || 'http://homeassistant.local:8123').replace(/\/+$/, '');
const HA_TOKEN = process.env.HA_TOKEN || '';
const PORT = parseInt(process.env.PORT || '8080', 10);
const PUBLIC_DIR = path.join(__dirname, 'public');

// Entity domains shown on the dashboard. Override with e.g.
// DOMAINS=light,switch,sensor in the environment.
const DISPLAY_DOMAINS = (process.env.DOMAINS || 'light,switch,media_player,fan,cover,lock,climate,vacuum')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

if (!HA_TOKEN) {
  console.error('[hearth3d] FATAL: HA_TOKEN is not set. Create a long-lived access token in');
  console.error('[hearth3d] Home Assistant (Profile -> Security) and set it in your .env file.');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

const registry = { areas: [], devices: [], entities: [] };
const states = new Map(); // entity_id -> { state, attributes, last_changed }
let topology = []; // [{ area_id, name, devices: [{ entity_id, domain, name }] }]
let displayedEntities = new Set();
let registryRefreshTimer = null;

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

function rebuildTopology() {
  const deviceById = new Map(registry.devices.map((d) => [d.id, d]));
  const rooms = new Map();
  for (const area of registry.areas) {
    rooms.set(area.area_id, { area_id: area.area_id, name: area.name, devices: [] });
  }
  const unassigned = { area_id: '_unassigned', name: 'Unassigned', devices: [] };

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

  topology = [...rooms.values()]
    .filter((room) => room.devices.length > 0)
    .sort((a, b) => a.name.localeCompare(b.name));
  displayedEntities = new Set(topology.flatMap((room) => room.devices.map((d) => d.entity_id)));
}

function topologyMessage() {
  const visibleStates = {};
  for (const entityId of displayedEntities) {
    const s = states.get(entityId);
    if (s) visibleStates[entityId] = s;
  }
  return { type: 'topology', rooms: topology, states: visibleStates };
}

// ---------------------------------------------------------------------------
// Home Assistant connection
// ---------------------------------------------------------------------------

class HomeAssistant {
  constructor(baseUrl, token) {
    this.wsUrl = baseUrl.replace(/^http/, 'ws') + '/api/websocket';
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

  async bootstrap() {
    const [areas, devices, entities, allStates] = await Promise.all([
      this.send({ type: 'config/area_registry/list' }),
      this.send({ type: 'config/device_registry/list' }),
      this.send({ type: 'config/entity_registry/list' }),
      this.send({ type: 'get_states' }),
    ]);
    registry.areas = areas;
    registry.devices = devices;
    registry.entities = entities;
    states.clear();
    for (const s of allStates) states.set(s.entity_id, pickState(s));
    rebuildTopology();

    await this.send({ type: 'subscribe_events', event_type: 'state_changed' });
    for (const eventType of [
      'area_registry_updated',
      'device_registry_updated',
      'entity_registry_updated',
    ]) {
      await this.send({ type: 'subscribe_events', event_type: eventType });
    }

    console.log(
      `[hearth3d] Topology ready: ${topology.length} rooms, ${displayedEntities.size} devices`
    );
    broadcast({ type: 'ha_status', connected: true });
    broadcast(topologyMessage());
  }

  async refreshRegistries() {
    const [areas, devices, entities] = await Promise.all([
      this.send({ type: 'config/area_registry/list' }),
      this.send({ type: 'config/device_registry/list' }),
      this.send({ type: 'config/entity_registry/list' }),
    ]);
    registry.areas = areas;
    registry.devices = devices;
    registry.entities = entities;
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
// HTTP server (static frontend + health) and browser-facing WebSocket
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
  if (topology.length > 0) client.send(JSON.stringify(topologyMessage()));

  client.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    handleClientMessage(msg);
  });
});

function handleClientMessage(msg) {
  if (msg.type !== 'toggle' || typeof msg.entity_id !== 'string') return;
  // Only allow commands for entities we actually expose on the dashboard.
  if (!displayedEntities.has(msg.entity_id)) return;

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
  }).catch((err) => console.error(`[hearth3d] call_service failed: ${err.message}`));
}

const ha = new HomeAssistant(HA_URL, HA_TOKEN);

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
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
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

body {
  @apply bg-slate-950 text-slate-100 antialiased;
  background-image: radial-gradient(circle at 20% 0%, rgba(56, 189, 248, 0.06), transparent 40%),
    radial-gradient(circle at 80% 100%, rgba(251, 191, 36, 0.05), transparent 40%);
}

/*
 * Isometric projection. The plane is tilted and rotated; device chips are
 * counter-rotated ("billboarded") so their icons and labels stay upright and
 * readable. Edit mode removes the tilt entirely (.flat) so pointer-based
 * dragging maps 1:1 to card coordinates.
 */
.iso-plane {
  transform: rotateX(55deg) rotateZ(45deg);
  transform-style: preserve-3d;
  transition: transform 0.7s cubic-bezier(0.33, 1, 0.68, 1);
}

.iso-plane.flat {
  transform: none;
}

.room-card,
.device-node {
  transform-style: preserve-3d;
}

.room-card {
  transition: transform 0.35s ease, box-shadow 0.35s ease;
}

.iso-plane:not(.flat) .room-card:hover {
  transform: translateZ(30px);
}

.device-billboard {
  transform: translate(-50%, -50%) rotateZ(-45deg) rotateX(-55deg);
  transition: transform 0.7s cubic-bezier(0.33, 1, 0.68, 1);
}

.flat .device-billboard {
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
 * Exposes the room topology, a live entity-state map, connection flags,
 * and a toggle(entityId) command sender. Reconnects with backoff.
 */
export default function useHearthSocket() {
  const [rooms, setRooms] = useState([]);
  const [states, setStates] = useState({});
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
          setStates(msg.states);
        } else if (msg.type === 'state') {
          setStates((prev) => ({
            ...prev,
            [msg.entity_id]: {
              state: msg.state,
              attributes: msg.attributes,
              last_changed: msg.last_changed,
            },
          }));
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

  const toggle = useCallback((entityId) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'toggle', entity_id: entityId }));
    }
  }, []);

  return { rooms, states, haConnected, wsConnected, toggle };
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/components/DeviceNode.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/components/DeviceNode.jsx <<'EOF'
const ICONS = {
  light: '💡',
  switch: '🔌',
  media_player: '🔊',
  fan: '🌀',
  cover: '🪟',
  lock: '🔒',
  climate: '🌡️',
  vacuum: '🤖',
  binary_sensor: '👁️',
  sensor: '📈',
};

const ACTIVE_STATES = [
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
  light: 'bg-amber-400/20 ring-amber-400/70 shadow-[0_0_24px_4px_rgba(251,191,36,0.45)]',
  switch: 'bg-emerald-400/20 ring-emerald-400/70 shadow-[0_0_20px_2px_rgba(52,211,153,0.4)]',
  media_player: 'bg-sky-400/20 ring-sky-400/70 shadow-[0_0_20px_2px_rgba(56,189,248,0.4)]',
  fan: 'bg-cyan-400/20 ring-cyan-400/70 shadow-[0_0_20px_2px_rgba(34,211,238,0.4)]',
  cover: 'bg-violet-400/20 ring-violet-400/70 shadow-[0_0_20px_2px_rgba(167,139,250,0.4)]',
  lock: 'bg-red-400/20 ring-red-400/70 shadow-[0_0_20px_2px_rgba(248,113,113,0.4)]',
  default: 'bg-emerald-400/20 ring-emerald-400/70 shadow-[0_0_20px_2px_rgba(52,211,153,0.4)]',
};

export default function DeviceNode({ device, state, pos, editMode, onDragStart, onToggle }) {
  const stateStr = state ? state.state : 'unknown';
  const isActive = ACTIVE_STATES.includes(stateStr);
  const canToggle = TOGGLABLE_DOMAINS.includes(device.domain);
  const icon = ICONS[device.domain] || '⚪';

  let detail = null;
  if (device.domain === 'sensor' && state) {
    const unit = state.attributes.unit_of_measurement;
    detail = `${state.state}${unit ? ` ${unit}` : ''}`;
  } else if (device.domain === 'climate' && state && state.attributes.current_temperature != null) {
    detail = `${state.attributes.current_temperature}°`;
  } else if (device.domain === 'media_player' && stateStr === 'playing' && state.attributes.media_title) {
    detail = state.attributes.media_title;
  }

  const handleClick = () => {
    if (editMode || !canToggle) return;
    onToggle();
  };

  return (
    <div className="device-node absolute z-10" style={{ left: `${pos.x}%`, top: `${pos.y}%` }}>
      <div className="device-billboard flex w-max max-w-[110px] flex-col items-center gap-1">
        <button
          type="button"
          onPointerDown={onDragStart}
          onClick={handleClick}
          title={`${device.name} — ${stateStr}`}
          className={`flex h-11 w-11 select-none items-center justify-center rounded-full text-lg ring-1 transition-all duration-300
            ${isActive ? ACTIVE_STYLES[device.domain] || ACTIVE_STYLES.default : 'bg-slate-800/90 ring-slate-600/60 opacity-80 grayscale'}
            ${editMode ? 'cursor-grab active:cursor-grabbing' : canToggle ? 'cursor-pointer hover:scale-110' : 'cursor-default'}`}
        >
          {icon}
        </button>
        <span className="pointer-events-none max-w-[100px] truncate rounded bg-slate-950/70 px-1.5 py-0.5 text-[10px] leading-tight text-slate-300">
          {device.name}
        </span>
        {detail && (
          <span className="pointer-events-none max-w-[100px] truncate text-[9px] text-slate-400">
            {detail}
          </span>
        )}
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

// Arranges devices without a saved position into a padded grid inside the card.
function defaultPos(index, count) {
  const cols = Math.max(1, Math.ceil(Math.sqrt(count)));
  const rows = Math.max(1, Math.ceil(count / cols));
  const col = index % cols;
  const row = Math.floor(index / cols);
  return {
    x: 14 + ((col + 0.5) / cols) * 72,
    y: 28 + ((row + 0.5) / rows) * 60,
  };
}

const ACTIVE_STATES = ['on', 'playing', 'open', 'unlocked'];

export default function RoomCard({ room, states, layout, editMode, onMove, onToggle }) {
  const cardRef = useRef(null);

  const activeCount = room.devices.filter((d) => {
    const s = states[d.entity_id];
    return s && ACTIVE_STATES.includes(s.state);
  }).length;

  const startDrag = (e, entityId) => {
    if (!editMode) return;
    e.preventDefault();
    const rect = cardRef.current.getBoundingClientRect();
    const move = (ev) => {
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
      <div className="pointer-events-none absolute left-3 right-3 top-3 flex items-baseline justify-between">
        <span className="truncate text-sm font-medium text-slate-200">{room.name}</span>
        <span className="text-[10px] text-slate-500">
          {room.devices.length} device{room.devices.length === 1 ? '' : 's'}
        </span>
      </div>
      {room.devices.map((device, i) => {
        const pos = layout[device.entity_id] || defaultPos(i, room.devices.length);
        return (
          <DeviceNode
            key={device.entity_id}
            device={device}
            state={states[device.entity_id]}
            pos={pos}
            editMode={editMode}
            onDragStart={(e) => startDrag(e, device.entity_id)}
            onToggle={() => onToggle(device.entity_id)}
          />
        );
      })}
    </div>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: frontend/src/App.jsx
# ---------------------------------------------------------------------------
cat > frontend/src/App.jsx <<'EOF'
import { useCallback, useEffect, useState } from 'react';
import useHearthSocket from './hooks/useHearthSocket';
import RoomCard from './components/RoomCard';

const LAYOUT_KEY = 'hearth3d-layout';

function loadLayout() {
  try {
    return JSON.parse(localStorage.getItem(LAYOUT_KEY)) || {};
  } catch {
    return {};
  }
}

export default function App() {
  const { rooms, states, haConnected, wsConnected, toggle } = useHearthSocket();
  const [editMode, setEditMode] = useState(false);
  const [layout, setLayout] = useState(loadLayout);

  // Persist the custom layout to local storage (debounced past drag events).
  useEffect(() => {
    const timer = setTimeout(() => localStorage.setItem(LAYOUT_KEY, JSON.stringify(layout)), 300);
    return () => clearTimeout(timer);
  }, [layout]);

  const moveDevice = useCallback((entityId, pos) => {
    setLayout((prev) => ({ ...prev, [entityId]: pos }));
  }, []);

  const resetLayout = () => {
    localStorage.removeItem(LAYOUT_KEY);
    setLayout({});
  };

  return (
    <div className="flex min-h-screen flex-col">
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
          {editMode && (
            <button
              type="button"
              onClick={resetLayout}
              className="rounded-lg border border-slate-700 px-3 py-1.5 text-xs text-slate-300 hover:bg-slate-800"
            >
              Reset layout
            </button>
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
          Edit mode: the view is flattened — drag devices to reposition them. Positions save
          automatically to this browser.
        </div>
      )}

      <main className="flex flex-1 justify-center px-6 py-20">
        {rooms.length === 0 ? (
          <div className="self-center text-center text-slate-500">
            <div className="mb-3 animate-pulse text-4xl">🏠</div>
            <p className="text-sm">
              {haConnected
                ? 'No rooms found. Assign your devices to areas in Home Assistant.'
                : 'Waiting for room and device topology…'}
            </p>
          </div>
        ) : (
          <div
            className={`iso-plane ${editMode ? 'flat' : ''} grid w-full max-w-6xl content-start gap-8`}
            style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(230px, 1fr))' }}
          >
            {rooms.map((room) => (
              <RoomCard
                key={room.area_id}
                room={room}
                states={states}
                layout={layout}
                editMode={editMode}
                onMove={moveDevice}
                onToggle={toggle}
              />
            ))}
          </div>
        )}
      </main>
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
WORKDIR /app
COPY server/package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server/server.js ./
COPY --from=frontend-build /build/dist ./public
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
    # NOTE: mDNS names like `homeassistant.local` usually do NOT resolve inside
    # a container. Prefer setting HA_URL in .env to your Home Assistant host's
    # IP address (e.g. http://192.168.1.50:8123). On Linux you can instead
    # uncomment host networking below and remove the `ports:` section:
    # network_mode: host
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
# DOMAINS=light,switch,media_player,fan,cover,lock,climate,vacuum
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
EOF

# ---------------------------------------------------------------------------
# README.md
# ---------------------------------------------------------------------------
cat > README.md <<'EOF'
# Hearth3D

A self-contained, real-time isometric dashboard for Home Assistant. Rooms are
discovered automatically from your Home Assistant areas; devices appear on
each room card based on their area assignment, update live, and can be toggled
with a click.

```
Browser  <-- WebSocket (/ws, port 8080) -->  Node.js backend  <-- HA WebSocket API -->  Home Assistant
   |                                              |
   +----------- static React frontend <----------+
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

- **Toggle devices**: click a light, switch, fan, media player, cover, or lock.
- **Edit mode**: click *Edit layout* in the header. The view flattens to a
  top-down floor plan; drag devices to reposition them on their room cards.
  Positions persist in your browser's local storage. *Reset layout* restores
  the automatic arrangement.
- Rooms and devices update automatically when you rename areas or reassign
  devices in Home Assistant — no restart needed.

## Configuration

| Variable   | Default                            | Description                                    |
|------------|------------------------------------|------------------------------------------------|
| `HA_URL`   | `http://homeassistant.local:8123`  | Base URL of Home Assistant                     |
| `HA_TOKEN` | *(required)*                       | Long-lived access token                        |
| `PORT`     | `8080`                             | Dashboard HTTP/WebSocket port                  |
| `DOMAINS`  | `light,switch,media_player,fan,cover,lock,climate,vacuum` | Entity domains to display |

## Local development (without Docker)

```sh
# Terminal 1 — backend
cd server && npm install
HA_URL=http://192.168.1.50:8123 HA_TOKEN=... node server.js

# Terminal 2 — frontend with hot reload (proxies /ws to the backend)
cd frontend && npm install
npm run dev
```

## Troubleshooting

- **`auth_invalid` in the logs** — the token is wrong or was revoked. Create a
  new one.
- **`HA connection closed; retrying…` forever** — the container cannot reach
  `HA_URL`. Use the IP address, verify port 8123, and check firewalls.
- **Dashboard is empty** — your entities have no areas. Assign devices to
  areas in Home Assistant (Settings → Devices & services → Devices).
- **Only some devices appear** — only domains in `DOMAINS` are shown, and
  disabled/hidden entities are skipped. Add domains (e.g. `sensor`) via the
  `DOMAINS` environment variable.

## Security notes

- The HA token stays server-side; the browser never sees it.
- The dashboard itself has **no authentication** — anyone on your LAN who can
  reach port 8080 can view and toggle the exposed devices. Do not port-forward
  it to the internet; put it behind a reverse proxy with auth if you need
  remote access.
- Browser clients may only send `toggle` for entities the dashboard exposes;
  arbitrary Home Assistant service calls are not relayed.
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

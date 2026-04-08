'use strict';

const http = require('http');

// ── Configuration (from environment) ─────────────────────────────────────────
const PORT    = parseInt(process.env.PORT    || '3000', 10);
const HOST    = process.env.HOST    || '0.0.0.0';
const APP_ENV = process.env.APP_ENV || 'production';

// ── In-memory "database" for demo ─────────────────────────────────────────────
const items = new Map();
let nextId = 1;

// ── Request router ────────────────────────────────────────────────────────────
function router(req, res) {
  const url    = new URL(req.url, `http://${req.headers.host}`);
  const path   = url.pathname;
  const method = req.method;

  // ── Health / readiness endpoints ─────────────────────────────────────────
  if (path === '/health' && method === 'GET') {
    return sendJson(res, 200, {
      status:    'ok',
      timestamp: new Date().toISOString(),
      uptime:    Math.floor(process.uptime()),
      env:       APP_ENV,
      pid:       process.pid,
    });
  }

  if (path === '/ready' && method === 'GET') {
    return sendJson(res, 200, { ready: true });
  }

  // ── Items API ─────────────────────────────────────────────────────────────
  if (path === '/items' && method === 'GET') {
    return sendJson(res, 200, { items: [...items.values()] });
  }

  if (path === '/items' && method === 'POST') {
    return readBody(req, (err, body) => {
      if (err) return sendJson(res, 400, { error: 'Invalid request body' });

      let data;
      try { data = JSON.parse(body); } catch (_) {
        return sendJson(res, 400, { error: 'Body must be valid JSON' });
      }

      if (!data.name || typeof data.name !== 'string') {
        return sendJson(res, 422, { error: '"name" field is required and must be a string' });
      }

      const item = { id: nextId++, name: data.name.trim(), createdAt: new Date().toISOString() };
      items.set(item.id, item);
      return sendJson(res, 201, item);
    });
  }

  const idMatch = path.match(/^\/items\/(\d+)$/);
  if (idMatch) {
    const id = parseInt(idMatch[1], 10);

    if (method === 'GET') {
      const item = items.get(id);
      return item
        ? sendJson(res, 200, item)
        : sendJson(res, 404, { error: 'Item not found' });
    }

    if (method === 'DELETE') {
      const deleted = items.delete(id);
      return deleted
        ? sendJson(res, 200, { deleted: true, id })
        : sendJson(res, 404, { error: 'Item not found' });
    }
  }

  // ── 404 fallback ──────────────────────────────────────────────────────────
  return sendJson(res, 404, { error: `Route not found: ${method} ${path}` });
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type':  'application/json',
    'Content-Length': Buffer.byteLength(payload),
    'X-Powered-By':  'ForgeOps/1.0',
  });
  res.end(payload);
}

function readBody(req, cb) {
  const chunks = [];
  req.on('data', chunk => chunks.push(chunk));
  req.on('end',  ()    => cb(null, Buffer.concat(chunks).toString('utf8')));
  req.on('error', err  => cb(err));
}

// ── Server ────────────────────────────────────────────────────────────────────
const server = http.createServer(router);

server.listen(PORT, HOST, () => {
  console.log(JSON.stringify({
    level:     'info',
    message:   'Server started',
    port:      PORT,
    env:       APP_ENV,
    pid:       process.pid,
    timestamp: new Date().toISOString(),
  }));
});

// ── Graceful shutdown ─────────────────────────────────────────────────────────
function shutdown(signal) {
  console.log(JSON.stringify({ level: 'info', message: `Received ${signal} — shutting down`, timestamp: new Date().toISOString() }));
  server.close(() => {
    console.log(JSON.stringify({ level: 'info', message: 'Server closed', timestamp: new Date().toISOString() }));
    process.exit(0);
  });
  // Force-kill if it hangs
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

module.exports = { server }; // Export for testing

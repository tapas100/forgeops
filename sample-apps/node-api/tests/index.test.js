'use strict';

const http     = require('http');
const { server } = require('../src/index');

// Helper: make a raw HTTP request to the test server
function request(method, path, body = null) {
  return new Promise((resolve, reject) => {
    const options = {
      hostname: '127.0.0.1',
      port:     server.address()?.port || 3000,
      path,
      method,
      headers: { 'Content-Type': 'application/json' },
    };

    const req = http.request(options, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        let json;
        try { json = JSON.parse(raw); } catch (_) { json = raw; }
        resolve({ status: res.statusCode, body: json });
      });
    });

    req.on('error', reject);
    if (body) { req.write(JSON.stringify(body)); }
    req.end();
  });
}

// ── Test suite ────────────────────────────────────────────────────────────────
describe('GET /health', () => {
  test('returns 200 with status:ok', async () => {
    const { status, body } = await request('GET', '/health');
    expect(status).toBe(200);
    expect(body.status).toBe('ok');
    expect(typeof body.uptime).toBe('number');
    expect(body.timestamp).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });
});

describe('GET /ready', () => {
  test('returns 200 with ready:true', async () => {
    const { status, body } = await request('GET', '/ready');
    expect(status).toBe(200);
    expect(body.ready).toBe(true);
  });
});

describe('Items CRUD', () => {
  test('GET /items returns empty list initially', async () => {
    const { status, body } = await request('GET', '/items');
    expect(status).toBe(200);
    expect(Array.isArray(body.items)).toBe(true);
  });

  test('POST /items creates a new item', async () => {
    const { status, body } = await request('POST', '/items', { name: 'Widget A' });
    expect(status).toBe(201);
    expect(body.name).toBe('Widget A');
    expect(typeof body.id).toBe('number');
    expect(body.createdAt).toBeDefined();
  });

  test('POST /items without name returns 422', async () => {
    const { status, body } = await request('POST', '/items', {});
    expect(status).toBe(422);
    expect(body.error).toMatch(/name/);
  });

  test('POST /items with invalid JSON returns 400', async () => {
    const options = {
      hostname: '127.0.0.1',
      port:     server.address()?.port || 3000,
      path:     '/items',
      method:   'POST',
      headers:  { 'Content-Type': 'application/json' },
    };
    const { status } = await new Promise((resolve, reject) => {
      const req = http.request(options, res => {
        const chunks = [];
        res.on('data', c => chunks.push(c));
        res.on('end', () => {
          resolve({ status: res.statusCode });
        });
      });
      req.on('error', reject);
      req.write('not-valid-json');
      req.end();
    });
    expect(status).toBe(400);
  });

  test('GET /items/:id returns 404 for unknown item', async () => {
    const { status } = await request('GET', '/items/999999');
    expect(status).toBe(404);
  });

  test('DELETE /items/:id deletes existing item', async () => {
    // Create first
    const { body: created } = await request('POST', '/items', { name: 'Temp Item' });
    const { status } = await request('DELETE', `/items/${created.id}`);
    expect(status).toBe(200);

    // Verify it is gone
    const { status: getStatus } = await request('GET', `/items/${created.id}`);
    expect(getStatus).toBe(404);
  });
});

describe('404 handler', () => {
  test('unknown route returns 404', async () => {
    const { status } = await request('GET', '/nonexistent');
    expect(status).toBe(404);
  });
});

'use strict';

/**
 * ForgeOps — node-worker (sample background worker)
 * Demonstrates a job queue processor. In production, replace the in-memory
 * queue with Redis Streams, RabbitMQ, etc.
 */

const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || '5000', 10);
const APP_ENV          = process.env.APP_ENV || 'production';

// ── Simple in-memory job queue ────────────────────────────────────────────────
const queue = [];
let processed = 0;
let running   = true;

function enqueue(job) {
  queue.push({ ...job, enqueuedAt: new Date().toISOString() });
}

async function processJob(job) {
  const start = Date.now();
  // Simulate async work (replace with real logic)
  await new Promise(r => setTimeout(r, Math.random() * 200));
  const duration = Date.now() - start;
  processed++;

  log('info', 'job_processed', { id: job.id, type: job.type, durationMs: duration });
  return { success: true, duration };
}

async function workerLoop() {
  log('info', 'worker_started', { env: APP_ENV, pollInterval: POLL_INTERVAL_MS });

  // Seed a few demo jobs
  for (let i = 1; i <= 3; i++) {
    enqueue({ id: `seed-${i}`, type: 'demo', payload: { value: i * 10 } });
  }

  while (running) {
    if (queue.length > 0) {
      const job = queue.shift();
      try {
        await processJob(job);
      } catch (err) {
        log('error', 'job_failed', { id: job.id, error: err.message });
      }
    }
    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS));
  }

  log('info', 'worker_stopped', { totalProcessed: processed });
}

// ── Structured JSON logging ───────────────────────────────────────────────────
function log(level, event, extra = {}) {
  console.log(JSON.stringify({ level, event, timestamp: new Date().toISOString(), pid: process.pid, ...extra }));
}

// ── Graceful shutdown ─────────────────────────────────────────────────────────
function shutdown(signal) {
  log('info', 'shutdown_initiated', { signal });
  running = false;
  setTimeout(() => {
    log('info', 'shutdown_complete', { totalProcessed: processed });
    process.exit(0);
  }, 1000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

// ── Export for testing ────────────────────────────────────────────────────────
module.exports = { enqueue, processJob, getProcessed: () => processed };

// ── Start (only when run directly) ───────────────────────────────────────────
if (require.main === module) {
  workerLoop().catch(err => {
    log('error', 'worker_crash', { error: err.message, stack: err.stack });
    process.exit(1);
  });
}

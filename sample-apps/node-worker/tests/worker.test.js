'use strict';

const { enqueue, processJob, getProcessed } = require('../src/worker');

describe('worker — enqueue and processJob', () => {
  test('processJob resolves with success:true', async () => {
    const job = { id: 'test-1', type: 'demo', payload: { value: 42 } };
    const result = await processJob(job);
    expect(result.success).toBe(true);
    expect(typeof result.duration).toBe('number');
  });

  test('processJob increments processed counter', async () => {
    const before = getProcessed();
    await processJob({ id: 'test-2', type: 'demo', payload: {} });
    expect(getProcessed()).toBe(before + 1);
  });

  test('enqueue adds jobs (smoke test)', () => {
    // enqueue is synchronous; we just verify it does not throw
    expect(() => {
      enqueue({ id: 'enq-1', type: 'demo', payload: { x: 1 } });
    }).not.toThrow();
  });
});

import { jest, describe, test, expect } from '@jest/globals';
import { RedisFallbackStore } from '../../lib/rate-limit-store.js';

const WINDOW = 60_000;

// Just enough of ioredis: status, connect(), and MULTI with set NX PX / incr /
// pttl, decr and del, over an in-memory map shared by every "replica".
function fakeRedis(status = 'ready', shared = new Map()) {
  const client = {
    status,
    data: shared,
    connect: jest.fn(async () => { client.status = 'ready'; }),
    multi() {
      const ops = [];
      const chain = {
        set: (k, v, px, ms, nx) => {
          ops.push(() => {
            if (nx === 'NX' && shared.has(k)) return null;
            shared.set(k, { n: Number(v), ttl: ms });
            return 'OK';
          });
          return chain;
        },
        incr: (k) => { ops.push(() => { shared.get(k).n += 1; return shared.get(k).n; }); return chain; },
        pttl: (k) => { ops.push(() => shared.get(k)?.ttl ?? -2); return chain; },
        exec: async () => {
          if (client.failNext) { client.failNext = false; throw new Error('connection lost'); }
          return ops.map((op) => [null, op()]);
        },
      };
      return chain;
    },
    decr: jest.fn(async (k) => { shared.get(k).n -= 1; }),
    del: jest.fn(async (k) => { shared.delete(k); }),
  };
  return client;
}

function store(client) {
  const s = new RedisFallbackStore(client);
  s.init({ windowMs: WINDOW });
  return s;
}

describe('RedisFallbackStore', () => {
  test('counts in Redis, shared by every replica', async () => {
    const shared = new Map();
    const a = store(fakeRedis('ready', shared));
    const b = store(fakeRedis('ready', shared));
    expect((await a.increment('1.2.3.4')).totalHits).toBe(1);
    expect((await b.increment('1.2.3.4')).totalHits).toBe(2);
    const { totalHits, resetTime } = await a.increment('1.2.3.4');
    expect(totalHits).toBe(3);
    expect(resetTime.getTime()).toBeGreaterThan(Date.now());
    expect(shared.get('my-app:rl:1.2.3.4').ttl).toBe(WINDOW);
  });

  test('counts in memory while Redis is not connected, and starts connecting', async () => {
    const client = fakeRedis('wait');
    const s = store(client);
    expect((await s.increment('k')).totalHits).toBe(1);
    expect(client.connect).toHaveBeenCalled();
    expect(client.data.size).toBe(0);
  });

  test('does not wait on a Redis that is reconnecting', async () => {
    const client = fakeRedis('reconnecting');
    const s = store(client);
    expect((await s.increment('k')).totalHits).toBe(1);
    expect((await s.increment('k')).totalHits).toBe(2);
    expect(client.connect).not.toHaveBeenCalled();
  });

  test('falls back to memory when a Redis command fails', async () => {
    const client = fakeRedis('ready');
    const s = store(client);
    client.failNext = true;
    expect((await s.increment('k')).totalHits).toBe(1);
    // Redis is used again on the next request.
    expect((await s.increment('k')).totalHits).toBe(1);
    expect(client.data.get('my-app:rl:k').n).toBe(1);
  });

  test('decrement and resetKey act on Redis when it is up', async () => {
    const client = fakeRedis('ready');
    const s = store(client);
    await s.increment('k');
    await s.increment('k');
    await s.decrement('k');
    expect(client.data.get('my-app:rl:k').n).toBe(1);
    await s.resetKey('k');
    expect(client.data.has('my-app:rl:k')).toBe(false);
  });

  test('decrement and resetKey fall back to memory when Redis is down', async () => {
    const client = fakeRedis('end');
    const s = store(client);
    await s.increment('k');
    await s.increment('k');
    await s.decrement('k');
    expect((await s.increment('k')).totalHits).toBe(2);
    await s.resetKey('k');
    expect((await s.increment('k')).totalHits).toBe(1);
    expect(client.del).not.toHaveBeenCalled();
  });
});

/**
 * Rate-limit store for express-rate-limit: counts in Redis, so every replica
 * shares one limit per client (an in-memory count is per pod, which makes the
 * real limit RATE_LIMIT_MAX × replicas).
 *
 * While Redis is not connected, it counts in memory instead (per pod): the
 * limit degrades rather than disappearing, and requests never wait on a Redis
 * that is down. A Redis error on a request falls back the same way.
 *
 * Each hit is one MULTI: SET key 0 PX window NX (start the window on the first
 * hit), INCR, PTTL.
 */

import { MemoryStore } from 'express-rate-limit';

export class RedisFallbackStore {
  /**
   * @param {import('ioredis').Redis} client — lazyConnect ioredis client
   * @param {{ prefix?: string }} [options]
   */
  constructor(client, { prefix = 'my-app:rl:' } = {}) {
    this.client = client;
    this.prefix = prefix;
    this.memory = new MemoryStore();
  }

  init(options) {
    this.windowMs = options.windowMs;
    this.memory.init(options);
  }

  // Ready to use now? A lazyConnect client that has not connected yet starts
  // connecting in the background; this request is counted in memory.
  redisReady() {
    if (this.client.status === 'ready') return true;
    if (this.client.status === 'wait') this.client.connect().catch(() => {});
    return false;
  }

  async increment(key) {
    if (!this.redisReady()) return this.memory.increment(key);
    const k = this.prefix + key;
    try {
      const replies = await this.client
        .multi()
        .set(k, 0, 'PX', this.windowMs, 'NX')
        .incr(k)
        .pttl(k)
        .exec();
      const err = replies.find(([e]) => e);
      if (err) throw err[0];
      const totalHits = Number(replies[1][1]);
      const ttl = Number(replies[2][1]);
      return {
        totalHits,
        resetTime: new Date(Date.now() + (ttl > 0 ? ttl : this.windowMs)),
      };
    } catch {
      return this.memory.increment(key);
    }
  }

  async decrement(key) {
    if (!this.redisReady()) return this.memory.decrement(key);
    try {
      await this.client.decr(this.prefix + key);
    } catch {
      await this.memory.decrement(key);
    }
  }

  async resetKey(key) {
    await this.memory.resetKey(key);
    if (!this.redisReady()) return;
    try {
      await this.client.del(this.prefix + key);
    } catch {
      // Nothing to reset when Redis is unreachable.
    }
  }

  shutdown() {
    this.memory.shutdown?.();
  }
}

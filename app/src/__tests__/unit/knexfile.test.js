import { jest, describe, test, expect, beforeEach, afterEach } from '@jest/globals';
import { mkdtempSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

// knexfile.js reads the environment when it is imported, so each test sets it
// and imports a fresh copy.
const ENV_KEYS = ['DB_HOST', 'DB_PORT', 'DB_USER', 'DB_PASSWORD', 'DB_NAME', 'DB_SSL', 'DB_SSL_CA'];
let savedEnv;

beforeEach(() => {
  savedEnv = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
  for (const k of ENV_KEYS) delete process.env[k];
  jest.resetModules();
});

afterEach(() => {
  for (const k of ENV_KEYS) {
    if (savedEnv[k] === undefined) delete process.env[k];
    else process.env[k] = savedEnv[k];
  }
});

async function loadKnexfile(env) {
  Object.assign(process.env, env);
  return import('../../../knexfile.js');
}

describe('knexfile.js', () => {
  test('development and test keep the local defaults', async () => {
    const { default: config } = await loadKnexfile({});
    expect(config.development.connection).toMatchObject({
      host: 'localhost', password: 'apppassword', database: 'appdb',
    });
    expect(config.test.connection).toMatchObject({ host: 'localhost', database: 'appdb_test' });
  });

  test.each([
    ['DB_HOST', { DB_PASSWORD: 'secret' }],
    ['DB_PASSWORD', { DB_HOST: 'db.internal' }],
  ])('production without %s throws instead of using localhost defaults', async (missing, env) => {
    const { default: config } = await loadKnexfile(env);
    expect(() => config.production).toThrow(`${missing} must be set for the production environment`);
  });

  test('production uses the environment, without TLS unless DB_SSL=true', async () => {
    const { default: config } = await loadKnexfile({ DB_HOST: 'db.internal', DB_PASSWORD: 'secret' });
    expect(config.production.connection).toMatchObject({
      host: 'db.internal', password: 'secret', ssl: false,
    });
  });

  test('production with DB_SSL=true verifies against the trust store', async () => {
    const { default: config } = await loadKnexfile({
      DB_HOST: 'db.internal', DB_PASSWORD: 'secret', DB_SSL: 'true',
    });
    expect(config.production.connection.ssl).toEqual({ rejectUnauthorized: true });
  });

  test('production with DB_SSL_CA verifies against that bundle', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'knex-ca-'));
    const caPath = join(dir, 'global-bundle.pem');
    writeFileSync(caPath, 'PEM');
    const { default: config } = await loadKnexfile({
      DB_HOST: 'db.internal', DB_PASSWORD: 'secret', DB_SSL: 'true', DB_SSL_CA: caPath,
    });
    expect(config.production.connection.ssl).toEqual({ ca: 'PEM', rejectUnauthorized: true });
  });

  test('sslOptions() ignores DB_SSL_CA unless DB_SSL=true', async () => {
    const { sslOptions } = await loadKnexfile({});
    expect(sslOptions({ DB_SSL_CA: '/etc/ssl/rds.pem' })).toBe(false);
  });
});

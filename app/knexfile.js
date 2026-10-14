/**
 * Knex configuration file.
 * Used by `knex` CLI and `lib/db.js` for migrations and queries.
 *
 * Environment variables (with local-dev defaults):
 *   DB_HOST     — Postgres host       (default: localhost; required in production)
 *   DB_PORT     — Postgres port       (default: 5432)
 *   DB_USER     — Postgres user       (default: appuser)
 *   DB_PASSWORD — Postgres password   (default: apppassword; required in production)
 *   DB_NAME     — Postgres database   (default: appdb)
 *   DB_SSL      — "true" to connect over TLS (production block)
 *   DB_SSL_CA   — with DB_SSL, path to a PEM CA bundle to verify the server
 *                 against (e.g. the RDS global bundle mounted into the pod)
 */

import { readFileSync } from 'fs';

/**
 * pg TLS options from DB_SSL and DB_SSL_CA; lib/db.js uses the same.
 * Without DB_SSL_CA the server is verified against Node's trust store (which
 * NODE_EXTRA_CA_CERTS extends); RDS certificates need the RDS CA bundle.
 */
export function sslOptions(env = process.env) {
  if (env.DB_SSL !== 'true') return false;
  if (!env.DB_SSL_CA) return { rejectUnauthorized: true };
  return { ca: readFileSync(env.DB_SSL_CA, 'utf8'), rejectUnauthorized: true };
}

const base = {
  client: 'pg',
  connection: {
    host:     process.env.DB_HOST     || 'localhost',
    port:     Number(process.env.DB_PORT || 5432),
    user:     process.env.DB_USER     || 'appuser',
    password: process.env.DB_PASSWORD || 'apppassword',
    database: process.env.DB_NAME     || 'appdb',
  },
  pool: { min: 2, max: 10 },
  migrations: {
    directory: './migrations',
    extension: 'js',
  },
};

export default {
  development: {
    ...base,
  },

  test: {
    ...base,
    connection: {
      ...base.connection,
      database: process.env.DB_NAME || 'appdb_test',
    },
    // Use minimum connections in test environment to avoid resource exhaustion
    pool: { min: 1, max: 5 },
  },

  // A getter, so the checks run only when the production block is used: the
  // local defaults would otherwise send migrations to localhost.
  get production() {
    for (const name of ['DB_HOST', 'DB_PASSWORD']) {
      if (!process.env[name]) {
        throw new Error(`knexfile: ${name} must be set for the production environment`);
      }
    }
    return {
      ...base,
      connection: {
        ...base.connection,
        ssl: sslOptions(),
      },
      pool: { min: 2, max: 10 },
    };
  },
};

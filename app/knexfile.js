/**
 * Knex configuration file.
 * Used by `knex` CLI and `lib/db.js` for migrations and queries.
 *
 * Environment variables (with local-dev defaults):
 *   DB_HOST     — Postgres host       (default: localhost)
 *   DB_PORT     — Postgres port       (default: 5432)
 *   DB_USER     — Postgres user       (default: appuser)
 *   DB_PASSWORD — Postgres password   (default: apppassword)
 *   DB_NAME     — Postgres database   (default: appdb)
 */

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

  production: {
    ...base,
    connection: {
      ...base.connection,
      ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: true } : false,
    },
    pool: { min: 2, max: 10 },
  },
};

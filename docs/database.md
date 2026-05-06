# Database — Postgres + knex migrations

Added in Build 017. This document covers local setup, migration workflow,
the expand-contract pattern, and rollback procedures.

## Stack

| Component | Choice | Version |
|-----------|--------|---------|
| Database  | Postgres | 15 (Docker) / cluster-managed |
| Driver    | `pg` (node-postgres) | ^8.x |
| Migrations | `knex` | ^3.x |
| Tests     | `DB_FAKE=1` in-memory store | — |

## Running locally with Docker Compose

```bash
# From repo root — starts Postgres, Redis, and the app (with migrations)
docker compose -f docker/docker-compose.yml up app
```

The `app` service runs `npm run migrate && npm start`, so migrations are
applied automatically before the server starts.

To start only the infrastructure (without the app):

```bash
docker compose -f docker/docker-compose.yml up app-db redis
```

Then in another terminal:

```bash
cd app
DB_HOST=localhost DB_PORT=5432 DB_USER=appuser \
DB_PASSWORD=apppassword DB_NAME=appdb npm run migrate
npm run dev
```

## Running migrations manually

```bash
cd app

# Apply all pending migrations
npm run migrate

# Roll back the most-recent migration batch
npm run migrate:rollback

# Create a new migration file
npm run migrate:make -- <migration_name>
# Example: npm run migrate:make -- add_status_to_items
```

Migration files live in `app/migrations/` and are sorted by timestamp prefix.

## Creating a new migration

```bash
cd app
npm run migrate:make -- add_status_to_items
```

This creates `app/migrations/<timestamp>_add_status_to_items.js`. Edit it:

```js
export async function up(knex) {
  await knex.schema.alterTable('items', (table) => {
    table.string('status').notNullable().defaultTo('active');
  });
}

export async function down(knex) {
  await knex.schema.alterTable('items', (table) => {
    table.dropColumn('status');
  });
}
```

## Expand-contract pattern

The CI pipeline runs `runMigrations()` **before** `deployToKubernetes()` in
both staging and production. During a Kubernetes rolling update, old and new
pods run simultaneously. To avoid downtime:

1. **Expand** (additive) — new columns must be nullable or have defaults.
   Old pods ignore unknown columns; new pods use them.
   ```sql
   ALTER TABLE items ADD COLUMN status TEXT DEFAULT 'active';
   ```

2. **Deploy** — roll out the new app image. Both old and new pods work.

3. **Contract** (cleanup) — once all old pods are gone, a subsequent migration
   can tighten constraints or remove deprecated columns.
   ```sql
   ALTER TABLE items ALTER COLUMN status SET NOT NULL;
   ```

**Never** do a destructive rename/drop in the same migration as the feature
that depends on it. Split it into two separate deploys.

## Rollback procedure

### Application rollback (code only)

If `kubectl rollout undo` is sufficient (schema is backward-compatible):

```bash
kubectl rollout undo deployment/my-app --namespace production
```

### Migration rollback

If a schema change needs to be reverted:

```bash
cd app
# Roll back the most-recent batch of migrations
DB_HOST=<host> DB_PASSWORD=<password> npm run migrate:rollback
```

Then roll back the application image.

> **Note:** Only roll back a migration if the code that uses the new schema
> is also being rolled back. Rolling back a schema while new code is running
> will cause errors.

## Environment variables

| Variable      | Required | Default   | Description                      |
|---------------|----------|-----------|----------------------------------|
| `DB_HOST`     | Yes*     | —         | Postgres hostname                |
| `DB_PORT`     | No       | `5432`    | Postgres port                    |
| `DB_USER`     | No       | `appuser` | Postgres username                |
| `DB_PASSWORD` | Yes*     | —         | Postgres password                |
| `DB_NAME`     | No       | `appdb`   | Database name                    |
| `DB_SSL`      | No       | `false`   | Set `true` to enable TLS         |
| `DB_FAKE`     | No       | `false`   | Set `1` for in-memory test store |

*Required in staging/production. For local dev with Docker Compose these are
pre-filled via the `app` service environment block.

## Schema

### `items` table

| Column       | Type                         | Notes              |
|--------------|------------------------------|--------------------|
| `id`         | SERIAL PRIMARY KEY           | Auto-increment     |
| `name`       | TEXT NOT NULL                |                    |
| `created_at` | TIMESTAMPTZ DEFAULT now()    |                    |
| `updated_at` | TIMESTAMPTZ DEFAULT now()    |                    |

Index: `items_created_at_desc ON items (created_at DESC)` — optimises the
default `GET /api/items` query (ORDER BY created_at DESC LIMIT 100).

## Kubernetes secrets

`DB_HOST` and `DB_PASSWORD` are sensitive and stored as a SealedSecret
(see `k8s/secrets/my-app-secrets.template.yaml` and `docs/secrets.md`).

`DB_PORT`, `DB_USER`, `DB_NAME` are non-sensitive and live in the per-overlay
ConfigMap (`k8s/overlays/{production,staging}/configmap-patch.yaml`).

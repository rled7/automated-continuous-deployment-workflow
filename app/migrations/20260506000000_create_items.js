/**
 * Migration: create_items
 * Created: 2026-05-06T00:00:00
 *
 * Creates the `items` table used by the /api/items endpoints.
 * Index on created_at DESC optimises the default "list latest" query
 * (SELECT ... ORDER BY created_at DESC LIMIT 100).
 */

/**
 * @param {import('knex').Knex} knex
 */
export async function up(knex) {
  await knex.schema.createTable('items', (table) => {
    table.increments('id').primary();          // SERIAL PRIMARY KEY
    table.text('name').notNullable();          // TEXT NOT NULL
    table.timestamp('created_at', { useTz: true }).defaultTo(knex.fn.now()); // TIMESTAMPTZ DEFAULT now()
    table.timestamp('updated_at', { useTz: true }).defaultTo(knex.fn.now()); // TIMESTAMPTZ DEFAULT now()
  });

  // Index on created_at DESC for typical "list latest" queries
  await knex.schema.raw(
    'CREATE INDEX items_created_at_desc ON items (created_at DESC)',
  );
}

/**
 * @param {import('knex').Knex} knex
 */
export async function down(knex) {
  await knex.schema.dropTableIfExists('items');
}

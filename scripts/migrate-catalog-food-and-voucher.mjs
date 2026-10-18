#!/usr/bin/env node
/**
 * One-shot migration: Food & Drinks products + the free-delivery voucher.
 *
 * Runs the SITE'S OWN `db.js` against `../Store/catalog.sql`, the way
 * regen-catalog-json.mjs and reindex-catalog.mjs do, so the result is exactly
 * what the admin panel would have produced by hand:
 *
 *   * settings  — `delivery_percent` (10) and the voucher wording. One place,
 *                 read by the site AND the app, so the two cannot disagree.
 *   * products  — French Fries, Zinger Burger and Roti in a "Food & Drinks"
 *                 category. The first two carry a "Cold drink" add-on: a
 *                 preference that travels in the WhatsApp message, never a
 *                 price.
 *   * vectors   — rebuilt for every product, after proving the local engine
 *                 reproduces the shipped index exactly (reindex-catalog.mjs
 *                 does the same, and for the same reason: a vector from a
 *                 different encoder ranks confidently and wrongly).
 *
 * WHY `catalog.sql` IS PATCHED FIRST
 * The file on disk predates `options`, so its `CREATE TABLE products` has no
 * such column and `createProduct`'s INSERT would fail. The column is added
 * textually, tolerating any mix of newlines, exactly as the guide's patching
 * section prescribes. `toSql()` then rewrites the whole file, so the patch is
 * only scaffolding.
 *
 * IDEMPOTENT. Re-running skips settings already set and products already
 * present, and simply rebuilds the index again.
 *
 * Usage:
 *   node scripts/migrate-catalog-food-and-voucher.mjs
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const HERE = dirname(fileURLToPath(import.meta.url));
const APP = resolve(HERE, '..');
const STORE = resolve(APP, '..', 'Store');

const require = createRequire(import.meta.url);
const ENGINE = resolve(APP, 'node_modules', '@ternlight', 'base', 'pkg-node', 'tern_engine.js');
const CATALOG_SQL = resolve(STORE, 'catalog.sql');

// ── what to write ────────────────────────────────────────────────────────────

const SETTINGS = {
  // Delivery is a percentage of the order's price. Both surfaces show the
  // pre-delivery price struck through; the price itself never changes.
  delivery_percent: '10',
  // The offer the old top strip announced, reworded as something claimable.
  // The threshold itself stays in free_delivery_over_paisa (Rs 6,000).
  voucher_title: 'Free delivery over Rs 6,000',
  voucher_code: 'FREEDELIVERY',
  voucher_description: 'Claim this voucher and we cover delivery on any order over Rs 6,000.',
  voucher_terms: 'Valid on orders over Rs 6,000. One claim per customer. Applied to your order on WhatsApp.',
};

/** The string the site embeds. Keep identical to admin.js and reindex-catalog.mjs. */
const embedText = (p) => `${p.name}. ${p.category}. ${p.description || ''}`.trim();

const COLD_DRINK = [{ key: 'cold_drink', label: 'Cold drink' }];

const PRODUCTS = [
  {
    slug: 'french-fries',
    name: 'French Fries',
    category: 'Food & Drinks',
    price_cents: 35000,
    description:
      'Golden fries, cut thin and fried to order, salted the moment they come up.',
    details:
      'Cut thin and fried twice: once to cook them through, again to crisp the outside. ' +
      'That second fry is why they stay crisp on the way to you instead of steaming soft in ' +
      'the box. Salted the moment they come out of the oil, while the surface still holds it. ' +
      'Served with ketchup; ask for chilli garlic instead if you prefer.',
    specs: {
      Portion: 'Regular',
      Serves: '1–2',
      Cut: 'Thin, twice-fried',
      'Served with': 'Ketchup',
    },
    options: COLD_DRINK,
    tint: '#E8DDF2',
    sort_order: 5,
  },
  {
    slug: 'zinger-burger',
    name: 'Zinger Burger',
    category: 'Food & Drinks',
    price_cents: 55000,
    description:
      'Buttermilk-marinated chicken fillet in a crisp spiced crust, in a soft sesame bun.',
    details:
      'A single chicken fillet, marinated overnight in buttermilk so it stays juicy, then ' +
      'dredged in a spiced flour crust and fried until it shatters. The bun is toasted so it ' +
      'holds up under the sauce without going soggy. Lettuce and mayo as standard; the heat ' +
      'is mild rather than hot.',
    specs: {
      Serves: '1',
      Filling: 'Chicken fillet',
      Heat: 'Mild',
      Bun: 'Toasted sesame',
    },
    options: COLD_DRINK,
    tint: '#CFC3E3',
    sort_order: 6,
  },
  {
    slug: 'roti',
    name: 'Roti',
    category: 'Food & Drinks',
    price_cents: 4000,
    description: 'Hand-rolled whole-wheat flatbread, cooked fresh on the tawa.',
    details:
      'Hand-rolled and cooked to order on a hot tawa, then held briefly over the flame so it ' +
      'puffs and stays soft rather than turning brittle. Whole-wheat flour and no shortening, ' +
      'and no oil brushed on at the end, so it is as good with a dry kebab as with a curry.',
    specs: {
      Pieces: '2',
      Flour: 'Whole wheat',
      Cooked: 'Fresh on the tawa',
      No: 'Shortening or oil',
    },
    options: [],
    tint: '#D9CCEA',
    sort_order: 7,
  },
];

// ── 1. Give the on-disk schema the `options` column ──────────────────────────

function bootstrapSchema() {
  let src = readFileSync(CATALOG_SQL, 'utf8');
  if (/^\s*options\s+TEXT\s*,/m.test(src)) {
    console.log('  = products.options already present in catalog.sql');
    return;
  }
  // `specs` exists only in the products table, so this anchor is unambiguous.
  const anchor = '  specs       TEXT,';
  const escaped = anchor.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(escaped.split('\n').map((p) => p).join('\\r*\\n'));
  const matches = src.match(re);
  if (!matches || matches.length !== 1) {
    throw new Error(`expected one products CREATE TABLE anchor, found ${matches ? matches.length : 0}`);
  }
  src = src.replace(re, () => `  specs       TEXT,\n  options     TEXT,`);
  writeFileSync(CATALOG_SQL, src, 'utf8');
  console.log('  + added products.options to catalog.sql (scaffolding)');
}

console.log('[1/6] Bootstrapping catalog.sql schema');
bootstrapSchema();

// ── 2. Load catalog.sql through the site's own db.js ─────────────────────────

console.log('\n[2/6] Loading catalog.sql through the site\'s db.js');

const localStorageStore = new Map();
globalThis.localStorage = {
  getItem: (k) => (localStorageStore.has(k) ? localStorageStore.get(k) : null),
  setItem: (k, v) => localStorageStore.set(k, String(v)),
  removeItem: (k) => localStorageStore.delete(k),
};

globalThis.fetch = async (url) => {
  const rel = String(url).replace(/^\.\//, '');
  if (rel !== 'catalog.sql') throw new Error(`unexpected fetch: ${url}`);
  return { ok: true, status: 200, text: async () => readFileSync(CATALOG_SQL, 'utf8') };
};

const WASM = resolve(STORE, 'vendor', 'sql-wasm.wasm');
globalThis.initSqlJs = (opts = {}) =>
  require(resolve(STORE, 'vendor', 'sql-wasm.js'))({ ...opts, locateFile: () => WASM });

const dbSource = readFileSync(resolve(STORE, 'db.js'), 'utf8');
const Catalog = new Function(`${dbSource}\n;return Catalog;`)();
await Catalog.init();
if (!Catalog.isReady()) {
  console.error('Catalog.init() resolved but isReady() is false.');
  process.exit(1);
}

const { embed } = require(ENGINE);

// ── 3. Prove the engine reproduces the shipped index ─────────────────────────

console.log('\n[3/6] Verifying the engine reproduces the shipped vectors');

const productsBefore = Catalog.listProducts();
const vectorsBefore = Catalog.getVectors();

let worst = 0;
let checked = 0;
for (const p of productsBefore) {
  const stored = vectorsBefore.get(p.slug);
  if (!stored || stored.model !== Catalog.SEARCH_MODEL) continue;
  const got = embed(embedText(p));
  for (let i = 0; i < stored.vector.length; i++) {
    worst = Math.max(worst, Math.abs(got[i] - stored.vector[i]));
  }
  checked++;
}
if (worst !== 0) {
  console.error(`\nEngine does not reproduce the shipped index (worst ${worst.toExponential(3)}).`);
  console.error('Refusing to rebuild with it. Nothing was written.');
  process.exit(1);
}
console.log(`  ${checked}/${productsBefore.length} stored vectors reproduced exactly`);

// ── 4. Settings ──────────────────────────────────────────────────────────────

console.log('\n[4/6] Writing settings');
for (const [key, value] of Object.entries(SETTINGS)) {
  const current = Catalog.getSetting(key);
  if (current === value) {
    console.log(`  = ${key}`);
  } else {
    Catalog.setSetting(key, value);
    console.log(`  + ${key} = ${JSON.stringify(value)}`);
  }
}

// ── 5. Products ──────────────────────────────────────────────────────────────

console.log('\n[5/6] Adding Food & Drinks products');
const existingSlugs = new Set(productsBefore.map((p) => p.slug));
for (const spec of PRODUCTS) {
  if (existingSlugs.has(spec.slug)) {
    console.log(`  = ${spec.slug} (already present)`);
    continue;
  }
  const created = Catalog.createProduct({
    slug: spec.slug,
    name: spec.name,
    description: spec.description,
    details: spec.details,
    specs: JSON.stringify(spec.specs),
    options: JSON.stringify(spec.options),
    category: spec.category,
    price_cents: spec.price_cents,
    image_url: null,
    tint: spec.tint,
    in_stock: 1,
    sort_order: spec.sort_order,
  });
  if (!created.ok) {
    console.error(`  The site rejected "${spec.slug}":`);
    console.error(JSON.stringify(created.errors, null, 2));
    process.exit(1);
  }
  console.log(`  + ${spec.slug}`);
}

// ── 6. Rebuild every vector, then write catalog.sql ──────────────────────────

console.log('\n[6/6] Rebuilding the search index and writing catalog.sql');
const productsAfter = Catalog.listProducts();
const entries = productsAfter.map((p) => ({ slug: p.slug, vector: embed(embedText(p)) }));
Catalog.replaceVectors(entries, Catalog.SEARCH_MODEL);

writeFileSync(CATALOG_SQL, Catalog.toSql(), 'utf8');

const after = JSON.parse(Catalog.toJson());
const withOptions = after.products.filter((p) => (p.options || []).length);
console.log(`    products: ${productsBefore.length} -> ${after.products.length}`);
console.log(`    searchable: ${Catalog.indexIsComplete()}`);
console.log(`    delivery_percent: ${after.store.delivery_percent}`);
console.log(`    voucher: ${after.store.voucher.title} (${after.store.voucher.code})`);
for (const p of after.products.filter((x) => x.category === 'Food & Drinks')) {
  const opts = (p.options || []).map((o) => o.label).join(', ') || '—';
  console.log(`      ${p.slug.padEnd(16)} Rs ${(p.price_cents / 100).toFixed(0).padStart(5)}  options: ${opts}`);
}
console.log(`    products with add-ons: ${withOptions.length}`);

console.log('\nDone. Next:');
console.log('  node scripts/regen-catalog-json.mjs    # rebuild ../Store/catalog.json');

#!/usr/bin/env node
/**
 * Add a product to catalog.sql, embedded by the SITE'S OWN engine.
 *
 * # Why this exists
 *
 * `catalog.sql` is the source of truth and its `product_vectors` rows are
 * precomputed in the admin panel. Adding a product otherwise means opening the
 * admin page in a browser, embedding, and downloading catalog.sql back — a
 * manual round trip through a UI. That is the step that gets skipped, and then
 * catalog.json and catalog.sql disagree, which is the failure CATALOG-GUIDE.md
 * spends most of its length on.
 *
 * # Why it uses the site's engine and not a reimplementation
 *
 * A vector is only meaningful in the space of the model that produced it. A
 * close-but-different embedding still ranks confidently and wrongly. So this
 * runs `@ternlight/base@0.1.1` — the same module `search.js` loads from
 * jsdelivr, and the same one the app's native Rust port reproduces.
 *
 * Before touching anything it VERIFIES the engine reproduces every vector
 * already in catalog.json. If that fails it stops: the engine is not the one
 * that built the existing index, and anything added with it would live in a
 * different space and silently misrank.
 *
 * # It embeds the string the site embeds
 *
 * admin.js: `${p.name}. ${p.category}. ${p.description || ''}`.trim()
 *
 * Embedding only `description` produced vectors differing from the shipped ones
 * by up to 8e-2 — close enough to look plausible, far enough to be wrong. This
 * was measured, not assumed.
 *
 * # The product goes into catalog.sql, not catalog.json
 *
 * `publish-catalog.mjs` regenerates catalog.json FROM catalog.sql. Writing the
 * product into catalog.json instead would have it silently overwritten on the
 * next publish, which looks like a bug in the app rather than in the workflow.
 *
 * Usage:
 *   node scripts/reindex-catalog.mjs --verify              reproduce the shipped index
 *   node scripts/reindex-catalog.mjs --add spec.json       embed + write catalog.sql
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const APP = resolve(HERE, '..');
const STORE = resolve(APP, '..', 'Store');
const require = createRequire(import.meta.url);

// Absolute path, not a package name: @ternlight/base declares an `exports`
// field exposing only "." and "./web", so a deep require of the pkg-node build
// is blocked even though the file is on disk.
const ENGINE = resolve(APP, 'node_modules', '@ternlight', 'base', 'pkg-node', 'tern_engine.js');

let embed;
try {
  ({ embed } = require(ENGINE));
} catch {
  console.error('The site engine is not installed. It is dev-only:\n');
  console.error('  npm install @ternlight/base@0.1.1\n');
  process.exit(1);
}

/** The string the site embeds. Keep this identical to admin.js. */
function embedText(p) {
  return `${p.name}. ${p.category}. ${p.description || ''}`.trim();
}

function maxDiff(a, b) {
  let worst = 0;
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    worst = Math.max(worst, Math.abs(a[i] - b[i]));
  }
  return worst;
}

const catalogJsonPath = resolve(STORE, 'catalog.json');
const catalogSqlPath = resolve(STORE, 'catalog.sql');

// ── verify ───────────────────────────────────────────────────────────────────
//
// The gate. If the engine does not reproduce what is already shipped, nothing
// may be added with it.

function verify() {
  const catalog = JSON.parse(readFileSync(catalogJsonPath, 'utf8'));
  let worst = 0;
  for (const p of catalog.products) {
    const stored = Buffer.from(p.vector, 'base64');
    const want = new Float32Array(stored.buffer, stored.byteOffset, stored.length / 4);
    const got = embed(embedText(p));
    const d = maxDiff(got, want);
    worst = Math.max(worst, d);
    console.log(`    ${p.slug.padEnd(20)} ${d.toExponential(3)}${d === 0 ? '  identical' : ''}`);
  }
  if (worst !== 0) {
    console.error(`\nEngine does not reproduce the shipped index (worst ${worst.toExponential(3)}).`);
    console.error('Refusing to embed anything with it.');
    return false;
  }
  console.log(`\n  ${catalog.products.length} vectors reproduced exactly.`);
  return true;
}

if (process.argv.includes('--verify')) process.exit(verify() ? 0 : 1);

// ── add ──────────────────────────────────────────────────────────────────────

const addAt = process.argv.indexOf('--add');
const specPath = addAt === -1 ? null : process.argv[addAt + 1];
if (!specPath) {
  console.error('usage: node scripts/reindex-catalog.mjs --verify');
  console.error('       node scripts/reindex-catalog.mjs --add <product.json>');
  process.exit(1);
}

const spec = JSON.parse(readFileSync(resolve(specPath), 'utf8'));
for (const field of ['slug', 'name', 'description', 'price_cents']) {
  if (spec[field] == null) {
    console.error(`The product is missing "${field}".`);
    process.exit(1);
  }
}

console.log('\n[1/4] Verifying the engine reproduces the shipped index');
if (!verify()) process.exit(1);

// ── run the site's own db.js against catalog.sql ─────────────────────────────
//
// Same shims as regen-catalog-json.mjs. db.js is written for a browser and
// needs fetch, localStorage and a resolvable sql.js wasm.

console.log('\n[2/4] Loading catalog.sql through the site\'s db.js');

const localStorageStore = new Map();
globalThis.localStorage = {
  getItem: (k) => (localStorageStore.has(k) ? localStorageStore.get(k) : null),
  setItem: (k, v) => localStorageStore.set(k, String(v)),
  removeItem: (k) => localStorageStore.delete(k),
};

globalThis.fetch = async (url) => {
  const rel = String(url).replace(/^\.\//, '');
  if (rel !== 'catalog.sql') throw new Error(`unexpected fetch: ${url}`);
  return { ok: true, status: 200, text: async () => readFileSync(catalogSqlPath, 'utf8') };
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

const existing = JSON.parse(Catalog.toJson()).products;
if (existing.some((p) => p.slug === spec.slug)) {
  console.error(`${spec.slug} already exists in catalog.sql.`);
  process.exit(1);
}

// ── insert the product ───────────────────────────────────────────────────────

console.log(`\n[3/4] Embedding "${spec.name}"`);
const text = embedText(spec);
const vector = embed(text);
if (vector.length !== 384) {
  console.error(`embedding was ${vector.length} dims, expected 384.`);
  process.exit(1);
}
console.log(`    from: ${text}`);

// Insert through the site's own validated path rather than raw SQL: createProduct
// runs db.js's validation, which is the same validation the admin panel uses. A
// product inserted with hand-written SQL would bypass checks the site relies on.
const created = Catalog.createProduct({
  slug: spec.slug,
  name: spec.name,
  description: spec.description,
  details: spec.details ?? '',
  specs: JSON.stringify(spec.specs ?? {}),
  category: spec.category ?? 'General',
  price_cents: Number(spec.price_cents),
  image_url: spec.image_url ?? null,
  tint: spec.tint ?? null,
  in_stock: spec.in_stock !== false ? 1 : 0,
  sort_order: spec.sort_order ?? 100,
});

if (!created.ok) {
  console.error('The site rejected the product:');
  console.error(JSON.stringify(created.errors, null, 2));
  process.exit(1);
}

// replaceVectors re-embeds the WHOLE index from scratch, so it can never drift.
// The existing vectors are read back from catalog.json — which this script just
// proved the engine reproduces exactly — and re-passed with the new one.
const existingJson = JSON.parse(readFileSync(catalogJsonPath, 'utf8'));
const entries = existingJson.products.map((p) => {
  const raw = Buffer.from(p.vector, 'base64');
  return {
    slug: p.slug,
    vector: new Float32Array(raw.buffer, raw.byteOffset, raw.length / 4),
  };
});
entries.push({ slug: spec.slug, vector });
Catalog.replaceVectors(entries, Catalog.SEARCH_MODEL);

// ── write catalog.sql ────────────────────────────────────────────────────────

console.log('\n[4/4] Writing catalog.sql');
const sql = Catalog.toSql();
writeFileSync(catalogSqlPath, sql, 'utf8');

const after = JSON.parse(Catalog.toJson());
console.log(`    ${existing.length} -> ${after.products.length} products`);
console.log(`    all vectors present: ${after.products.filter((p) => p.vector).length}/${after.products.length}`);
console.log(`    searchable: ${Catalog.indexIsComplete()}`);

console.log('\nDone. Next:');
console.log('  node scripts/publish-catalog.mjs');

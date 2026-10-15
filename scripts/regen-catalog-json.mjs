#!/usr/bin/env node
/**
 * Regenerate the site's `catalog.json` by running the site's own `db.js`.
 *
 * WHY NOT REIMPLEMENT THE EXPORT
 * CATALOG-GUIDE.md §8 is emphatic that catalog.sql and catalog.json are
 * "generated from the same database by the same click, so they cannot
 * disagree, but they are two separate files in the repo and both must be
 * committed". Writing a second exporter here would break exactly that
 * guarantee — and silently, because the two would look fine until a field
 * drifted.
 *
 * So this drives the real thing: vendored sql.js + the real db.js, with
 * `fetch` and `localStorage` stubbed. The file it writes is byte-identical to
 * what the admin panel's **Download catalog.json** button produces.
 *
 * `localStorage` is stubbed as an empty Map on purpose. That makes
 * `hasDraft()` false, so `loadCatalogSource()` reads the committed
 * catalog.sql — the published catalog, not whatever draft happens to be in the
 * admin's browser. We want the published one.
 *
 * Usage:
 *   node scripts/regen-catalog-json.mjs                 # writes ../Store/catalog.json
 *   node scripts/regen-catalog-json.mjs --check         # verify, do not write
 *   node scripts/regen-catalog-json.mjs --out <path>
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const HERE = dirname(fileURLToPath(import.meta.url));
const APP = resolve(HERE, '..');
const STORE = resolve(APP, '..', 'Store');

const require = createRequire(import.meta.url);

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
const CHECK = process.argv.includes('--check');
const OUT = resolve(arg('out', resolve(STORE, 'catalog.json')));

// ── browser shims, installed before db.js is evaluated ─────────────────────

// localStorage: an empty Map. Makes hasDraft() false, so init() reads the
// committed catalog.sql rather than a browser-local draft.
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => void store.set(k, String(v)),
  removeItem: (k) => void store.delete(k),
  clear: () => store.clear(),
  key: () => null,
  get length() {
    return store.size;
  },
};

// fetch: only `./catalog.sql` is ever requested (CATALOG_URL in db.js).
globalThis.fetch = async (url) => {
  const rel = String(url).replace(/^\.\//, '');
  if (rel !== 'catalog.sql') throw new Error(`unexpected fetch: ${url}`);
  const body = readFileSync(resolve(STORE, 'catalog.sql'), 'utf8');
  return { ok: true, status: 200, text: async () => body };
};

// db.js resolves its wasm as `${SQLJS_BASE}${file}` where SQLJS_BASE is the
// relative './vendor/'. That works in a browser; in Node it has to be absolute,
// so wrap locateFile rather than relying on process.cwd().
const WASM = resolve(STORE, 'vendor', 'sql-wasm.wasm');
const loadSqlJs = require(resolve(STORE, 'vendor', 'sql-wasm.js'));
globalThis.initSqlJs = (opts = {}) => loadSqlJs({ ...opts, locateFile: () => WASM });

// db.js ends in `const Catalog = (() => {...})()`. `const` inside a Function
// body is function-local, not global, so capture it with an explicit return
// rather than reading globalThis.Catalog.
const dbSource = readFileSync(resolve(STORE, 'db.js'), 'utf8');
const Catalog = new Function(`${dbSource}\n;return Catalog;`)();

if (!Catalog) {
  console.error('db.js did not define Catalog');
  process.exit(1);
}

// ── run it ──────────────────────────────────────────────────────────────────

await Catalog.init();

if (!Catalog.isReady()) {
  console.error('Catalog.init() resolved but isReady() is false');
  process.exit(1);
}

const json = Catalog.toJson();
const parsed = JSON.parse(json); // a BOM or stray char must fail loudly here

// ── report ──────────────────────────────────────────────────────────────────

const products = parsed.products || [];
const withVector = products.filter((p) => p.vector);
const complete = Catalog.indexIsComplete();

console.log(`store          : ${parsed.store.name}`);
console.log(`products       : ${products.length}`);
console.log(`collections    : ${(parsed.collections || []).length}`);
console.log(`search_model   : ${parsed.search_model}`);
console.log(`index complete : ${complete}`);
console.log(`vectors present: ${withVector.length}/${products.length}`);
console.log(`payload        : ${(Buffer.byteLength(json) / 1024).toFixed(1)} KB`);

const problems = [];
if (!complete) problems.push('indexIsComplete() is false — rebuild the index in admin.html');
if (parsed.search_model !== Catalog.SEARCH_MODEL) problems.push('search_model does not match SEARCH_MODEL');
if (withVector.length !== products.length) {
  problems.push(`${products.length - withVector.length} product(s) have no vector — the app will refuse to search`);
}
for (const p of products) {
  if (!p.vector) continue;
  const dims = (Buffer.from(p.vector, 'base64').length) / 4;
  if (dims !== Catalog.SEARCH_DIMS) {
    problems.push(`'${p.slug}' vector decodes to ${dims} dims, expected ${Catalog.SEARCH_DIMS}`);
  }
}

if (problems.length) {
  console.error('\nNot publishable:');
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}

if (CHECK) {
  const current = readFileSync(OUT, 'utf8');
  if (current === json) {
    console.log(`\n${OUT} is up to date.`);
  } else {
    console.error(`\n${OUT} is stale. Run without --check to regenerate.`);
    process.exit(1);
  }
} else {
  writeFileSync(OUT, json, 'utf8');
  console.log(`\nWrote ${OUT}`);
}
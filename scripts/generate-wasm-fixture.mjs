#!/usr/bin/env node
/**
 * Generate the parity fixture by running the site's **actual WASM engine**.
 *
 * # WHY THIS EXISTS
 *
 * `scripts/extract-site-vectors.mjs` reads the vectors out of the site's
 * `catalog.sql`, on the assumption that they were produced by
 * `@ternlight/base@0.1.1` — the version `search.js` imports, and the string in
 * `product_vectors.model`. That assumption was never tested, and it is the
 * kind of thing that is quietly wrong: `catalog.json` and `catalog.sql` are
 * generated data, and the `model` column is a label, not a proof.
 *
 * This script removes the assumption. It loads the published WASM, embeds each
 * product's text with it, and writes those vectors as the fixture. The parity
 * test then compares the **native build against the engine the site actually
 * runs**, with `catalog.json` out of the loop entirely.
 *
 * It also cross-checks the fixture against the site's published vectors, and
 * reports the cosine. If those two ever disagree, the site's index was built
 * with a different engine than the one it now loads — which would mean every
 * vector in `catalog.sql` is stale relative to the running engine.
 *
 * @ternlight/base is MIT. See README.md "Third party".
 *
 * Usage:
 *   node scripts/generate-wasm-fixture.mjs
 *   node scripts/generate-wasm-fixture.mjs --check   # verify, do not write
 */

import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');
const STORE = resolve(REPO, '..', 'Store');
const OUT = resolve(REPO, 'rust', 'tests', 'fixtures', 'site_vectors.json');

const CHECK_ONLY = process.argv.includes('--check');
const EMBEDDING_DIMS = 384;

// The exact text the site's admin panel embeds. CATALOG-GUIDE.md §4.
const embeddingText = (p) => `${p.name}. ${p.category}. ${p.description || ''}`.trim();

// ── load the engine ─────────────────────────────────────────────────────────
//
// Three Windows/Node specifics, each of which costs a debugging round:
//
//   1. The package exports the web build under `/web`; the directory on disk is
//      `pkg-web`, and anything outside the `exports` map throws
//      ERR_PACKAGE_PATH_NOT_EXPORTED — including `pkg-web/tern_engine_bg.wasm`.
//   2. Node's ESM loader needs a `file://` URL. A bare `C:\...` parses as a URL
//      with scheme `c:` and is rejected.
//   3. The web build's default `init()` calls `fetch(module_or_path)`, and
//      Node's fetch has no `file:` scheme ("not implemented... yet...").
//      `init()` accepts an InitInput, so pass the wasm bytes and skip fetch.

const require = createRequire(import.meta.url);

function requireEngine() {
  try {
    return require.resolve('@ternlight/base/web');
  } catch {
    console.error('@ternlight/base is not installed.');
    console.error('  npm install @ternlight/base@0.1.1');
    console.error('  (dev-only: this script is not needed to build the app)');
    process.exit(1);
  }
}

const enginePath = requireEngine();
const { default: init, embed, config_summary } = await import(pathToFileURL(enginePath).href);
const { dirname: dirOf, join } = await import('node:path');
const wasmBytes = readFileSync(join(dirOf(enginePath), 'tern_engine_bg.wasm'));
await init({ module_or_path: wasmBytes });

const summary = config_summary();
console.log('engine  :', summary);
console.log('');

// ── sanity-check the engine against the site's own metadata ─────────────────

function headerField(field) {
  const m = new RegExp(`${field}=(\\d+)`).exec(summary);
  return m ? Number(m[1]) : null;
}

const dModel = headerField('d_model');
const outDim = headerField('output_dim');
const nHeads = headerField('n_heads');
const ffnDim = headerField('ffn_dim');

if (outDim !== EMBEDDING_DIMS) {
  console.error(`engine output_dim is ${outDim}, expected ${EMBEDDING_DIMS}`);
  process.exit(1);
}
console.log(`geometry: d_model=${dModel} n_heads=${nHeads} ffn_dim=${ffnDim} output_dim=${outDim}`);
console.log('');
console.log('NOTE: the published checkpoints on HuggingFace are all');
console.log('      d_model=256 n_heads=4 ffn_dim=1024. They are a DIFFERENT model');
console.log('      that happens to share the 384-dim output width, which is why a');
console.log('      mismatch never announces itself.');
console.log('');

// ── build the fixture ───────────────────────────────────────────────────────

const catalog = JSON.parse(readFileSync(resolve(STORE, 'catalog.json'), 'utf8'));

function dot(a, b) {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i] * b[i];
  return s;
}

const products = [];
const comparisons = [];

for (const p of catalog.products) {
  const text = embeddingText(p);
  const vec = Array.from(embed(text));

  if (vec.length !== EMBEDDING_DIMS) {
    console.error(`'${p.slug}': engine returned ${vec.length} dims, expected ${EMBEDDING_DIMS}`);
    process.exit(1);
  }

  // Cross-check against what the site published, if it published anything.
  if (typeof p.vector === 'string' && p.vector.length) {
    const buf = Buffer.from(p.vector, 'base64');
    const site = new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
    if (site.length === EMBEDDING_DIMS) {
      comparisons.push({ slug: p.slug, cosine: dot(vec, site) });
    }
  }

  products.push({
    slug: p.slug,
    name: p.name,
    category: p.category,
    description: p.description || '',
    text,
    vector: vec,
  });
}

console.log('product          cosine(engine, site-published)');
for (const c of comparisons) {
  console.log(`${c.slug.padEnd(16)} ${c.cosine.toFixed(8)}`);
}

const worst = comparisons.length ? Math.min(...comparisons.map((c) => c.cosine)) : null;
console.log('');

if (comparisons.length) {
  if (worst > 0.9999) {
    console.log('OK: the published engine reproduces the site vectors.');
    console.log('    catalog.json is trustworthy, and this fixture is ground truth.');
  } else if (worst > 0.5) {
    console.error(`WARNING: worst cosine ${worst.toFixed(6)}. Same family, different weights.`);
    console.error('  The site index was likely built with a different engine build than');
    console.error('  the one search.js loads. Treat catalog.sql vectors as stale.');
    process.exit(1);
  } else {
    console.error(`MISMATCH: worst cosine ${worst.toFixed(6)}.`);
    console.error('  The site vectors were NOT produced by this engine. Do not use them');
    console.error('  as ground truth — this fixture is the only valid reference.');
  }
}

const fixture = {
  _comment:
    'Generated by scripts/generate-wasm-fixture.mjs by running the published ' +
    '@ternlight/base@0.1.1 WASM engine — the same engine search.js loads. This is ' +
    'ground truth for the native port, independent of catalog.json. Do not hand-edit.',
  // `model` mirrors the site's SEARCH_MODEL and the `product_vectors.model`
  // column. parity.rs asserts it matches rust/src/api.rs, so all three must
  // agree before the vectors mean anything.
  model: catalog.search_model,
  source: '@ternlight/base@0.1.1 (WASM, pkg-web)',
  engine_summary: summary,
  dims: EMBEDDING_DIMS,
  products,
};

if (CHECK_ONLY) {
  console.log('--check: not writing.');
} else {
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(`Wrote ${OUT}`);
  console.log('');
  console.log('Next:  cd rust && cargo test --test parity');
}
#!/usr/bin/env node
/**
 * Patch the Store repo's `db.js` so `toJson()` ships product_vectors.
 *
 * WHY A SCRIPT AND NOT A TEXT EDIT
 * db.js contains \n, \r\n and \r\r\n line endings in the same file (154 / 44 /
 * 471 at time of writing). Any tool that matches on newlines silently fails to
 * find its anchor. CATALOG-GUIDE.md §10 says the same thing: patch this file
 * with Node using single-line anchors.
 *
 * WHAT IT CHANGES
 * catalog.json gains, per product, a `vector` field: the precomputed
 * ternlight embedding as base64, or null. Plus a top-level `search_model`.
 *
 * WHY BASE64 AND NOT A JSON ARRAY OF FLOATS
 * A Float32Array stringified to JSON is ~19 characters per element — 384 of
 * them is ~7 KB per product, ~58 KB for this catalog. The base64 blob is
 * 2048 characters, ~16 KB for the whole catalog, and it is already the
 * storage format in `product_vectors`, so there is one representation rather
 * than two that can disagree. It is also lossless: a float32 -> float64 ->
 * decimal -> float32 round trip is not, and this is the one artifact the whole
 * app's search correctness rests on.
 *
 * IDEMPOTENT. Re-running after the patch is a no-op.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TARGET = resolve(HERE, '..', '..', 'Store', 'db.js');

let src = readFileSync(TARGET, 'utf8');
const before = src;
let changed = 0;

function patch(anchor, replacement, label) {
  if (src.includes(replacement) && src.includes(anchor) === false) {
    console.log(`  = ${label} (already applied)`);
    return;
  }
  const occurrences = src.split(anchor).length - 1;
  if (occurrences !== 1) {
    throw new Error(`anchor for "${label}" matched ${occurrences} times, expected exactly 1`);
  }
  src = src.replace(anchor, replacement);
  changed++;
  console.log(`  + ${label}`);
}

// ── 1. Doc comment on toJson() ──────────────────────────────────────────────

patch(
  `   * The Flutter app fetches catalog.json from the site; it does not embed
   * sql.js or parse catalog.sql. Deliberately excludes product_vectors: those
   * are ternlight embeddings for the browser's own search and are useless to a
   * Dart client, and they would roughly triple the payload.`,
  `   * The Flutter app fetches catalog.json from the site; it does not embed
   * sql.js or parse catalog.sql, so this is the only file it can read.
   *
   * product_vectors ARE included, as base64 on each product as \`vector\`.
   * The app embeds its own queries with the same ternlight model compiled
   * natively via flutter_rust_bridge — Dart cannot host a WASM runtime, so it
   * cannot run the engine the way a browser does, but it does not need to: it
   * only needs the precomputed product side, which is this. Without them the
   * app has no way to rank anything.
   *
   * \`vector\` is null when that product has no embedding, or when the stored
   * one was built by a different encoder. Null is a meaningful value, not a
   * gap: the app checks it and refuses to search rather than silently
   * comparing vectors from two different models, which produces a plausible
   * but entirely wrong ranking. See CATALOG-GUIDE.md section 1.
   *
   * \`search_model\` at the top level names the encoder these vectors belong to.
   * It is the same string as SEARCH_MODEL and the \`model\` column, so all three
   * can be cross-checked.`,
  'toJson() doc comment',
);

// ── 2. Vector lookup, built once per export ─────────────────────────────────

patch(
  `    const products = all('SELECT * FROM products ORDER BY sort_order ASC, id ASC').map((p) => ({`,
  `    const vectorBySlug = new Map(
      all('SELECT slug, vector, model FROM product_vectors').map((r) => [r.slug, r]),
    );

    /**
     * This product's precomputed embedding as base64, or null.
     *
     * Null covers three cases that must not be conflated:
     *   - no vector row at all (the index was never built, or was built before
     *     this product was added) — indexIsComplete() is false and search is
     *     dead site-wide until you rebuild;
     *   - a vector built by a previous SEARCH_MODEL — completeness still reads
     *     true, so search silently matches the old text. This is the one that
     *     bites;
     *   - a blob that does not decode to SEARCH_DIMS floats, which means it is
     *     not a ternlight d384 vector at all.
     *
     * The length check is the cheap one. Decoding a foreign vector and shipping
     * it would let the app rank against numbers that mean something else.
     */
    function vectorFor(slug) {
      const row = vectorBySlug.get(slug);
      if (!row || row.model !== SEARCH_MODEL) return null;
      if (base64ToFloat32(row.vector).length !== SEARCH_DIMS) return null;
      return row.vector;
    }

    const products = all('SELECT * FROM products ORDER BY sort_order ASC, id ASC').map((p) => ({`,
  'vectorFor() helper',
);

// ── 3. Attach the vector to each product ────────────────────────────────────

patch(
  `      image_url: p.image_url || null,
      tint: p.tint || null,
    }));

    const collections = all('SELECT * FROM collections ORDER BY sort_order ASC, id ASC').map((c) => ({`,
  `      image_url: p.image_url || null,
      tint: p.tint || null,
      vector: vectorFor(p.slug),
    }));

    const collections = all('SELECT * FROM collections ORDER BY sort_order ASC, id ASC').map((c) => ({`,
  'product.vector field',
);

// ── 4. Name the model at the top level ──────────────────────────────────────

patch(
  `        products,
        collections,
      },`,
  `        products,
        collections,
        search_model: SEARCH_MODEL,
      },`,
  'search_model field',
);

if (src === before) {
  console.log('db.js already patched; nothing to do.');
  process.exit(0);
}

writeFileSync(TARGET, src, 'utf8');
console.log(`\nPatched ${TARGET} (${changed} change${changed === 1 ? '' : 's'})`);
console.log('Now run:  node build.mjs --check   (from the Store repo)');
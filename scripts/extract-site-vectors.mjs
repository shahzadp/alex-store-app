#!/usr/bin/env node
/**
 * Extract the site's precomputed product vectors out of `catalog.sql` and
 * write them as a JSON fixture the Rust parity harness can read.
 *
 * Why a script and not a test: the vectors are base64 float32 blobs that only
 * the site can produce, and they are the *only* ground truth we have for what
 * the engine is supposed to output. The Rust test needs them as data; SQL is
 * a bad container for that. Node is used because it is already required to run
 * the site's `build.mjs`, so this adds no toolchain.
 *
 * Why not just read catalog.sql from Rust: parsing SQLite string literals
 * (`''` escapes) and `||` concatenation by hand in two languages is how you
 * end up testing against a subtly wrong fixture. One parser, one language.
 *
 * Usage:
 *   node scripts/extract-site-vectors.mjs [--in <catalog.sql>] [--out <fixture.json>]
 *
 * Defaults assume the site repo sits next to this one:
 *   ../Store/catalog.sql  ->  rust/tests/fixtures/site_vectors.json
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');

/** Must match `SEARCH_MODEL` in the site's db.js and in rust/src/api.rs. */
const EXPECTED_MODEL = 'ternlight/base@0.1.1';
const EXPECTED_DIMS = 384;

// ── argv ─────────────────────────────────────────────────────────────────────

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const IN = resolve(arg('in', resolve(REPO, '..', 'Store', 'catalog.sql')));
const OUT = resolve(arg('out', resolve(REPO, 'rust', 'tests', 'fixtures', 'site_vectors.json')));

// ── minimal SQLite literal scanner ───────────────────────────────────────────
//
// Handles the three shapes catalog.sql actually uses: single-quoted strings
// with '' escapes, numbers, and NULL. Concatenation via || is resolved by the
// caller.

/** Scan one quoted string starting at the opening `'`. Returns [value, endIdx]. */
function scanString(sql, start) {
  let out = '';
  let i = start + 1;
  for (;;) {
    const c = sql[i];
    if (c === undefined) throw new Error('unterminated string literal');
    if (c === "'") {
      if (sql[i + 1] === "'") { out += "'"; i += 2; continue; }
      return [out, i + 1];
    }
    out += c;
    i++;
  }
}

/** Scan one bare token (number, NULL, or a concatenated blob) up to a separator. */
function scanBare(sql, start) {
  let i = start;
  while (i < sql.length && !',()'.includes(sql[i])) i++;
  return [sql.slice(start, i).trim(), i];
}

/** Parse one scalar starting at `i`, folding any `||` concatenation. */
function scanValue(sql, i) {
  const [first, j] = scanAtom(sql, i);
  let value = first;
  let k = j;

  // `||` concatenation. Folds quoted parts (the base64 blobs are split into
  // ~70-char chunks upstream) and bare numbers alike.
  for (;;) {
    let p = k;
    while (p < sql.length && /\s/.test(sql[p])) p++;
    if (sql.slice(p, p + 2) !== '||') break;
    const [part, after] = scanAtom(sql, p + 2);
    if (part === null) throw new Error(`NULL in a || concatenation near offset ${p}`);
    value += part;
    k = after;
  }
  return [value, k];
}

/** Parse one atom: a quoted string, NULL, or a bare number/token. */
function scanAtom(sql, start) {
  let i = start;
  while (i < sql.length && /\s/.test(sql[i])) i++;
  if (sql[i] === "'") return scanString(sql, i);

  const [raw, end] = scanBare(sql, i);
  if (raw.toUpperCase() === 'NULL') return [null, end];
  if (/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(raw)) return [Number(raw), end];
  return [raw, end];
}

/** Split `INSERT INTO <table> (...) VALUES <tuples>` into arrays of values. */
function parseInsert(sql, table) {
  const re = new RegExp(`INSERT\\s+INTO\\s+${table}\\s*\\(([^)]*)\\)\\s*VALUES`, 'i');
  const m = re.exec(sql);
  if (!m) throw new Error(`no INSERT INTO ${table} found`);
  const cols = m[1].split(',').map((c) => c.trim());

  let i = m.index + m[0].length;
  const rows = [];
  for (;;) {
    // Skip whitespace and the comma that separates one row from the next.
    while (i < sql.length && (/\s/.test(sql[i]) || sql[i] === ',')) i++;
    if (sql[i] !== '(') break;   // ';' or the next statement ends the INSERT

    i++;

    const vals = [];
    for (;;) {
      const [v, next] = scanValue(sql, i);
      vals.push(v);
      i = next;
      while (i < sql.length && /\s/.test(sql[i])) i++;
      if (sql[i] === ',') { i++; continue; }
      if (sql[i] === ')') { i++; break; }
      throw new Error(`unexpected '${sql[i]}' in ${table} row near offset ${i}`);
    }
    rows.push(Object.fromEntries(cols.map((c, k) => [c, vals[k]])));
  }
  return rows;
}

// ── main ─────────────────────────────────────────────────────────────────────

let sql;
try {
  sql = readFileSync(IN, 'utf8');
} catch (e) {
  console.error(`Cannot read ${IN}\n  ${e.message}`);
  console.error('Pass --in <path/to/catalog.sql>.');
  process.exit(1);
}

const products = parseInsert(sql, 'products');
const vectors = parseInsert(sql, 'product_vectors');

if (!products.length) { console.error('No products parsed from catalog.sql'); process.exit(1); }
if (!vectors.length) { console.error('No product_vectors parsed from catalog.sql'); process.exit(1); }

// The site's embedded text, verbatim. CATALOG-GUIDE.md §4. If the site ever
// changes this expression the vectors change and so does every search result.
const embeddingText = (p) => `${p.name}. ${p.category}. ${p.description || ''}`.trim();

const bySlug = new Map(vectors.map((v) => [v.slug, v]));

const problems = [];
const out = [];

for (const p of products) {
  const row = bySlug.get(p.slug);
  if (!row) {
    problems.push(`'${p.slug}' has no product_vectors row — search returns nothing site-wide`);
    continue;
  }
  if (row.model !== EXPECTED_MODEL) {
    problems.push(`'${p.slug}' is indexed by '${row.model}', expected '${EXPECTED_MODEL}'`);
    continue;
  }
  const buf = Buffer.from(row.vector, 'base64');
  const expectedBytes = EXPECTED_DIMS * 4;
  if (buf.length !== expectedBytes) {
    problems.push(`'${p.slug}' vector decodes to ${buf.length} bytes, expected ${expectedBytes}`);
    continue;
  }
  out.push({
    slug: p.slug,
    // The three parts, kept so the parity test can re-compose the embedded
    // text itself rather than trusting the string we stored. If the site's
    // expression ever changes, this catches the drift instead of hiding it
    // inside a fixture that would be regenerated to match.
    name: p.name,
    category: p.category,
    description: p.description || '',
    text: embeddingText(p),
    vector: Array.from(new Float32Array(buf.buffer, buf.byteOffset, EXPECTED_DIMS)),
  });
}

// Orphan vector rows: harmless for search (completeness only checks that every
// product HAS one) but they are the fingerprint of a product that was renamed.
for (const v of vectors) {
  if (!products.some((p) => p.slug === v.slug)) {
    problems.push(`product_vectors has '${v.slug}' but products does not — orphaned vector`);
  }
}

if (problems.length) {
  console.error('catalog.sql is not in a searchable state:');
  for (const p of problems) console.error(`  - ${p}`);
  console.error('\nSee CATALOG-GUIDE.md §1 before re-running.');
  process.exit(1);
}

const fixture = {
  _comment:
    'Generated by scripts/extract-site-vectors.mjs from the Store repo catalog.sql. ' +
    'Ground truth for the native/WASM parity test. Do not hand-edit.',
  model: EXPECTED_MODEL,
  dims: EXPECTED_DIMS,
  products: out,
};

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, `${JSON.stringify(fixture, null, 2)}\n`);

console.log(`Wrote ${out.length} vectors (${EXPECTED_DIMS} dims, ${EXPECTED_MODEL})`);
console.log(`  -> ${OUT}`);
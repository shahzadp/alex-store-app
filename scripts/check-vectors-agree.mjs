// Cross-check: the `vector` now in catalog.json must be byte-identical to the
// blob stored in catalog.sql. They come from the same table in the same
// database, so any difference means one of the two exports is lying.
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const STORE = resolve(HERE, '..', '..', 'Store');

const json = JSON.parse(readFileSync(resolve(STORE, 'catalog.json'), 'utf8'));
const sql = readFileSync(resolve(STORE, 'catalog.sql'), 'utf8');

// Scope to the product_vectors block. Both tables open rows with a quoted
// slug, so an unscoped search for `('stoneware-mug', '...')` happily matches
// the *products* INSERT first and silently compares against the product name.
const block = /INSERT INTO product_vectors \(slug, vector, model\) VALUES([\s\S]*?);/.exec(sql);
if (!block) {
  console.error('no INSERT INTO product_vectors in catalog.sql');
  process.exit(1);
}
const vectorBlock = block[1];

let ok = 0;
const bad = [];

for (const p of json.products) {
  const escaped = p.slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // The blob is one or more quoted chunks joined by `||`.
  const re = new RegExp(`\\('${escaped}',\\s*((?:'[^']*'\\s*\\|\\|\\s*)*'[^']*')\\s*,\\s*'([^']*)'`);
  const m = re.exec(vectorBlock);
  if (!m) { bad.push(`${p.slug}: no product_vectors row found in catalog.sql`); continue; }

  const b64 = [...m[1].matchAll(/'([^']*)'/g)].map((x) => x[1]).join('');

  if (b64 === p.vector) ok++;
  else bad.push(`${p.slug}: catalog.sql has ${b64.length} chars, catalog.json has ${p.vector.length}`);

  if (m[2] !== json.search_model) {
    bad.push(`${p.slug}: model tag in catalog.sql is '${m[2]}', catalog.json says '${json.search_model}'`);
  }
}

// And the reverse: nothing in the JSON that the SQL does not have.
const sqlSlugs = new Set(
  [...vectorBlock.matchAll(/\('([a-z0-9-]+)'/g)].map((x) => x[1]),
);

console.log(`byte-identical vectors : ${ok}/${json.products.length}`);
console.log(`product_vectors in sql : ${sqlSlugs.size}`);

const missing = json.products.filter((p) => !sqlSlugs.has(p.slug)).map((p) => p.slug);
if (missing.length) bad.push(`in catalog.json but not catalog.sql: ${missing.join(', ')}`);

if (bad.length) {
  console.error('\nMISMATCH:');
  for (const b of bad) console.error(`  - ${b}`);
  process.exit(1);
}
console.log('\nOK — catalog.json and catalog.sql agree.');
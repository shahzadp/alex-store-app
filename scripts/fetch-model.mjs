#!/usr/bin/env node
/**
 * Fetch the ternlight model weights and tokenizer.
 *
 * WHY THIS IS A SCRIPT
 * `model.bin` is 4.6 MB of binary that belongs in the repo only once. ternlight
 * itself does not commit it either — its build pipeline writes it into
 * `engine/assets/` before the wasm build, and publishes it as a release asset.
 * We do the same and record the checksum, so a clean clone is one command from
 * building.
 *
 # WHICH FILE
 * `model-int4.bin` from the `wenshutang/ternlight` HuggingFace repo. That is
 * the d384 int4 tier — the one `@ternlight/base@0.1.1` ships, and therefore the
 * one the site's `product_vectors` were computed with. The published
 * `model-int4.bin.json` carries the SHA-256 we verify against.
 *
 * Do not substitute `model-embedding-int8.bin` or `model-ternary.bin`: a `.bin`
 * packed for one embedding format cannot be read by an engine built for
 * another, and the vectors would become meaningless without any error.
 *
 * Usage:
 *   node scripts/fetch-model.mjs            # download and verify
 *   node scripts/fetch-model.mjs --check   # verify what is already there
 */

import { createWriteStream, existsSync, readFileSync, statSync, rmSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const HERE = dirname(fileURLToPath(import.meta.url));
const ASSETS = resolve(HERE, '..', 'rust', 'src', 'assets');

const BASE = 'https://huggingface.co/wenshutang/ternlight/resolve/main';

// Files, and what each one is. `tokenizer.json` is also committed upstream in
// the ternlight repo; we take HuggingFace's copy because it is the one that was
// paired with this checkpoint.
const FILES = {
  'model-int4.bin.json': `${BASE}/model-int4.bin.json`,
  'model.bin': `${BASE}/model-int4.bin`,
  'tokenizer.json': `${BASE}/tokenizer.json`,
};

const CHECK_ONLY = process.argv.includes('--check');

// ── helpers ─────────────────────────────────────────────────────────────────

const mib = (n) => `${(n / 1024 / 1024).toFixed(2)} MB`;

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

async function download(url, dest) {
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) throw new Error(`GET ${url} -> HTTP ${res.status}`);

  const tmp = `${dest}.part`;
  await pipeline(Readable.fromWeb(res.body), createWriteStream(tmp));
  return tmp;
}

// ── main ────────────────────────────────────────────────────────────────────

mkdirSync(ASSETS, { recursive: true });

// The manifest first: it is small and it tells us the checksum to verify
// against, so we never have to trust the big download blindly.
const manifestPath = resolve(ASSETS, 'model-int4.bin.json');
let manifest;
if (existsSync(manifestPath)) {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
} else {
  console.log('fetching model manifest...');
  const tmp = await download(FILES['model-int4.bin.json'], manifestPath);
  const { renameSync } = await import('node:fs');
  renameSync(tmp, manifestPath);
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
}

console.log(`model     : ${manifest.bin_path}`);
console.log(`format    : ${manifest.embedding_format} / weights ${manifest.weights_format}`);
console.log(`packed at : ${manifest.packed_at_iso}`);
console.log(`expected  : ${manifest.bin_bytes} bytes, sha256 ${manifest.bin_sha256}`);
console.log('');

if (manifest.embedding_format !== 'int4') {
  console.error(`Expected an int4 checkpoint for this engine build, got ${manifest.embedding_format}.`);
  process.exit(1);
}

let failures = 0;

for (const [name, url] of Object.entries(FILES)) {
  const dest = resolve(ASSETS, name);
  const exists = existsSync(dest);
  const isModel = name === 'model.bin';

  if (CHECK_ONLY && !exists) {
    console.error(`  MISSING  ${name}`);
    failures++;
    continue;
  }

  if (!exists) {
    process.stdout.write(`  fetching ${name} ... `);
    const tmp = await download(url, dest);
    const { renameSync } = await import('node:fs');
    renameSync(tmp, dest);
    console.log(`ok (${mib(statSync(dest).size)})`);
  } else {
    console.log(`  present  ${name} (${mib(statSync(dest).size)})`);
  }

  // Only the model carries a published checksum. The tokenizer is verified by
  // the engine itself — `Tokenizer::from_bytes` panics on a malformed asset, so
  // a bad download fails loudly at first embed rather than silently producing
  // different token ids.
  if (isModel) {
    const actual = sha256(dest);
    const expected = manifest.bin_sha256;
    if (actual !== expected) {
      console.error(`\n  CHECKSUM MISMATCH for ${name}`);
      console.error(`    expected ${expected}`);
      console.error(`    actual   ${actual}`);
      rmSync(dest, { force: true });
      failures++;
    } else {
      console.log('           sha256 verified');
    }

    const size = statSync(dest).size;
    if (size !== manifest.bin_bytes) {
      console.error(`\n  SIZE MISMATCH: got ${size} bytes, expected ${manifest.bin_bytes}`);
      rmSync(dest, { force: true });
      failures++;
    }
  }
}

console.log('');
if (failures) {
  console.error(`${failures} problem(s). Re-run without --check to re-download.`);
  process.exit(1);
}
console.log(`Assets in ${ASSETS}`);
console.log('Next:  cd rust && cargo test');
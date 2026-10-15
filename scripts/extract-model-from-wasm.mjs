#!/usr/bin/env node
/**
 * Extract the exact model file from the @ternlight/base WASM.
 *
 * # WHY THIS EXISTS
 *
 * The engine embeds `include_bytes!` of a model built from
 * `training/pack/out/d384/model-int4.bin` (see the `build` script in
 * @ternlight/base's package.json). That artefact is not published, so
 * `model.bin` has to be recovered out of the published WASM.
 *
 * # THE TRAP: THE FILE IS NOT THE MEMORY
 *
 * The obvious approach — find the `TERN` magic in the .wasm and slice from
 * there — produces a file that is wrong in a way nothing detects. It loads,
 * passes `verify_sha256` (because the scripts recompute the hash), and returns
 * unit-length vectors.
 *
 * The reason is that a WASM data segment is laid out in the FILE as
 *
 *     [flags][offset expression][size][payload]
 *
 * so consecutive segments are separated by their own headers. The engine never
 * sees those separators: it reads LINEAR MEMORY, where the payloads are placed
 * at their declared addresses. The `TERN` magic sits in one 21-byte segment and
 * the weights in the next, and slicing the file across that boundary splices in
 * eleven bytes of WASM scaffolding.
 *
 * Two wrong answers came out of this, and both had to be undone:
 *
 *   1. Slicing the file: the 11 inter-segment bytes (`41 98 ef c1 00 0b b5 c3
 *      c9 03`) land in the middle of the model. Earlier this was even mistaken
 *      for the header's `reserved` field — but `format.py` says those 10 bytes
 *      are zero-padding, and in memory they genuinely are.
 *   2. "Correcting" for it by treating the embedding as 30,521 rows: also
 *      wrong. Those 192 bytes are the zeroed first row of the embedding table,
 *      which `encode_embedding_int4` emits via `q[0].zero_()`. They are part of
 *      the packed table, and `compute_layout`'s arithmetic is exactly right.
 *
 * # HOW THE ADDRESS IS FOUND
 *
 * Not guessed. `format.rs::verify_sha256` panics unless the final 32 bytes are
 * the SHA-256 of everything before them, so the model has a
 * cryptographically-checkable length. Reconstructing memory and scanning for
 * the address whose 7,492,280-byte body hashes to the 32 bytes that follow it
 * lands on 1,078,968 exactly — and nothing else does.
 *
 * Usage:
 *   node scripts/extract-model-from-wasm.mjs           # write model.bin
 *   node scripts/extract-model-from-wasm.mjs --check    # verify, do not write
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, '..', 'rust', 'src', 'assets', 'model.bin');
const CHECK_ONLY = process.argv.includes('--check');

const HEADER = 32, SHA = 32;
// compute_layout's total for d_model=384, ffn=1536, out=384, vocab=30522.
const EXPECTED_BODY = 7_492_280;

function loadWasm() {
  const require = createRequire(import.meta.url);
  let pkg;
  try { pkg = require.resolve('@ternlight/base/web'); }
  catch {
    console.error('@ternlight/base is not installed.  npm install');
    process.exit(1);
  }
  return readFileSync(join(dirname(pkg), 'tern_engine_bg.wasm'));
}

const wasm = loadWasm();

// ── section table ──────────────────────────────────────────────────────────
function uleb(buf, at) {
  let result = 0, shift = 0, byte;
  do { byte = buf[at++]; result += (byte & 0x7f) * 2 ** shift; shift += 7; } while (byte & 0x80);
  return [result, at];
}

function sectionRange(idWanted) {
  let pos = 8;
  while (pos < wasm.length) {
    const id = wasm[pos++];
    let size; [size, pos] = uleb(wasm, pos);
    const start = pos, end = start + size;
    if (id === idWanted) return [start, end];
    pos = end;
  }
  return null;
}

// ── linear memory from the data section ─────────────────────────────────────
function buildMemory() {
  const range = sectionRange(11); // 11 = data
  if (!range) throw new Error('no data section');
  let pos = range[0];
  let count; [count, pos] = uleb(wasm, pos);
  const mem = new Map();
  for (let i = 0; i < count; i++) {
    let flags; [flags, pos] = uleb(wasm, pos);
    if (flags === 2) { let d; [d, pos] = uleb(wasm, pos); }
    let offset = null, op;
    do {
      op = wasm[pos++];
      if (op === 0x41 || op === 0x23) { let d; [d, pos] = uleb(wasm, pos); offset = d; }
    } while (op !== 0x0b);
    let size; [size, pos] = uleb(wasm, pos);
    if (offset !== null) for (let k = 0; k < size; k++) mem.set(offset + k, wasm[pos + k]);
    pos += size;
  }
  return mem;
}

const mem = buildMemory();
const readMem = (addr, n) => Buffer.from(Array.from({ length: n }, (_, i) => mem.get(addr + i) ?? 0));

// ── find the model by its own SHA-256 ──────────────────────────────────────
// Candidate addresses: the start of any data segment, plus a small window
// around them in case the linker padded. The hash does the selecting.
const addresses = new Set();
{
  const range = sectionRange(11);
  let pos = range[0];
  let count; [count, pos] = uleb(wasm, pos);
  for (let i = 0; i < count; i++) {
    let flags; [flags, pos] = uleb(wasm, pos);
    if (flags === 2) { let d; [d, pos] = uleb(wasm, pos); }
    let offset = null, op;
    do {
      op = wasm[pos++];
      if (op === 0x41 || op === 0x23) { let d; [d, pos] = uleb(wasm, pos); offset = d; }
    } while (op !== 0x0b);
    let size; [size, pos] = uleb(wasm, pos);
    if (offset !== null) {
      for (let delta = 0; delta <= 256; delta += 8) addresses.add(offset - delta);
      addresses.add(offset + size);
    }
    pos += size;
  }
}
addresses.delete(0);
// must start with the magic
const candidates = [...addresses].filter((a) => a >= 0 && readMem(a, 4).toString('latin1') === 'TERN');

console.log(`memory has ${mem.size} bytes; ${candidates.length} candidate addresses start with TERN`);

let found = null;
for (const addr of candidates) {
  const body = readMem(addr, EXPECTED_BODY);
  const tail = readMem(addr + EXPECTED_BODY, SHA);
  if (createHash('sha256').update(body).digest().equals(tail)) { found = { addr, body, tail }; break; }
}

if (!found) {
  console.error('\nno address in memory hashes to the 32 bytes that follow it.');
  console.error('the engine would panic on verify_sha256, so one must exist — widen the search.');
  process.exit(1);
}

console.log(`\nmodel located at memory ${found.addr}`);
console.log(`  body ${found.body.length} bytes + 32 SHA = ${found.body.length + SHA}`);
console.log(`  sha256 ${createHash('sha256').update(found.body).digest('hex').slice(0, 32)}...`);

// Sanity: header must agree with the engine's own config_summary.
const hdr = {
  magic: found.body.subarray(0, 4).toString('latin1'),
  version: found.body.readUInt16LE(4),
  embFmt: found.body[6],
  weightsFmt: found.body[7],
  vocab: found.body.readUInt32LE(8),
  dModel: found.body.readUInt16LE(12),
  nLayers: found.body[14],
  nHeads: found.body[15],
  ffn: found.body.readUInt16LE(16),
  out: found.body.readUInt16LE(18),
  maxSeq: found.body.readUInt16LE(20),
  reserved: found.body.subarray(22, 32),
};
const reservedZero = hdr.reserved.every((b) => b === 0);
console.log(`  header: reserved ${reservedZero ? 'all zero (as format.py requires)' : `NOT zero: ${hdr.reserved.toString('hex')}`}`);

// Embedding row 0 is zeroed by the packer, which is why 192 zero bytes follow
// the header. Check it, because it is what made a correct file look shifted.
const row0 = readMem(found.addr + HEADER, hdr.dModel / 2);
console.log(`  embedding row 0 all zero: ${row0.every((b) => b === 0)} (192 bytes)`);

const model = Buffer.concat([found.body, found.tail]);

if (CHECK_ONLY) {
  const cur = readFileSync(OUT);
  console.log(`\n--check: model.bin ${cur.equals(model) ? 'matches' : 'DIFFERS'}`);
} else {
  writeFileSync(OUT, model);
  console.log(`\nwrote ${OUT} (${model.length} bytes)`);
  console.log('next: cd rust && cargo test --test parity');
}
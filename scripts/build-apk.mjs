#!/usr/bin/env node
/**
 * Build the Android APK.
 *
 * Wraps the toolchain steps in the right order, and fails loudly at the first
 * one that is missing rather than emitting a confusing cargo or gradle error.
 *
 * Pipeline:
 *   1. flutter_rust_bridge_codegen   Rust <-> Dart bindings
 *   2. cargo-ndk / rustup targets    libalex_store_native.so for each ABI
 *   3. flutter build apk             Dart AOT + packages the .so
 *
 * Android targets only. arm64 covers essentially every real device; armv7 and
 * x86_64 are buildable but see README — the engine currently has no NEON path,
 * and armv7 is 32-bit.
 *
 * Usage:
 *   node scripts/build-apk.mjs                 # release, universal APK
 *   node scripts/build-apk.mjs --split         # per-ABI APKs
 *   node scripts/build-apk.mjs --debug
 *   node scripts/build-apk.mjs --abis arm64-v8a
 */

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const RUST = resolve(ROOT, 'rust');

const argv = process.argv.slice(2);
const has = (flag) => argv.includes(flag);
const value = (flag, fallback) => {
  const i = argv.indexOf(flag);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : fallback;
};

const MODE = has('--debug') ? 'debug' : 'release';
const SPLIT = has('--split');
const TARGET_PLATFORM = value('--target-platform', 'android-arm64');

// Which Rust target backs each Flutter Android ABI.
const ABI_TARGETS = {
  'android-arm64': 'aarch64-linux-android',
  'android-arm': 'armv7-linux-androideabi',
  'android-x64': 'x86_64-linux-android',
};
const ABIS = value('--abis', 'android-arm64').split(',').map((s) => s.trim());

// ── helpers ─────────────────────────────────────────────────────────────────

let step = 0;
function heading(text) {
  step++;
  console.log(`\n[${step}] ${text}`);
}

function run(cmd, args, opts = {}) {
  console.log(`    ${cmd} ${args.join(' ')}`);
  const res = spawnSync(cmd, args, {
    stdio: 'inherit',
    shell: process.platform === 'win32',
    cwd: opts.cwd ?? ROOT,
    env: { ...process.env, ...opts.env },
  });
  if (res.status !== 0) {
    console.error(`\n${cmd} failed with exit code ${res.status}`);
    process.exit(res.status ?? 1);
  }
}

function which(cmd) {
  const probe = spawnSync(process.platform === 'win32' ? 'where' : 'which', [cmd], { encoding: 'utf8' });
  return probe.status === 0;
}

function need(cmd, hint) {
  if (which(cmd)) return;
  console.error(`\nMissing required tool: ${cmd}`);
  if (hint) console.error(`  ${hint}`);
  process.exit(1);
}

// ── preflight ───────────────────────────────────────────────────────────────

console.log('Alex Store — Android build');
console.log(`mode ${MODE}${SPLIT ? ', split per ABI' : ''}, ABIs: ${ABIS.join(', ')}`);

need('flutter', 'Install Flutter: https://docs.flutter.dev/get-started/install');
need('cargo', 'Install Rust: https://rustup.rs');

// The model must exist before cargo runs: include_bytes! is a compile-time
// failure, and the error message points at the include rather than at the
// missing download.
const modelBin = resolve(RUST, 'src', 'assets', 'model.bin');
if (!existsSync(modelBin)) {
  console.error('\nMissing rust/src/assets/model.bin');
  console.error('  Run:  node scripts/fetch-model.mjs');
  process.exit(1);
}

// ── 1. codegen ──────────────────────────────────────────────────────────────

heading('Generating flutter_rust_bridge bindings');
run('flutter', ['pub', 'get']);
run('flutter_rust_bridge_codegen', ['generate']);

// ── 2. native library ───────────────────────────────────────────────────────

heading('Building libalex_store_native.so');
for (const abi of ABIS) {
  const target = ABI_TARGETS[abi];
  if (!target) {
    console.error(`\nUnknown ABI '${abi}'. Expected one of: ${Object.keys(ABI_TARGETS).join(', ')}`);
    process.exit(1);
  }
  console.log(`  ${abi} -> ${target}`);
}

// cargo-ndk drives cargo with the NDK clang wrappers for each target in one
// pass, which is the supported way to cross-compile without setting
// CARGO_TARGET_*_LINKER by hand.
need('cargo-ndk', 'Install:  cargo install cargo-ndk');

run(
  'cargo',
  [
    'ndk',
    '-t',
    ABIS.map((a) => ABI_TARGETS[a]).join(','),
    '-o',
    'android/jniLibs',
    'build',
    '--release',
    '--features',
    'frb,emb_int4',
  ],
  { cwd: RUST },
);

// ── 3. APK ──────────────────────────────────────────────────────────────────

heading('Building the APK');
const flutterArgs = ['build', 'apk', '--target-platform', TARGET_PLATFORM, '--' + MODE];
if (SPLIT) flutterArgs.push('--split-per-abi');
if (!has('--debug')) flutterArgs.push('--release');
run('flutter', flutterArgs);

console.log(`
Done. Output:
  build/app/outputs/flutter-apk/     universal
  build/app/outputs/flutter-apk/*-*   split per ABI

MEMORY.md §3: the APK is published as a GitHub *release* asset, never
committed to the repo. Use the \`latest\` tag so the URL never changes:

  gh release create v<version> build/app/outputs/flutter-apk/alex-store.apk
  # then, in the Store repo:
  #   build.config.json -> apkUrl, node build.mjs
`);
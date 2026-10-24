#!/usr/bin/env node
/**
 * Build the Android APK.
 *
 * Wraps the toolchain steps in the right order, and fails loudly at the first
 * one that is missing rather than emitting a confusing cargo or gradle error.
 *
 * Pipeline:
 *   2. cargo (GNU host toolchain)        libalex_store_native.so per ABI
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
import * as crypto from 'node:crypto';
import * as fs from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const REPO = ROOT;
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

// Which Rust target backs each Flutter Android ABI, and — separately — what the
// folder inside android/app/src/main/jniLibs has to be called.
//
// These two sets of names are NOT the same and conflating them breaks the
// build. Flutter calls the platform "android-arm64" and cargo calls the target
// "aarch64-linux-android", but the jniLibs folder must be named after the
// Android ABI, "arm64-v8a". Writing the .so into jniLibs/android-arm64/
// produces a Gradle failure that reads:
//
//   out extracted from path ...\out\android-arm64\libalex_store_native.so
//   is not an ABI
//
// which looks like a packaging problem rather than a naming one.
const ABI_TARGETS = {
  'android-arm64': 'aarch64-linux-android',
  'android-arm': 'armv7-linux-androideabi',
  'android-x64': 'x86_64-linux-android',
};
const ABI_DIRS = {
  'android-arm64': 'arm64-v8a',
  'android-arm': 'armeabi-v7a',
  'android-x64': 'x86_64',
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
if (!fs.existsSync(modelBin)) {
  console.error('\nMissing rust/src/assets/model.bin');
  console.error('  Run:  node scripts/extract-model-from-wasm.mjs');
  process.exit(1);
}

// ── 1. native library ───────────────────────────────────────────────────────

heading('Building libalex_store_native.so');
for (const abi of ABIS) {
  const target = ABI_TARGETS[abi];
  const dir = ABI_DIRS[abi];
  if (!target || !dir) {
    console.error(`\nUnknown ABI '${abi}'. Expected one of: ${Object.keys(ABI_TARGETS).join(', ')}`);
    process.exit(1);
  }
  console.log(`  ${abi} -> ${target} -> jniLibs/${dir}`);
}

// No `flutter_rust_bridge_codegen` step, and no `cargo-ndk`. The bridge is
// hand-written (rust/src/ffi.rs + lib/src/services/native_engine.dart), so
// there is nothing to generate, and rust/.cargo/config.toml already points each
// Android target at the NDK's clang, which is all cargo-ndk would have done.
//
// The host toolchain must be the GNU one: MSVC has no link.exe on this machine,
// and cargo needs to build host build scripts even when the target is Android.
const HOST_TOOLCHAIN = 'stable-x86_64-pc-windows-gnu';
const JNI_DIR = resolve(REPO, 'android', 'app', 'src', 'main', 'jniLibs');

for (const abi of ABIS) {
  const target = ABI_TARGETS[abi];
  const dir = ABI_DIRS[abi];
  run(
    'cargo',
    [`+${HOST_TOOLCHAIN}`, 'build', '--release', '--target', target],
    { cwd: RUST },
  );

  const outDir = resolve(RUST, 'target', target, 'release');
  const built = resolve(outDir, 'libalex_store_native.so');
  if (!fs.existsSync(built)) {
    console.error(`\nExpected ${built} to exist after building ${target}.`);
    process.exit(1);
  }
  const dest = resolve(JNI_DIR, dir);
  fs.mkdirSync(dest, { recursive: true });
  fs.copyFileSync(built, resolve(dest, 'libalex_store_native.so'));
  console.log(`  copied to ${resolve(dest, 'libalex_store_native.so').slice(ROOT.length + 1)}`);
}

// Remove any jniLibs folder that is not a real Android ABI. A folder left from
// a previous run with the wrong name (see ABI_DIRS above) makes Gradle fail on
// every subsequent build, even a correct one, because it merges whatever is in
// jniLibs/ rather than only what this run produced.
const VALID_ABIS = new Set(Object.values(ABI_DIRS));
if (fs.existsSync(JNI_DIR)) {
  for (const entry of fs.readdirSync(JNI_DIR, { withFileTypes: true })) {
    if (!entry.isDirectory() || VALID_ABIS.has(entry.name)) continue;
    fs.rmSync(resolve(JNI_DIR, entry.name), { recursive: true, force: true });
    console.log(`  removed stale jniLibs/${entry.name} (not an Android ABI)`);
  }
}

// ── 2. APK ──────────────────────────────────────────────────────────────────

heading('Building the APK');
run('flutter', ['pub', 'get']);
const flutterArgs = ['build', 'apk', '--target-platform', TARGET_PLATFORM, '--' + MODE];
if (SPLIT) flutterArgs.push('--split-per-abi');
if (!has('--debug')) flutterArgs.push('--release');
run('flutter', flutterArgs);

// ── 2b. Drop the duplicate ──────────────────────────────────────────────────
//
// A build produces the APK TWICE, and they are byte-identical:
//
//   build/app/outputs/apk/<mode>/app-<mode>.apk   written by Gradle
//   build/app/outputs/flutter-apk/app-<mode>.apk  copied there by Flutter
//
// Flutter's own copy is the canonical one, because that is the path the docs,
// MEMORY.md and any release step name. The Gradle copy is an intermediate that
// nothing downstream reads, and leaving it in place means every build silently
// doubles to 55MB of identical APK on disk.
//
// This asserts they really are identical before deleting, so if Flutter ever
// changes that arrangement the build fails loudly instead of discarding work.
const flutterOut = resolve(ROOT, 'build', 'app', 'outputs', 'flutter-apk');
const gradleOut = resolve(ROOT, 'build', 'app', 'outputs', 'apk');

if (fs.existsSync(gradleOut)) {
  const sha256 = (p) => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');

  let removed = 0, kept = 0;
  for (const entry of fs.readdirSync(gradleOut, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const gradleMode = resolve(gradleOut, entry.name);
    for (const file of fs.readdirSync(gradleMode)) {
      if (!file.endsWith('.apk')) continue;
      const a = resolve(gradleMode, file);
      const b = resolve(flutterOut, file);
      if (!fs.existsSync(b)) continue;
      if (sha256(a) !== sha256(b)) {
        console.warn(`  kept  outputs/apk/${entry.name}/${file} — differs from the flutter-apk copy`);
        kept++;
        continue;
      }
      fs.rmSync(a);
      console.log(`  removed outputs/apk/${entry.name}/${file} (identical to the flutter-apk copy)`);
      removed++;
    }
    if (fs.readdirSync(gradleMode).length === 0) fs.rmdirSync(gradleMode);
  }
  if (removed > 0) {
    heading('One APK, one place');
    console.log(`  removed ${removed} duplicate; kept ${kept}\n`);
  }
}

console.log(`
Done. Output:
  build/app/outputs/flutter-apk/app-${MODE}.apk

MEMORY.md §3: the APK is published as a GitHub *release* asset, never
committed to the repo. The asset must be named alex-store.apk, because
that is the name the Store's apkUrl ends in:

  .../releases/latest/download/alex-store.apk

\`gh release create <path>#<name>\` does NOT rename the asset. The #<name>
becomes its display *label*; the file keeps its own basename. Uploading
app-${MODE}.apk straight from the build output therefore publishes a
release whose download URL 404s while the release page looks correct.
Stage it under the right name first:

  cp build/app/outputs/flutter-apk/app-${MODE}.apk /tmp/alex-store.apk
  gh release create v<version> /tmp/alex-store.apk --title "Alex Store v<version>" --notes-file <notes>

Bump \`version\` in pubspec.yaml before that. An equal versionCode is the
same version to the installer, so the release never reaches anyone still
on the previous build.

The Store needs no rebuild: apkUrl uses the \`latest\` alias, so it follows
the newest release on its own. Rebuild only if apkUrl itself moves.
`);
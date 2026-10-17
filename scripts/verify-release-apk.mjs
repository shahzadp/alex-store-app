#!/usr/bin/env node
/**
 * Verify that the built release APK is what the build claims it is.
 *
 * `flutter build apk --release` succeeding proves the build ran. It does not
 * prove the artifact is signed with the release key rather than the debug one,
 * that R8 actually ran, or — the question this file exists to answer — that
 * obfuscation did not break the native semantic search. All of those are silent
 * failures: a mis-signed or search-broken APK builds cleanly and only misbehaves
 * on a device, which is the worst place to find out.
 *
 * Every expectation is read from the repository rather than hard-coded here, so
 * this cannot drift out of step with the thing it is checking:
 *
 *   * the FFI symbol names come from lib/src/services/native_engine.dart — add a
 *     symbol to the engine and this checks it automatically
 *   * the expected signing certificate comes from docs/assetlinks.json
 *   * the expected model hashes come from rust/src/assets/model-from-wasm.json
 *
 * Run it after scripts/build-apk.mjs:
 *
 *   node scripts/verify-release-apk.mjs
 *   node scripts/verify-release-apk.mjs --apk path/to/other.apk
 *
 * Exits non-zero if any check fails.
 */

import { spawnSync } from 'node:child_process';
import * as crypto from 'node:crypto';
import * as fs from 'node:fs';
import * as os from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');

const argv = process.argv.slice(2);
const flagValue = (flag, fallback) => {
  const i = argv.indexOf(flag);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : fallback;
};

const APK_PATH = resolve(ROOT, flagValue('--apk', 'build/app/outputs/flutter-apk/app-release.apk'));
const NATIVE_ENGINE_DART = resolve(ROOT, 'lib/src/services/native_engine.dart');
const ASSETLINKS = resolve(ROOT, 'docs/assetlinks.json');
const MODEL_JSON = resolve(ROOT, 'rust/src/assets/model-from-wasm.json');
const MODEL_BIN = resolve(ROOT, 'rust/src/assets/model.bin');
const SPLASH_DART = resolve(ROOT, 'lib/src/screens/splash_screen.dart');
const MAPPING_DIR = resolve(ROOT, 'build/app/outputs/mapping/release');

// The debug keystore's certificate. It is a public file — every Android SDK
// install has the same one and its password is "android" — so an APK signed
// with it can be forged by anyone, and Android will treat the forgery as a
// legitimate update.
const DEBUG_FINGERPRINT =
  '5CE34089F17240D55A4519A7ADDEA8FF0B0F24BD2876D525AA1EE5EA394388D2';

// apksigner prints digests without separators; keytool, assetlinks.json and
// everyone who reads them use colons. Normalise before comparing or the check
// fails on formatting rather than on substance.
const normaliseFingerprint = (value) => value.replace(/[^0-9a-fA-F]/g, '').toUpperCase();

// ── reporting ───────────────────────────────────────────────────────────────

const results = [];
let failures = 0;

function record(name, ok, detail = '') {
  if (!ok) failures++;
  results.push({ name, ok });
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${name}`);
  if (detail) console.log(`         ${detail}`);
}

function info(name, detail) {
  results.push({ name, ok: true, informational: true });
  console.log(`  [info] ${name}`);
  if (detail) console.log(`         ${detail}`);
}

const heading = (text) => console.log(`\n${text}`);
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

// ── tools ───────────────────────────────────────────────────────────────────

function sdkRoot() {
  const local = resolve(ROOT, 'android/local.properties');
  if (fs.existsSync(local)) {
    for (const line of fs.readFileSync(local, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^\s*sdk\.dir\s*=\s*(.+?)\s*$/);
      // Java properties escape the separator: `sdk.dir=D:\\android-sdk`.
      if (m) return m[1].replace(/\\\\/g, '\\');
    }
  }
  return process.env.ANDROID_SDK_ROOT || process.env.ANDROID_HOME || null;
}

/** Newest directory under `parent`, by version-ish sort. */
function newestDir(parent) {
  if (!parent || !fs.existsSync(parent)) return null;
  const names = fs
    .readdirSync(parent, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' }));
  return names.length ? join(parent, names[names.length - 1]) : null;
}

function buildToolsFile(name) {
  const sdk = sdkRoot();
  const bt = newestDir(sdk && join(sdk, 'build-tools'));
  const p = bt && join(bt, name);
  return p && fs.existsSync(p) ? p : null;
}

function findLlvmNm() {
  const sdk = sdkRoot();
  const ndk = newestDir(sdk && join(sdk, 'ndk'));
  if (!ndk) return null;
  const host = { win32: 'windows-x86_64', darwin: 'darwin-x86_64', linux: 'linux-x86_64' }[
    process.platform
  ];
  const nm = join(
    ndk,
    'toolchains',
    'llvm',
    'prebuilt',
    host,
    'bin',
    process.platform === 'win32' ? 'llvm-nm.exe' : 'llvm-nm',
  );
  return fs.existsSync(nm) ? nm : null;
}

function javaExe() {
  if (process.env.JAVA_HOME) {
    const p = join(process.env.JAVA_HOME, 'bin', process.platform === 'win32' ? 'java.exe' : 'java');
    if (fs.existsSync(p)) return p;
  }
  return 'java';
}

function run(cmd, args) {
  const res = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  return { status: res.status, stdout: res.stdout ?? '', stderr: res.stderr ?? '', error: res.error };
}

// ── checks ──────────────────────────────────────────────────────────────────

function main() {
  console.log('Alex Store — release APK verification');
  console.log(`apk: ${APK_PATH}`);

  if (!fs.existsSync(APK_PATH)) {
    console.error(`\nNo APK at ${APK_PATH}\nRun:  node scripts/build-apk.mjs`);
    process.exit(1);
  }
  info('artifact', `${(fs.statSync(APK_PATH).size / 1024 / 1024).toFixed(2)} MB`);

  // Unpack. tar ships with Windows 10+ and sniffs the format from content, so it
  // does not care that the extension is .apk rather than .zip.
  const work = fs.mkdtempSync(join(os.tmpdir(), 'alex-apk-verify-'));
  const tar = run('tar', ['-xf', APK_PATH, '-C', work]);
  if (tar.status !== 0) {
    console.error(`\nCould not unpack the APK with tar.\n${tar.stderr || tar.error}`);
    process.exit(1);
  }

  try {
    const minSdk = apkMinSdk();
    checkSignature(minSdk);
    checkAbiConsistency(work);
    const symbols = ffiSymbols();
    checkR8Ran(symbols);
    checkNativeLibrary(work, symbols);
    checkDartKeptSymbolStrings(work, symbols);
    checkModel(work);
    checkSplash(work);
    checkPluginRegistration(work);
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }

  const graded = results.filter((r) => !r.informational);
  heading(`${graded.length - failures}/${graded.length} checks passed`);
  if (failures) {
    console.log(`\n${failures} FAILED. Do not publish this APK.`);
    process.exit(1);
  }
  console.log('\nThe release APK is signed, obfuscated, and still has a working search path.');
}

function apkMinSdk() {
  const aapt2 = buildToolsFile(process.platform === 'win32' ? 'aapt2.exe' : 'aapt2');
  if (!aapt2) return null;
  const m = run(aapt2, ['dump', 'badging', APK_PATH]).stdout.match(/minSdkVersion:'(\d+)'/);
  return m ? Number(m[1]) : null;
}

function checkSignature(minSdk) {
  heading('Signing');

  const jar = buildToolsFile(join('lib', 'apksigner.jar'));
  if (!jar) {
    record('apksigner available', false, 'no build-tools/lib/apksigner.jar under the SDK');
    return;
  }

  // Run the jar directly rather than apksigner.bat: no cmd.exe quoting to get
  // wrong, and the wrapper only exists to find java anyway.
  const res = run(javaExe(), ['-jar', jar, 'verify', '--verbose', '--print-certs', APK_PATH]);
  const out = `${res.stdout}\n${res.stderr}`;
  if (!/\bVerifies\b/i.test(out)) {
    record('apksigner verify', false, out.trim().split('\n').slice(0, 4).join(' / '));
    return;
  }

  const digests = [...out.matchAll(/certificate SHA-256 digest:\s*([0-9a-fA-F:]+)/g)].map((m) =>
    normaliseFingerprint(m[1]),
  );
  if (!digests.length) {
    record('signing certificate readable', false, 'apksigner printed no SHA-256 digest');
    return;
  }
  const actual = digests[0];

  // The expected fingerprint is the one docs/assetlinks.json publishes for App
  // Links, so a mismatch means the APK and that file disagree — a real bug in
  // whichever of the two is stale, and in the file's case a silent break of deep
  // linking.
  const expected = JSON.parse(fs.readFileSync(ASSETLINKS, 'utf8'))
    .flatMap((e) => e.target.sha256_cert_fingerprints ?? [])
    .map(normaliseFingerprint);

  record(
    'signed with the key published in docs/assetlinks.json',
    expected.includes(actual),
    expected.includes(actual)
      ? actual.replace(/(..)(?=..)/g, '$1:').replace(/:$/, '')
      : `apk:      ${actual}\nexpected: ${expected.join('\n          ') || '(none listed)'}`,
  );

  record('not signed with the public Android debug key', actual !== DEBUG_FINGERPRINT);

  const schemePresent = (n) =>
    new RegExp(`Verified using v${n} scheme[^:]*:\\s*true`, 'i').test(out);

  // v2 is what every device from Android 7.0 up actually verifies.
  record('APK Signature Scheme v2', schemePresent(2));

  // v3 carries the signing key's rotation history; without it, changing the key
  // later means every existing install has to be removed first.
  const v3 = schemePresent(3);
  record(
    'APK Signature Scheme v3 (key-rotation history)',
    v3,
    v3 ? '' : 'rotating this signing key later would need every install removed first',
  );

  // v1 (JAR signing) is only consulted below API 24, so whether it should be
  // here depends entirely on minSdk. Checking both directions is what stops this
  // from quietly asserting the wrong thing.
  const v1 = schemePresent(1);
  if (minSdk === null) {
    info('minSdk unknown', 'aapt2 unavailable, so the v1 requirement was not checked');
  } else if (minSdk >= 24) {
    record(
      `v1 signing correctly omitted at minSdk ${minSdk}`,
      !v1,
      v1 ? 'v1 is present but unnecessary above API 24' : '',
    );
  } else {
    record(`v1 signing present for minSdk ${minSdk} (pre-API-24)`, v1, v1 ? '' : 'Android 6 cannot install this APK');
  }

  info('signer', `CN=${out.match(/certificate DN:.*?CN=([^,]+)/)?.[1] ?? '?'}${minSdk !== null ? `, minSdk ${minSdk}` : ''}`);
}

/** Every ABI the APK advertises must actually be runnable. */
function checkAbiConsistency(work) {
  heading('Packaged ABIs');

  const libDir = join(work, 'lib');
  const abis = fs.existsSync(libDir)
    ? fs.readdirSync(libDir).filter((d) => fs.statSync(join(libDir, d)).isDirectory())
    : [];
  record('APK contains native libraries', abis.length > 0, abis.join(', ') || 'no lib/<abi>/ at all');
  if (!abis.length) return;

  // This is the check that catches a dishonest APK. Plugins ship prebuilt native
  // code for every ABI they support — path_provider pulls in jni_flutter, whose
  // libdartjni.so covers arm64, armv7 and x86_64 — and Gradle merges those
  // directories in even when Flutter was told to build one ABI. Android reads
  // the result as "this APK runs on armv7", installs it there, and the app dies
  // at launch because libflutter.so was never built for that ABI. A directory
  // holding only a plugin's stub library is a crash waiting for the right phone.
  for (const abi of abis) {
    const files = fs.readdirSync(join(libDir, abi));
    const hasEngine = files.includes('libflutter.so') && files.includes('libapp.so');
    record(
      `lib/${abi} has both libflutter.so and libapp.so`,
      hasEngine,
      hasEngine ? `also: ${files.filter((f) => !f.startsWith('libflutter') && !f.startsWith('libapp')).join(', ')}` : `only: ${files.join(', ')}`,
    );

    const hasSearch = files.includes('libalex_store_native.so');
    record(
      `lib/${abi} has the semantic search engine`,
      hasSearch,
      hasSearch ? '' : 'this ABI installs and browses but has no native search',
    );
  }
}

/** The symbol names the Dart side looks up, read from the binding itself. */
function ffiSymbols() {
  const src = fs.readFileSync(NATIVE_ENGINE_DART, 'utf8');
  const names = [...src.matchAll(/lookupFunction<[^>]*>\(\s*'([^']+)'\s*\)/g)].map((m) => m[1]);
  return [...new Set(names)];
}

function checkR8Ran(symbols) {
  heading('R8 / shrinking');

  const mapping = join(MAPPING_DIR, 'mapping.txt');
  for (const [label, file] of [
    ['mapping.txt written', mapping],
    ['usage.txt written', join(MAPPING_DIR, 'usage.txt')],
    ['seeds.txt written', join(MAPPING_DIR, 'seeds.txt')],
  ]) {
    record(label, fs.existsSync(file), fs.existsSync(file) ? '' : `missing: ${file}`);
  }
  if (!fs.existsSync(mapping)) return;

  const text = fs.readFileSync(mapping, 'utf8');
  const lines = text.split(/\r?\n/);
  // A class line reads `com.example.Foo -> a.b.c:`. Renamed means left != right.
  const classLines = lines.filter((l) => /^\S.* -> \S+:$/.test(l));
  const renamed = classLines.filter((l) => {
    const [lhs, rhs] = l.split(' -> ');
    return lhs.trim() !== rhs.replace(/:$/, '').trim();
  });
  record(
    'classes were actually obfuscated',
    renamed.length > 0,
    `${renamed.length} of ${classLines.length} classes renamed`,
  );

  // The direct evidence for the argument in proguard-rules.pro. Match the exact
  // FFI symbol names, not a loose /alex_\w+/ — the application id contains
  // `alex_store`, which a loose pattern flags and which is not the FFI surface.
  const touched = symbols.filter((s) => text.includes(s));
  record(
    'R8 never saw an FFI symbol name',
    touched.length === 0,
    touched.length ? `mapping.txt mentions: ${touched.join(', ')}` : `${symbols.length} symbols checked, none appear in R8's output`,
  );
}

/** Locate the packaged engine and its ABI. */
function findEngine(work) {
  const libDir = join(work, 'lib');
  if (!fs.existsSync(libDir)) return null;
  for (const abi of fs.readdirSync(libDir)) {
    const p = join(libDir, abi, 'libalex_store_native.so');
    if (fs.existsSync(p)) return { abi, path: p, buf: fs.readFileSync(p) };
  }
  return null;
}

function checkNativeLibrary(work, symbols) {
  heading('Native engine (dart:ffi)');

  const engine = findEngine(work);
  record('libalex_store_native.so packaged', !!engine, engine ? `lib/${engine.abi}/` : 'not found in any ABI directory');
  if (!engine) return;

  const soBuf = engine.buf;
  info('engine', `${(soBuf.length / 1024 / 1024).toFixed(2)} MB, ${engine.abi}`);

  // Nothing may be code-signed away: this is Rust, and R8 has no input to it.
  const isElf = soBuf[0] === 0x7f && soBuf.subarray(1, 4).toString('ascii') === 'ELF';
  record('the packaged .so is a real ELF', isElf, isElf ? '' : 'not an ELF header — packaging is wrong');

  // Every symbol the Dart side will ask for must be exported. This is the check
  // that obfuscation did not touch the engine: it could not have, but the point
  // is that a claim like that is worth exactly as much as the check behind it.
  const nm = findLlvmNm();
  if (!nm) {
    record('llvm-nm available', false, 'no NDK under the Android SDK');
    return;
  }
  const res = run(nm, ['--dynamic', '--defined-only', engine.path]);
  const exported = new Set(
    res.stdout
      .split(/\r?\n/)
      .map((l) => l.trim().split(/\s+/).pop())
      .filter(Boolean),
  );
  const missing = symbols.filter((s) => !exported.has(s));
  record(
    `all ${symbols.length} FFI symbols exported from the .so`,
    missing.length === 0,
    missing.length ? `missing: ${missing.join(', ')}` : symbols.join(', '),
  );
}

function checkDartKeptSymbolStrings(work, symbols) {
  heading('Dart AOT snapshot');

  const libDir = join(work, 'lib');
  const snapshots = [];
  if (fs.existsSync(libDir)) {
    for (const abi of fs.readdirSync(libDir)) {
      const p = join(libDir, abi, 'libapp.so');
      if (fs.existsSync(p)) snapshots.push({ abi, buf: fs.readFileSync(p) });
    }
  }
  if (!snapshots.length) {
    record('libapp.so present', false, 'no Dart AOT snapshot in the APK');
    return;
  }

  // R8 is not the shrinker that could break the search path — Dart's own AOT
  // tree-shaker is. `lookupFunction('alex_search')` passes a runtime string, so
  // the literal has to survive into the snapshot, and it is stored in whichever
  // of Dart's two string encodings the compiler picked. Search both.
  for (const { abi, buf } of snapshots) {
    const missing = symbols.filter(
      (s) =>
        !buf.includes(Buffer.from(s, 'latin1')) && !buf.includes(Buffer.from(s, 'utf16le')),
    );
    record(
      `libapp.so (${abi}) still carries all ${symbols.length} symbol names`,
      missing.length === 0,
      missing.length
        ? `missing: ${missing.join(', ')} — Dart removed a runtime lookup`
        : 'the strings the FFI resolves at runtime survived AOT compilation',
    );
  }
}

function checkModel(work) {
  heading('Model weights');

  if (!fs.existsSync(MODEL_BIN)) {
    info('model.bin absent locally', 'skipped; run scripts/extract-model-from-wasm.mjs to restore it');
    return;
  }

  const model = fs.readFileSync(MODEL_BIN);

  // The strongest available statement about the model, and it needs no external
  // reference: the file ends with the SHA-256 of everything before it, and
  // rust/src/engine/format.rs::verify_sha256 recomputes exactly that when the
  // engine loads. If this holds, the engine accepts this file as correct.
  const body = model.subarray(0, model.length - 32);
  const tail = model.subarray(model.length - 32);
  const bodyHash = crypto.createHash('sha256').update(body).digest();
  record(
    'model.bin matches its own embedded SHA-256',
    bodyHash.equals(tail),
    bodyHash.equals(tail) ? `body ${body.length} bytes -> ${bodyHash.toString('hex')}` : 'the file is corrupt',
  );

  // And that the provenance record agrees, so it cannot rot into a file that
  // describes a model nobody has (which is what it was doing before).
  const json = JSON.parse(fs.readFileSync(MODEL_JSON, 'utf8'));
  record(
    'model-from-wasm.json describes this exact file',
    json.sha256 === sha256(model) && json.bytes === model.length,
    `sha256 ${sha256(model).slice(0, 16)}…, ${model.length} bytes`,
  );

  // The weights are `include_bytes!`d into the library rather than shipped as a
  // Flutter asset, which is precisely why R8's resource shrinker is not a threat
  // to them — but only if they really are in there.
  const engine = findEngine(work);
  if (!engine) return;
  const at = engine.buf.indexOf(model);
  record(
    'model weights are embedded in the packaged .so',
    at >= 0,
    at >= 0 ? `found at offset ${at}` : 'the 7 MB model is not in the shipped library',
  );
}

/** The launch video's path inside the bundle, as the app itself names it. */
function splashAssetPath() {
  const m = fs.readFileSync(SPLASH_DART, 'utf8').match(/defaultAsset\s*=\s*'([^']+)'/);
  return m ? m[1] : null;
}

/**
 * The launch video, and only that.
 *
 * This is here because `isShrinkResources = true` is on in app/build.gradle.kts.
 * Flutter assets are bundled as plain files rather than as Android resources, so
 * the resource shrinker has no business touching them — but a splash whose video
 * has been dropped is a black screen on launch, which is both the worst possible
 * first impression and the sort of thing that only ever appears on a device.
 * Reading the asset back out and hashing it is cheap and settles it.
 */
function checkSplash(work) {
  heading('Launch video');

  const assetPath = splashAssetPath();
  if (!assetPath) {
    record('SplashScreen names its video', false, 'no defaultAsset in lib/src/screens/splash_screen.dart');
    return;
  }

  const source = resolve(ROOT, assetPath);
  if (!fs.existsSync(source)) {
    record('the launch video is in the repository', false, `missing ${assetPath}`);
    return;
  }

  const packaged = join(work, 'assets', 'flutter_assets', assetPath);
  if (!fs.existsSync(packaged)) {
    record('the launch video is in the APK', false, `no ${assetPath} under assets/flutter_assets`);
    return;
  }

  const shipped = fs.readFileSync(packaged);

  // Every MP4 opens with a `ftyp` box at offset 4. A placeholder, an empty file
  // left by a failed copy, or an HTML error page all fail this.
  record(
    'the packaged video is a real MP4',
    shipped.length > 12 && shipped.toString('latin1', 4, 8) === 'ftyp',
    shipped.length > 12 ? `${(shipped.length / 1024).toFixed(0)} KB, brand ${shipped.toString('latin1', 8, 12).trim()}` : 'too short',
  );

  record(
    'the packaged video is the repository\'s video, byte for byte',
    sha256(shipped) === sha256(fs.readFileSync(source)),
    sha256(shipped).slice(0, 32) + '…',
  );
}

function checkPluginRegistration(work) {
  heading('Plugin registration (reached reflectively)');

  const dexes = fs
    .readdirSync(work)
    .filter((f) => /^classes\d*\.dex$/.test(f))
    .map((f) => join(work, f));
  record('DEX files present', dexes.length > 0, `${dexes.length} dex`);
  if (!dexes.length) return;

  const blob = Buffer.concat(dexes.map((d) => fs.readFileSync(d)));
  const has = (s) => blob.includes(Buffer.from(s, 'latin1'));

  // Flutter's GeneratedPluginRegister does
  //   Class.forName("io.flutter.plugins.GeneratedPluginRegistrant")
  //     .getDeclaredMethod("registerWith", FlutterEngine.class)
  // so both names have to survive byte for byte. If either is obfuscated, no
  // plugin registers: the app opens and browses, but WhatsApp links, the offline
  // catalog and deep links all silently stop working — and none of that looks
  // like an obfuscation bug.
  record(
    'GeneratedPluginRegistrant kept its name (Class.forName target)',
    has('io/flutter/plugins/GeneratedPluginRegistrant'),
    'reached only by name; a rename here disables every plugin with no error',
  );
  record('the registerWith method name survives (getDeclaredMethod target)', has('registerWith'));

  // Manifest-declared, so AGP generates a keep rule for it from aapt_rules.txt.
  record(
    'MainActivity kept its name (manifest entry point)',
    has('io/github/shahzadp/alex_store/MainActivity'),
    'renamed here and the launcher icon does nothing',
  );
}

main();

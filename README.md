# Alex Store — Android app

The Flutter app for [shahzadp.github.io/store](https://shahzadp.github.io/store).

Reads the same `catalog.json` the website serves, and does semantic search
**on device** using ternlight compiled to native Rust instead of WebAssembly.

---

## The official download, and how to check it

The only official copies of this app are published from this repository: the
storefront at <https://shahzadp.github.io/store>, and the release asset its
button points at,
`https://github.com/shahzadp/alex-store-app/releases/latest/download/alex-store.apk`.

Anything else offering "Alex Store" - another site, a mirror, an APK forwarded in
a chat - is not from here. That warning is worth stating because the usual signals
prove nothing: the name, the icon and the shop's WhatsApp number are all public,
so a convincing fake is made of exactly the same parts as the real thing.

Two things do prove authenticity, and both are cheap:

- The APK is signed with the key whose SHA-256 fingerprint is recorded in
  `docs/assetlinks.json`:

  ```
  DA:5B:48:50:1D:CE:D4:5D:35:C7:5B:EC:8D:F0:D8:45:CF:8E:2C:19:4B:FC:D8:A6:DD:ED:AB:9B:D1:02:1A:C2
  ```

  `apksigner verify --print-certs <file>.apk` prints it. A different key means it
  is not this app - and Android refuses to install anything signed with a
  different key *as an update* to a copy already installed, so an impostor cannot
  reach an existing install at all.
- `node scripts/verify-release-apk.mjs` checks every release against that
  fingerprint and against `docs/assetlinks.json`, and fails on anything else. The
  published APK is the one that passed.

## Why the Rust part exists

The website runs [ternlight](https://github.com/soycaporal/ternlight) — a
1.58-bit BitNet-style sentence encoder — compiled to WASM, and ships the
resulting product embeddings inside `catalog.sql`. Visitors embed only their own
query.

Dart cannot host a WebAssembly runtime, so the app cannot do that. Three ways
out, and why this one:

| Option | Verdict |
| --- | --- |
| Lexical search over `catalog.json` | Cheapest. MEMORY.md §6 calls it "the better trade" for eight products, and for eight products it may well be. But it cannot answer "something to drink out of". |
| A different, ONNX-runnable model | Works in Dart, but forces a **full reindex of the site** and gives up the model the vectors were built with. |
| **The same ternlight engine, compiled natively** | Chosen. Same weights, same tokenizer, same forward pass — so the app ranks with exactly the vectors the site publishes, offline, with no model download at query time. |

ternlight is MIT and the engine is plain Rust; only its `#[wasm_bindgen]` surface
is WebAssembly-specific. `rust/src/engine/` is vendored **byte-for-byte
unmodified** from upstream.

## Layout

```
lib/
  main.dart                     app entry, CatalogScope
  src/
    models/
      catalog.dart              Catalog, Store, Product, Collection
      price.dart                integer paisa -> "Rs 7,800"
    services/
      catalog_service.dart      fetch, cache, validate, map hits -> products
      search_engine.dart        the SearchEngine interface
      rust_search_engine.dart   dart:ffi binding to the native engine
      whatsapp.dart             wa.me links, plus the two-toned button label
      launcher.dart             external URL opening
      deep_link_service.dart    storefront links -> the matching product
    screens/                    home, shop, product, search, splash
    widgets/
      product_card.dart        the card, with the grid that sizes it
      product_image.dart       image + the placeholder every product uses
      skeleton.dart            loading placeholders shaped like the content
      states.dart              empty, error and "nothing matched" states
    theme.dart                  the site's palette, type scale, card metrics

assets/
  splash/alex-store.mp4         the launch video (see "The launch video")

rust/
  Cargo.toml
  src/
    lib.rs                      module wiring + compile-time guards  (ours)
    index.rs                    product vector index and ranking     (ours)
    ffi.rs                       the C ABI Dart calls               (ours)
    engine/                     vendored from ternlight, unmodified
    assets/                     tokenizer.json (committed); model.bin (fetched)

scripts/
  publish-catalog.mjs           ONE command: rebuild vectors, bump, publish
  regen-catalog-json.mjs        run the site's own db.js in Node to re-export
  check-vectors-agree.mjs       catalog.json and catalog.sql must agree
  bump-site-version.mjs         cache-buster bump + rebuild the site
  extract-model-from-wasm.mjs   recover + SHA-256 verify the model weights
  extract-site-vectors.mjs      pull vectors out of catalog.sql -> test fixture
  check-vendor-clean.mjs        vendored engine must match upstream, byte for byte
  build-apk.mjs                 cargo -> jniLibs -> flutter build apk
  verify-release-apk.mjs        prove the built APK is signed, obfuscated, searchable
  render-launcher-icons.mjs     assets/icon/app_icon.svg -> the Android mipmaps
  reference-forward.mjs         independent JS port of the engine's forward pass
  patch-store-catalog-json.mjs  one-shot patch of the site's db.js
  generate-wasm-fixture.mjs     regenerate the parity fixture from the site WASM

test/                           Dart tests: domain, theme, grid, links
docs/
  CATALOG-WORKFLOW.md           how to change the catalog and publish it
  APP-LINKS.md                  how to make links open the app automatically
  assetlinks.json               the file to publish, and its warnings
```

## Building

```bash
npm install                            # dev-only, for the scripts below
node scripts/extract-model-from-wasm.mjs   # once; recovers + verifies SHA-256
node scripts/build-apk.mjs
```

Prerequisites: Flutter, Rust **with the `stable-x86_64-pc-windows-gnu` host
toolchain** and the `aarch64-linux-android` target *installed for that
toolchain*, plus the Android SDK and NDK. `rustup` keeps targets per toolchain,
so a target present under `msvc` does not help the GNU one.

No codegen step and no `cargo install`. The Dart boundary is hand-written:
`rust/src/ffi.rs` and `lib/src/services/native_engine.dart` are a matched pair.
`flutter_rust_bridge` was tried first and abandoned; MEMORY.md section 6 records why.

Outputs land in `build/app/outputs/flutter-apk/`.

### Release signing and R8

Release builds are signed with `android/app/release-keystore.jks`, read through
`android/key.properties`. Neither file is committed (`.gitignore` covers both),
so a fresh clone cannot produce a release APK — the build stops with instructions
rather than quietly falling back to something else.

That fallback is what this project used before, and it is worth spelling out why
it was wrong. The Android debug keystore is a public file whose password is
literally `android`, so a "release" APK signed with it can be re-signed by anyone
and Android accepts the forgery as an official update. It also cannot be upgraded
past: Android refuses to install an update whose signing key differs, so every
install of a debug-signed build has to be removed before a properly-signed one
will go on. Release builds carry APK Signature Scheme v3 as well as v2, so *this*
key can be rotated later without that surgery.

R8 then shrinks and obfuscates the Java/Kotlin bytecode. It cannot affect the
semantic search path, and `android/app/proguard-rules.pro` sets out why at
length: R8 only rewrites JVM bytecode, whereas search is `dart:ffi` — Dart
resolves ten symbols out of `libalex_store_native.so` from string literals at
runtime, and `rust/src/ffi.rs` exports them as plain `extern "C"` with no JNI, so
there is no class or method name in the search path for R8 to rename. The rules
file is almost empty on purpose.

None of that is left as an assertion:

```bash
node scripts/build-apk.mjs
node scripts/verify-release-apk.mjs
```

The verifier reads its expectations out of the repository rather than carrying
its own copies, and checks the built artifact: the signing certificate against
`docs/assetlinks.json`; that R8 ran *and* never saw an FFI symbol name; that
every symbol in `native_engine.dart` is both exported by the `.so` and still
present as a string in the Dart AOT snapshot; that the model is embedded
byte-for-byte and matches its own checksum; that every packaged ABI has a real
Flutter engine behind it; that `GeneratedPluginRegistrant` — which Flutter
looks up with `Class.forName`, so a rename would silently disable every plugin —
kept its name; and that the packaged manifest still disables backups and
cleartext, trusts only the system CA store, and exports only the components it
has to.

### Network, backups and exported components

The manifest sets three things explicitly, because each one fails silently when
it regresses:

| Setting | Value | What it prevents |
| --- | --- | --- |
| `android:allowBackup` | `false` (with `fullBackupContent="false"`) | The OS backup agent uploading the cached catalog and voucher state, and `adb backup` pulling them out |
| `android:usesCleartextTraffic` | `false` | Plain HTTP if `targetSdk` ever moves; the network config repeats the rule |
| `android:networkSecurityConfig` | `res/xml/network_security_config.xml` | Cleartext on any domain, and trust anchors beyond the system store |

The app has exactly one network origin — `https://shahzadp.github.io/store` — and
everything else (the search engine, the model, the launch video) is inside the
APK. There is no local dev server, so the config has no exception to carve out.
The catalog is the product data shown to shoppers, which is why the trust
anchors are the system store only: a proxy certificate cannot rewrite prices or
stock.

`allowBackup="false"` is a deliberate trade. Moving to a new phone will not carry
the cached catalog or the "voucher already claimed" flag; the catalog refetches
on first launch, and the voucher is a welcome offer rather than state worth
backing up.

Only two components are exported, and both are required:

- `MainActivity` — the launcher icon and the `https://shahzadp.github.io/store`
  app-link filter.
- `androidx.profileinstaller.ProfileInstallReceiver` — merged in by Flutter, and
  guarded by `android.permission.DUMP`, which is signature/privileged.

Everything else is `exported="false"`: `WebViewActivity` from `url_launcher`,
`androidx.startup.InitializationProvider`, and any future plugin component.
`scripts/verify-release-apk.mjs` reads all of this back out of the packaged
manifest and fails on a third exported component, a missing permission on the
profile receiver, or a `debuggable` release build.

### `model.bin` is not in this repository

A fresh clone has no weights, and `cargo build` fails on `include_bytes!` until
you fetch them:

```bash
node scripts/extract-model-from-wasm.mjs
```

It rebuilds the file out of `@ternlight/base`'s WASM. It does **not** download
HuggingFace's `model-int4.bin`: that is a different model (d256 internally) which
happens to produce the same 384-dim output width, and the site's vectors were not
built with it.

The recovery is not a slice, and the obvious version of it is a trap worth
knowing about. A WASM data segment is laid out in the file as
`[flags][offset][size][payload]`, but the engine reads **linear memory**, where
the payloads sit contiguously at their declared addresses. So cutting the file at
the `TERN` magic splices segment headers into the weights. The result still
loads, still returns unit-length vectors, and still passes a checksum the
extractor itself recomputed — it is simply wrong, and nothing downstream can
tell. The script rebuilds linear memory from the data section and chooses the
candidate address by requiring the 32 bytes *after* the body to be its SHA-256.

What makes this safe is that the model carries its own checksum: the last 32
bytes hash everything before them, and
`rust/src/engine/format.rs::verify_sha256` recomputes exactly that at load. A
corrupted or half-recovered file cannot get far enough to produce a ranking.
`--check` re-derives the file and compares it against what is on disk.

7.5 MB of binary in permanent git history for an artifact that is obtainable and
verifiable is a poor trade, and the Store repo's MEMORY.md §3 makes the same
argument about the APK. `tokenizer.json` (694 KB) *is* committed, because it is
upstream source rather than a build artifact.

### The parity test

`rust/tests/parity.rs` is the reason the native port is trustworthy. It reads
the vectors the **site** publishes, re-derives them from the same product text
using the native engine, and asserts:

- per-dimension agreement within `1e-3`;
- cosine ≥ `0.9999` per product;
- identical **ranking order** for ten natural-language queries the index was
  never built from.

The tolerance is not zero and cannot be: the WASM build accumulates the BitLinear
matmul in 16-lane `i32` SIMD, the native build walks ternlight's scalar
fallback, so the summation order differs. The bound is far tighter than any
semantic difference — two different models score cosine < 0.9 — so it catches a
model swap or tokenizer change, and ignores rounding.

Regenerate the fixture after any catalog or model change:

```bash
node scripts/extract-site-vectors.mjs
```

## The launch video

The app opens with a video — the same title animation the storefront uses — rather
than the blank Android window the Flutter template ships. `assets/splash/alex-store.mp4`
is the published render of `AlexStore.tsx` in the Remotion project
(`Remotion/src/compositions/AlexStore`), 1080x1920, 30 fps, 150 frames, with its
audio.

Three things are worth knowing about how it is wired.

**It is an overlay, not a route.** `SplashScreen` is stacked above `MaterialApp`'s
navigator via `builder:` in `lib/main.dart`, so `home` is built on the very first
frame underneath it. The catalog fetch and the whole home layout therefore happen
*while* the video plays, and the reveal is instant. A pushed route would hold the
fetch back for the length of the clip and then show a loading state — the opposite
of what a splash is for.

**The fade is the composition's own.** `AlexStore.tsx` fades out over frames
140→150; `SplashScreen.defaultFadeOut` is that same 333 ms, so the overlay
dissolves at the speed the video fades and the hand-off is one continuous fade
rather than a cut. `test/splash_test.dart` fails if the two ever disagree.

**The Android window is the same gradient.** The video's opening frame is a
`#f5f3ff → #fdf2f8 → #ecfeff` wash. `res/values/colors.xml` holds those three
stops and `res/drawable/launch_background.xml` paints them, so the few hundred
milliseconds before Flutter starts are the same surface as the first frame rather
than a white — or, in dark mode, black — flash. `res/values-v31/` and
`res/values-night-v31/` do the same for Android 12's system splash, which reads
`windowSplashScreenBackground` instead of `windowBackground`, and also set that
splash's *icon* to a blank drawable (`res/drawable/splash_icon.xml`). Left alone,
Android draws the app's launcher icon there — the shop's mark, motionless — and
the video then animates the same mark, which reads as the same drawing twice,
once dead. The video's opening frame has no logo in it, so the backdrop alone is
what actually continues into the film. `splash_test.dart` asserts the XML and the
Dart backdrop carry the same three values.

**Nothing here can strand a user.** A video that will not load, a decoder that
reports an error and a playback that stalls all fall through to the next screen;
the splash is never why the app did not open. That path is tested directly.

Cost: the clip is 1.1 MB, and `video_player` brings ExoPlayer (media3) in on
Android. The APK went from 27.5 MB to 29.3 MB, of which 1.1 MB is the video
itself; R8 shrinks the rest. `scripts/verify-release-apk.mjs` checks the video
came out the other side byte for byte, because `isShrinkResources = true` is on,
and that the system splash has no icon in it.

## The site side

`catalog.json` did not used to carry vectors — they lived only in `catalog.sql`,
and MEMORY.md §6 left "decide app search" open partly because of it. They are
now included, as base64 on each product, via
`scripts/patch-store-catalog-json.mjs`.

Base64 rather than a JSON array of floats: a `Float32Array` stringified to JSON
is ~19 characters per element, so 384 dims is ~7 KB per product against 2 KB for
base64. It is also lossless, and it is already the storage format in
`product_vectors`, so there is one representation rather than two that can
drift.

Cost: `catalog.json` went from 6.9 KB to 22.9 KB.

`scripts/regen-catalog-json.mjs` regenerates it by **running the site's real
`db.js`** under Node with `fetch` and `localStorage` stubbed, so the file is
byte-identical to what the admin panel's *Download catalog.json* produces.
Reimplementing the export here would break the guarantee in CATALOG-GUIDE.md §8
that the two catalog files cannot disagree.

`catalog.json` also carries the shop's refund policy, appended to the end of every
product's `details` by the same patched `db.js`
(`scripts/patch-store-refund-policy.mjs`). It is one sentence — "Once an order has
been dispatched, a cancellation fee applies." — because the rest of the policy
belongs on the About page, not in small print under a description. It is carried
there because this app renders exactly three per-product text fields and `details`
is the only one that is neither embedded for search nor pasted into the WhatsApp
order message, so it is the only field that can put a policy in front of someone
who already has the app installed. `description` was out twice over: appending to
it would change the vector of every product and put a policy in every order
message. `specs` is a label/value table. No vector is affected, nothing needs
re-indexing, and no Dart file changed: the sentence arrives with the catalog.
Cost: about 0.7 KB across nine products (25.8 KB to 26.5 KB).

The website shows the same words as small text under the full description, from
`db.js`'s `REFUND_POLICY` constant, and strips the appended copy out of `details`
first so a shopper on the website reads the sentence once.

## Rules this app inherits from the store

These are not preferences; breaking them breaks the shop.

- **WhatsApp is the only purchase path.** No cart, no account, no checkout.
  Every "order" control is a `whatsapp://send` deep link (falling back to
  `https://wa.me`) with the product, price and description already written into
  the message. WhatsApp prefills the message and the shopper taps send — no URL
  can send on their behalf.
- **PKR only, integer paisa.** `price_cents: 780000` is Rs 7,800. No
  currency selector, no USD, no `double` anywhere near a price.
- **Grid uniformity is enforced by layout, not discipline.** Card name and
  description get fixed-height boxes (2 lines / 3 lines) so a row can never go
  ragged, whatever the catalog says.
- **Only verifiable claims.** The About page describes mechanics a shopper can
  check from the app. It does not say who runs the shop or where the goods come
  from, because those are not known.
- **Sold out means `in_stock == false`** and a disabled control, not a
  pretend-purchasable button.

## Search failure is never silent

This is the failure MEMORY.md §4 spends most of its length on: an incomplete
index makes *every* search return nothing, site-wide, with nothing logged.
`SearchProblem` gives each cause its own message:

| Problem | Meaning | What the user sees |
| --- | --- | --- |
| `incompleteIndex` | a product has no vector | "Search is unavailable: the store catalog is being reindexed." |
| `modelMismatch` | catalog indexed by a different encoder | "Search is unavailable: the app and the store use different search models." |
| `noIndex` | `set_index` has not run | "Search is still starting up." |
| `engineUnavailable` | the native library failed to load | "Search is unavailable on this device." |

A model mismatch is the dangerous one: a dot product between two unrelated
models still returns a confident, entirely wrong ranking. `loadIndex` refuses
rather than proceeding, and checks `search_model` from the catalog against
`SEARCH_MODEL` compiled into the binary.

## Known gaps

- **No NEON path.** ternlight's `kernels.rs` has a WASM SIMD matmul and a
  scalar fallback; native ARM takes the scalar path. Correct, but slower than
  the site. A `core::arch::aarch64` implementation is the obvious next
  optimisation. See `docs/PERF.md`.
- **Automatic link opening needs a repository that does not exist.** The intent
  filter and `autoVerify` are shipped and the chooser works; Android only skips
  the chooser when it can fetch
  `https://shahzadp.github.io/.well-known/assetlinks.json`, which sits at the
  *domain* root and so is not something a Pages project repo under `/store/` can
  serve. `docs/APP-LINKS.md` has the whole story. No code change is needed once
  that file is reachable.
- **arm64 only.** `libalex_store_native.so` is built for `arm64-v8a`, and the APK
  packages exactly the ABIs the engine was built for, so it no longer advertises
  ABIs it cannot run. On an x86_64 emulator the app installs and browses with
  search disabled (`engineUnavailable`); `node scripts/build-apk.mjs --abis
  android-x64` fixes that for local work.
- **The launch video is confirmed on one device now, and that is how the system
  splash defect was found.** The clip plays with its audio and the fade matches
  the composition; what made the first attempt wrong — Android drawing its own
  copy of the mark before the video animated it — was invisible to every check
  here and obvious on a handset the moment it opened. The Android 12 system
  splash and the video's decode are now confirmed, not just verified as bytes.
- **The app has run on one device, and device testing found things unit tests
  did not.** The release build shipped with no `INTERNET` permission (Flutter's
  template puts it only in the debug manifest), the product grid overlapped
  itself by 341px, and the system splash repeated the video's own mark. All three
  are now covered by tests, and the R8-obfuscated build has since been exercised
  by hand on that handset — the splash, its audio, and both a misspelled query
  and one asked by meaning. The wider claim stands unchanged: one handset is not
  a test matrix.

## Licence

**This repository is not open source.** `LICENSE` is all-rights-reserved: no
permission is granted to reuse the source, the name, the icon or the launch
video, and nothing here permits redistributing the app - or a modified version of
it - as though it were official.

That is a deliberate choice for this particular app. Its whole purchase path is a
WhatsApp message, and the icon and the shop's number are what a convincing fake
would need; both are necessarily public, so branding cannot be the thing that
proves authenticity. The signature described under "The official download" can
be, which is why it is checked on every release rather than asserted here.

Third-party components keep their own permissive licences, listed in
`THIRD_PARTY_NOTICES.md`. None of them licenses anything of this project's.

## Third party

- [ternlight](https://github.com/soycaporal/ternlight) — MIT. Engine in
  `rust/src/engine/`, weights from
  [`wenshutang/ternlight`](https://huggingface.co/wenshutang/ternlight) (MIT).
  See `THIRD_PARTY_NOTICES.md`.
- `dart:ffi` is in the Dart SDK, so the bridge itself carries no licence. It was
  built with `flutter_rust_bridge` (MIT) first, which was abandoned — see
  MEMORY.md §6 for why.
- `url_launcher`, `path_provider` — BSD-3.
- `video_player` (BSD-3) and, through it on Android,
  [AndroidX Media3](https://github.com/androidx/media) / ExoPlayer
  (Apache-2.0). Used for the launch video and nothing else; see
  "The launch video".
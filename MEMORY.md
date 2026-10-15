# MEMORY — Alex Store app

Working notes for whoever picks this up next, including an agent with no prior
context. Architecture is in `README.md`.

**Companion repo:** the storefront lives in `../Store` (a sibling directory, not
a subdirectory). Several scripts here edit it. Nothing in this repo is
self-contained.

---

## 1. Current state

- Flutter app, Android target, five screens: home, shop, product, search, about.
- Reads the site's `catalog.json` on every launch; caches a copy for offline.
- Search: ternlight `base@0.1.1`, **compiled to native Rust** and called over
  `dart:ffi`, ranking the site's published vectors. The boundary is
  hand-written: `rust/src/ffi.rs` and
  `lib/src/services/native_engine.dart` are a matched pair; see section 6 for why
  `flutter_rust_bridge` was dropped.
- The site's `catalog.json` now carries those vectors. It did not until
  `scripts/patch-store-catalog-json.mjs` ran.
- **The Rust crate builds and its tests run** (19 green, including parity).
  The Dart side is still design-only: no Flutter SDK build, no device, no
  emulator.
- **Search now matches the site.** The native engine reproduces the WASM's
  vectors bit-exactly (worst per-dimension difference `0.000e+0`), so the app's
  rankings are the site's rankings. See §3.

---

## 2. The one decision that shapes everything

The website runs ternlight as WebAssembly. Dart cannot host a WASM runtime.
Rather than switching models — which would force a full reindex of the site —
the app compiles **the same engine to native code** and runs the same weights
on the phone.

The engine is plain Rust; only its `#[wasm_bindgen]` surface is
WebAssembly-specific, so `rust/src/engine/` is vendored byte-for-byte and
compiled as-is.

The consequence is the thing to protect: **the app's rankings and the site's
rankings must be the same rankings.** Everything below exists to keep that
true.

---

## 3. Things that have actually bitten, or will

### Parity: SOLVED. The bug was in how the model was extracted, not in the engine.

`cargo test --test parity` is **9/9 green**, and the native engine reproduces
the WASM's vectors **bit-exactly** — worst per-dimension difference across all
eight products is `0.000e+0`, not merely inside the 0.001 tolerance.

#### The actual bug: a WASM file is not a WASM memory

The obvious way to recover the model is to find the `TERN` magic in the `.wasm`
and slice from there. That is wrong, and it fails silently: the file loads,
`verify_sha256` passes (the scripts recompute the hash), and `embed()` returns
unit-length vectors, so nothing complains.

A WASM data segment is stored in the FILE as

```
[flags][offset expression][size][payload]
```

so **consecutive segments are separated by their own headers**. The engine never
sees those separators — it reads LINEAR MEMORY, where payloads sit at their
declared addresses. The `TERN` magic sits in one 21-byte segment and the weights
in the next; slicing the file across that boundary splices in eleven bytes of
scaffolding (`41 98 ef c1 00 0b b5 c3 c9 03`).

`scripts/extract-model-from-wasm.mjs` now parses the section table, replays every
data segment into a memory image, and extracts from that.

#### How the address was found — not guessed

`format.rs::verify_sha256` panics unless the last 32 bytes are the SHA-256 of
everything before them, so the model has a cryptographically-checkable length.
Scanning memory for the address whose 7,492,280-byte body hashes to the 32 bytes
that follow lands on **1,078,968**, and nothing else does. The header there
parses perfectly: `max_seq_len=128`, and all ten `reserved` bytes zero, as
`format.py` demands.

#### Two wrong answers this produced, both now undone

Worth recording, because both were confident and both were wrong:

1. **The naive file slice.** The 11 inter-segment bytes land mid-model. They were
   even mistaken for the header's `reserved` field — but `reserved` is zero in
   memory, and the bytes that looked like it were scaffolding.

2. **"Correcting" for it with a 192-byte realignment.** I inferred the embedding
   held 30,521 rows rather than 30,522, rebuilt the file to match, and got 12/12
   plausible weight scales and a unit-length, input-dependent — but still
   uncorrelated — embedding. **Those 192 bytes are row 0 of the embedding table,
   which `encode_embedding_int4` emits as zeros via `q[0].zero_()`.** They are
   part of the packed table. `compute_layout`'s arithmetic was right all along,
   and the repack is deleted.

The lesson: a plausible, self-consistent story about a binary format is worth
almost nothing until something independent checks it. Here that was the engine's
own SHA-256, and it had been available the whole time.

#### Traps worth remembering

- **A binary artefact's own checksum is the cheapest oracle available.** Reach
  for it before reasoning about offsets. It settled the file length, the start
  address, and the layout in one step.
- **"The extracted weights are byte-identical to the wasm" was circular.** The
  comparison was `model.bin` against the very slice it was cut from — a file
  always equals itself that way.
- **`ranking_scores_match_the_site` is not a parity test.** It scores the app's
  own query vector against the site's stored vectors, so it passes for *any*
  embedding. `native_reproduces_every_site_vector` is the only real check.
- **Scalar-vs-SIMD was "ruled out" by a vacuous test.** It was measured on the
  host, where `#[cfg(not(target_arch = "wasm32"))]` compiles the scalar fallback
  and the SIMD path does not exist — so it compared scalar to scalar. Both are
  exact integer arithmetic and cannot differ anyway.
- **Three separate probes gave wrong answers from one repeated mistake:**
  `subarray(32)` (stripping the header) combined with offsets that were already
  header-inclusive, shifting every reading by 32 bytes. Pick one coordinate
  system and never mix.
- **`scripts/reference-forward.mjs`** is an independent port of
  `unpack.py`'s forward pass to JS. It exists to answer "is it the data or the
  engine?" and answered that the data was wrong. Keep it.

#### Everything else is ruled out, empirically

| Suspect | Verdict | Evidence |
| --- | --- | --- |
| `catalog.json` / base64 encoding | **ruled out** | The site's own WASM reproduces every `catalog.json` vector at cosine **1.0000002**, zero dimensions differing by more than 0.01. `scripts/generate-wasm-fixture.mjs` builds the fixture from the engine directly, so the JSON is not even in the loop. |
| Wrong model (d256 vs d384) | **was a bug, fixed** | Every HF `wenshutang/ternlight` checkpoint is d_model=256/n_heads=4/ffn=1024; the site uses 384/6/1536. Same 384-dim *output* width, which is why nothing failed loudly. |
| Tokenizer | **ruled out** | Byte-identical to the wasm's embedded copy (sha256 `d241a60d…`), and both emit the same id sequence (`active=23`, identical prefix) for the product texts. |
| Forward-pass math | **ruled out** | `inference.rs` + `kernels.rs` follow `training/pack/unpack.py` step for step: parameterless LN → per-token AbsMax → round/clamp to int8 → i8 matmul → `+bias` in pre-rescale space → divide by `(w_scale * x_scale)`; GELU is the exact erf form; attention is `[T, n_heads, d_head]` with `1/√d_head`. Ternary codes unpack low-bits-first with `0b01→+1`, `0b10→−1`, exactly as the packer wrote them. |
| Engine drift from upstream | **ruled out** | `scripts/check-vendor-clean.mjs` pins all five files byte-for-byte; same hashes at commit `c6d2c0a` (the published 0.1.1 build) and on `main`. |
| Model extraction | **was the bug, fixed** | See above. |

**`include_bytes!` is a compile-time failure, not a runtime one.** A missing
`rust/src/assets/model.bin` produces an error pointing at the `include`, which
does not say "run `node scripts/extract-model-from-wasm.mjs`". `scripts/build-apk.mjs`
checks for the file first and prints that line.

**The vendored engine uses `crate::format::`, `crate::model::` and friends.**
A normal `src/engine/mod.rs` breaks those and forces edits. `lib.rs` uses
`#[path = "engine/format.rs"] pub mod format;` to lift each module to the crate
root instead, so the vendored files stay byte-identical to upstream and
`git diff` against ternlight means something. **Do not "tidy" this into a
`mod.rs`.**

`src/assets/` is one level up from `src/engine/` on purpose:
`model.rs` does `include_bytes!("../assets/model.bin")`, which resolves
relative to the source file. Moving the assets breaks it.

**Exactly one `emb_*` Cargo feature must be enabled.** The vendored `format.rs`
picks `BUILD_EMBEDDING_FORMAT` with `#[cfg(feature = ...)]` and the kernels
dispatch on the same flags. Zero features means `BUILD_EMBEDDING_FORMAT` does
not exist and the crate does not compile; two means you are packing a format
you did not intend. `lib.rs` reproduces ternlight's own `compile_error!` guard
for both cases. `emb_int4` matches the checkpoint the site's vectors came from.

**A `.bin` packed for one embedding format cannot be read by an engine built
for another.** `model-int4.bin`, `model-embedding-int8.bin` and
`model-ternary.bin` are not interchangeable. `scripts/extract-model-from-wasm.mjs`
rejects a blob whose header does not say `emb_int4` with `d_model=384`, so a
mismatched model cannot silently become the shipped one.

**There is no NEON path.** ternlight's `kernels.rs` has a WASM SIMD BitLinear
matmul under `#[cfg(target_arch = "wasm32")]` and a scalar loop for everything
else. Native ARM takes the scalar path. Correct, just slower than the site.
An `aarch64` implementation is the obvious next optimisation; see
`docs/PERF.md`.

**The parity tolerance cannot be zero — but the difference turned out not to be
rounding.** WASM accumulates the matmul in 16 lanes of `i32` SIMD while the
native build uses a scalar loop, so the two *could* differ in the last bits. In
practice they do not: `bitlinear_inner_simd` and its scalar twin are both exact
integer arithmetic (`i8 × i8 → i32`, no floating point), and the measured
difference is **exactly `0.000e+0` per dimension across all eight products**.
The `1e-3` tolerance and cosine ≥ `0.9999` floor in `tests/parity.rs` are
therefore slack, not a fudge — they are far tighter than any semantic difference
(two different models score below 0.9), so they would still catch a model swap.

**`db.js` has mixed line endings** (`\n`, `\r\n` and `\r\r\n` in the same
file — 154/44/471 at time of writing). Plain text replaces silently fail to
find their anchor. Patch it with `scripts/patch-store-catalog-json.mjs`, which
uses single-line anchors, exactly as CATALOG-GUIDE.md §10 says.

**PowerShell `Set-Content -Encoding utf8` writes a BOM** that makes `JSON.parse`
fail on an invisible character. `scripts/bump-site-version.mjs` writes UTF-8
without one.

**A model mismatch is the dangerous failure.** A dot product between two
unrelated models still returns a confident, entirely wrong ranking — no error,
no warning. So `RustSearchEngine.loadIndex` compares the catalog's
`search_model` against `SEARCH_MODEL` compiled into the binary and **refuses**
rather than proceeding. `SEARCH_MODEL` appears in four places that must move
together:

| Where | What |
| --- | --- |
| `../Store/db.js` | `SEARCH_MODEL` |
| `../Store/catalog.json` | `search_model` |
| `rust/src/ffi.rs` | C ABI + `SEARCH_MODEL` |
| `lib/src/services/rust_search_engine.dart` | `kSearchModel` |

Changing any one of them without the others makes search silently wrong.

**An empty index and an empty result look identical on screen.** A shopper who
searches "brass tray" and sees nothing concludes the store does not stock it,
not that the app is broken. `SearchProblem` gives each cause its own message.
Never collapse them into one "no results" state.

**`Catalog.isSearchable` is the app's `indexIsComplete()`.** It requires a
vector on *every* product. Partial indexes rank only what they have and look
like a weak result set rather than a broken one, so the app refuses to search
at all and says why.

### A release APK had no internet permission, and the message blamed the user's wifi

Opening the app said *"Could not reach the store. Check your connection and try
again"* while the connection was fine. The URL was fine too (`catalog.json`
returns HTTP 200 with all 8 products).

The cause was Flutter's own Android template: it puts
`<uses-permission android:name="android.permission.INTERNET"/>` in
`android/app/src/{debug,profile}/AndroidManifest.xml` and **not** in
`android/app/src/main/AndroidManifest.xml`. That is correct for a fresh
Flutter app, which talks to no network, so the omission is invisible until the
app starts fetching something. The release APK shipped with no network
permission at all — `dart:io` threw `SocketException` on every attempt.

This is the worst shape of bug, because **every diagnostic points at the wrong
thing**:

- `dart:io` raises a permission/connect error that names no permission.
- The message deliberately says "check your connection", because the code
  cannot tell "no permission" from "no network" — both arrive as the same
  exception.
- Nothing anywhere mentions permissions, so there is nothing to grep for.

`android/app/src/main/AndroidManifest.xml` now declares `INTERNET`, with a
comment explaining why it cannot move back. **When adding any permission, put
it in `main`, not in the debug manifest** — `flutter run` will work fine
without it, which is what makes this survive right up to the APK.

### Mojibake repair: whole-file round trips destroy correct text

Writing a UTF-8 file through `Get-Content -raw` (no `-Encoding`) and back with
`WriteAllText(..., UTF8)` corrupts every non-ASCII character, because Windows
PowerShell reads the file as cp1252. The symptom is `—` becoming `â€”` and `§`
becoming `Â§`, which then propagate into **user-visible strings** — the product
button read `Order on WhatsApp â€”`.

Two rules, both learned the hard way:

1. **Never repair by round-tripping the whole file.** A whole-file
   cp1252→UTF-8 round trip cannot distinguish corrupted bytes from correct
   characters, so it converts already-correct `—` (U+2014) into U+FFFD. It
   "repairs" the corruption and destroys the file in the same pass. Repair
   **per run** of non-ASCII characters, and accept a run only if it decodes as
   UTF-8 *and* the result no longer contains a mojibake marker.
2. **A second corruption pass is not repairable at all.** cp1252 leaves `0x9D`
   undefined, so a double-encoded `—` arrives truncated and unwrapping it
   yields a NUL. Worse than the original. Stop after one pass and leave
   anything lossy alone.

Detection is cheap: sweep for `U+FFFD`, the markers `Ã.` / `Â.` / `â€`, and
control characters, then confirm with `git diff` before committing.

### `ThemeData.copyWith` REPLACES a TextStyle, so a bare `TextStyle()` loses its colour

The home screen rendered its hero heading, the collection titles and the "Shop"
heading in the wrong colour. Six of the ten text styles were declared with no
`color` at all:

```dart
textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink).copyWith(
  displaySmall: const TextStyle(fontSize: 30, ...),   // no colour!
)
```

`copyWith` **replaces** a style rather than merging it, so the bare
`TextStyle(fontSize: 30)` discarded the colour `.apply()` had just put there.
The style then falls back to the ambient `DefaultTextStyle`, which is
`bodyMedium` — so the headings silently rendered in body-copy grey instead of
near-black. `theme_test.dart` now asserts every style names its colour.

**A chained `.apply(color).copyWith(style:)` is a lie.** The `.apply()` half
does nothing, because the `.copyWith()` half throws it away. Name the colour in
each style instead.

### A hard-coded `childAspectRatio` cannot be right, because the card is taller than its cell

Product cards rendered on top of each other with no gap. The grid was a fixed
`SliverGridDelegateWithFixedCrossAxisCount(childAspectRatio: 0.66)`. A
two-column cell is ~150dp wide, so `0.66` asked for a 228dp cell — while the
card's contents are ~340dp tall (square image + two name lines + three
description lines + price). Every card overflowed its slot by more than 100dp.
A widget test at 360dp measured **341px of overflow**; the price row separately
overflowed 134px sideways, because "Order on WhatsApp" is wider than half a
phone.

The fix is not a better constant. The card's height is *knowable*: the name and
description slots are fixed height, so the only variable is the square image,
whose height is the cell width. So `ProductGrid.cardHeightFor(cellWidth)` sums
the parts and the grid derives its ratio from the result. It cannot be wrong
unless a card constant changes, and `grid_layout_test.dart` measures the real
widget and compares.

The price and "Order on WhatsApp" now stack instead of sharing a line.

### One build produces two identical APKs, and that is not two compiles

`flutter build apk` leaves the APK in two places, byte-identical:

```
build/app/outputs/apk/release/app-release.apk    written by Gradle
build/app/outputs/flutter-apk/app-release.apk   copied there by Flutter
```

Same SHA-256, one second apart — one compile, two copies. Flutter's copy is the
canonical path (the one the docs and any release step name), so
`scripts/build-apk.mjs` now hashes both and deletes the Gradle one, failing
loudly rather than discarding work if they ever diverge.

### `DefaultTextStyle.of(context)` at a call site is the WRONG context for a button label

The product page's order button rendered "Order on" and "— Rs 7,800" in dark
ink on the purple button; only the word "WhatsApp" was legible. The label was
built from `DefaultTextStyle.of(context).style` — but `context` there is the
**screen's**, built *above* the button, so it captured the page's text colour
instead of the button's foreground. Measured at **2.09:1**.

The rule: **never pass a base style into a button label.** Let the spans carry
no colour and inherit — inside a button the ambient `DefaultTextStyle` is
already the button's foreground, so a light button gets light text and a dark
one gets dark text, and no call site can get it wrong.

`ui_safety_test.dart` resolves each span the way the engine does and asserts
4.5:1 against the button colour, so "dark button, light text" is now enforced
rather than remembered. Reintroducing the bug makes it fail at 2.09:1.

### Encode the WhatsApp message ONCE, or the chat shows "%0A" as literal text

Tapping "Order on WhatsApp" produced a message reading

```
Hello%0A%0AStoneware%20Mug%20%E2%80%94%20Rs%207%2C800
```

— percent escapes as visible text, instead of a message with line breaks.

Cause: `Product.whatsappMessage` returned `Uri.encodeComponent(message)` and
`whatsappLink` then encoded it **again**. A newline became `%250A`, WhatsApp
decoded the query parameter once, and displayed the single-encoded string. The
link was well-formed the whole time, so nothing errored and nothing looked
wrong until you read the message.

**Encode at exactly one boundary.** `whatsappMessage` now returns plain text
and `whatsappLink` owns the encoding. `whatsapp_link_test.dart` asserts the raw
URL contains no `%25`, which is the encoding of a literal `%` and therefore the
fingerprint of a double encode.

**The test that hid it:** `catalog_test.dart` asserted on
`Uri.decodeComponent(p.whatsappMessage(...))`. Decoding the result undid the
first encode, so the test passed while the shipped link was broken. A test that
decodes what it is testing has stopped testing the thing that matters — assert
on the raw value, and cover the URL boundary separately.

### WhatsApp prefills; it cannot send for you

The remaining half of "why is it not normal text" is not a bug. `?text=` is
WhatsApp's documented behaviour — it opens the chat with the message **in the
compose box**, and the shopper taps send. There is no URL parameter that sends a
message without them; the platform requires that confirmation deliberately.

What *can* be improved is not bouncing through a browser: `openWhatsApp` now
tries `whatsapp://send?phone=…&text=…` first and falls back to the `https://`
universal link, so the app opens directly instead of a redirect page with the
whole message visible in the address bar.

The app's message now also matches the site's `common.js:productLink` exactly:
store name, `*bold*` product name, category and price on one line, the short
description, and "Is it available?". It used to append the entire long-form
`details` block, which the site deliberately does not — an order message long
enough to scroll is one the shopkeeper will not read.

### The three-button navigation bar is ~48dp, and every hard-coded bottom padding was smaller

Home, shop and search all ended with a hard-coded bottom pad of 28dp. Android's
three-button nav bar is around 48dp, so the last product card or footer line sat
underneath the nav buttons. Gesture navigation has a ~16dp inset, so this looked
correct in every emulator and only failed on the handset that uses three
buttons.

`StoreTheme.bottomSafeInset(context)` reads `MediaQuery.viewPaddingOf` — not
`padding`, because `Scaffold` **strips `padding.bottom`** from its body once it
has consumed that area for a `bottomNavigationBar`, which the product screen
has. `viewPadding` is the raw window inset and survives.

**A hard-coded bottom pad is a guess.** Nothing in the app may assume the
navigation bar is a particular height.

---

## 4. Ordering rules inherited from the store

Not preferences — breaking them breaks the shop. See `README.md` for the
rationale.

- **WhatsApp is the only purchase path.** No cart, no account, no checkout.
- **PKR only, integer paisa.** No `double` anywhere near a price, no USD, no
  currency selector.
- **Grid uniformity is enforced by layout.** Fixed-height text boxes (2 lines
  name, 3 lines description). Never swap these for `maxLines` alone — that is
  what lets a row go ragged.
- **Only verifiable claims.** The About screen was removed on request as
  looking ugly, which removes the only place this rule applied. It applies to
  anything written from now on: nothing about who runs the shop or where goods
  come from, because that is not known.
- **Sold out means `in_stock == false`** and a disabled control.

---

## 5. Working on it

```bash
node scripts/extract-model-from-wasm.mjs     # once; recovers + verifies SHA-256
node scripts/extract-model-from-wasm.mjs --check   # verify, do not rewrite

cd rust && cargo test                        # parity against the site's vectors
node scripts/extract-site-vectors.mjs        # refresh the fixture first
cd .. && node scripts/check-vectors-agree.mjs # catalog.json == catalog.sql

node scripts/build-apk.mjs
```

### Touching the site

```bash
node scripts/regen-catalog-json.mjs          # re-export catalog.json
node scripts/check-vectors-agree.mjs         # must pass
node scripts/bump-site-version.mjs           # bump ?v=NN, rebuild, verify
```

`bump-site-version.mjs` runs `node build.mjs --check` and must exit 0 before
anything is pushed.

---

## 6. Open work

**Blocking**

- [ ] **Build the Android `.so` and the APK.** `cargo build --release --target
      aarch64-linux-android`, then `flutter build apk`. The GNU host toolchain is
      required for build scripts (see `rust/.cargo/config.toml`), and the target
      must be installed *for that toolchain* — rustup keeps targets per
      toolchain, so `aarch64-linux-android` being present under `msvc` does not
      help.
- [x] ~~Find the forward-pass divergence~~ — solved, see §3.

### The bridge is hand-written, not generated

`flutter_rust_bridge` is gone, and the reason is the toolchain rather than the
technology. FRB 2.13's generator shells out to `cargo expand`, which needs
`-Zunpretty=expanded` — **a nightly toolchain**. Getting there meant clearing
six blockers in order, each exposing the next:

| Symptom | Cause | Fix |
| --- | --- | --- |
| `link.exe` not found | default toolchain is `msvc`; `D:\VS2022BT` is empty | `cargo +stable-x86_64-pc-windows-gnu` |
| `dlltool.exe` not found | not on `PATH` | staged a copy at a space-free path |
| `dlltool: CreateProcess` | its own path contained a space | same fix |
| `ld: cannot find -lmsvcrt` | my copy of `gcc.exe` shadowed the real one | removed it, keeping only `dlltool` |
| `windows-sys 0.61` needs import libs | `raw-dylib`, and binutils `as` is absent | used the NDK's `llvm-dlltool` |
| `cargo expand` exits `0xC0000005` | the binary crashes, with and without nightly, with and without `RUSTC_BOOTSTRAP=1` | gave up |

That is a permanent tax on every `flutter build apk` in exchange for a
seven-function interface. So `rust/src/ffi.rs` and
`lib/src/services/native_engine.dart` are now a hand-written matched pair, and
the build needs only `cargo` and `flutter` — no codegen, no extra dependency.

What that costs, and the mitigations:

- **No thread pool.** FRB's `#[frb(async)]` moved search off the UI isolate. Now
  each call is one synchronous crossing. The work is bounded — one embed (a few
  ms) plus a scan over the index — and the index still lives in Rust, so nothing
  beyond ~10 small records is marshalled per keystroke.
- **No generated tree to version-match** against `pubspec.yaml`. A genuine win.
- **`Vec<Vec<f32>>` became one flat buffer**, so the whole index crosses in a
  single `set_index` call.

Both files are a pair: change one, change the other.

**Done**

- [x] ~~Generate `android/`~~ — done via `flutter create`.
- [x] ~~Compile the Rust crate~~ — it builds and runs.
- [x] ~~Find the right model~~ — it was not the published checkpoint; see §3.
- [x] ~~Run the parity test~~ — it runs, and passes: 9/9, bit-exact against
      the WASM. The bug was in extracting the model from the WASM, not in the
      engine; see §3.
- [x] ~~Fix the 192-byte section misalignment~~ — that diagnosis was wrong and
      has been reverted. Those 192 bytes are embedding row 0.

**Should do**

- [ ] **NEON matmul** for `bitlinear_inner_simd`. See `docs/PERF.md`.
- [ ] **Measure on a device.** Every latency claim is currently a guess.
- [ ] **Wire up `path_provider`.** `CatalogService` takes `readCache`/
      `writeCache` callbacks for exactly this and nothing passes them yet, so
      offline mode does not work.
- [ ] **Decide `armv7`.** The engine targets 64-bit clean; 32-bit Android is
      a vanishing share. `build-apk.mjs` can build it but nothing says it
      should ship.
- [ ] **Release, then set `apkUrl`.** `../Store/build.config.json` keeps
      `apkUrl` empty until a `v1.0` release exists, which is correct — it
      renders an inert control rather than a link to nothing.

**Housekeeping**

- [ ] No CI. `cargo test` plus the Node scripts would catch a stale fixture or
      a catalog that stopped being searchable.
- [ ] The site repo is a sibling checkout, not a submodule. The scripts assume
      `../Store`. Worth pinning or vendoring at some point.

---

## 7. Where things are

| Concern | File |
| --- | --- |
| Module wiring, compile-time guards | `rust/src/lib.rs` |
| C ABI for Dart | `rust/src/ffi.rs` |
| Product vector index, ranking | `rust/src/index.rs` |
| Dart FFI bindings | `lib/src/services/native_engine.dart` |
| Vendored ternlight engine | `rust/src/engine/` (do not edit) |
| Parity test | `rust/tests/parity.rs` |
| Model recovery + SHA-256 | `scripts/extract-model-from-wasm.mjs` |
| Fixture extraction | `scripts/extract-site-vectors.mjs` |
| Domain model | `lib/src/models/catalog.dart` |
| Paisa arithmetic | `lib/src/models/price.dart` |
| Catalog fetch / cache / validate | `lib/src/services/catalog_service.dart` |
| Search interface | `lib/src/services/search_engine.dart` |
| Bridge implementation | `lib/src/services/rust_search_engine.dart` |
| Card height constants | `lib/src/theme.dart` |
| Architecture and rationale | `README.md` |
# MEMORY — Alex Store app

Working notes for whoever picks this up next, including an agent with no prior
context. Architecture is in `README.md`.

**Companion repo:** the storefront lives in `../Store` (a sibling directory, not
a subdirectory). Several scripts here edit it. Nothing in this repo is
self-contained.

---

## 1. Current state

- Flutter app, Android target, five screens: home, shop, product, search, and the
  launch video that opens the app. (The About screen was removed; see §3.)
- **The app opens with a video.** `assets/splash/alex-store.mp4` — the same
  render of the storefront's title animation — plays over the app with its audio,
  and the app is already built underneath it, so the reveal is instant. See §3,
  "The launch video: an overlay, an exact fade, and three places that must agree".
- Reads the site's `catalog.json` on every launch; caches a copy for offline.
- Search: ternlight `base@0.1.1`, **compiled to native Rust** and called over
  `dart:ffi`, ranking the site's published vectors. The boundary is
  hand-written: `rust/src/ffi.rs` and
  `lib/src/services/native_engine.dart` are a matched pair; see section 6 for why
  `flutter_rust_bridge` was dropped.
- The site's `catalog.json` now carries those vectors. It did not until
  `scripts/patch-store-catalog-json.mjs` ran.
- **Search matches the site.** The native engine reproduces the WASM's vectors
  bit-exactly (worst per-dimension difference `0.000e+0`), so the app's rankings
  are the site's rankings. See §3.
- **The release is signed with a real key and obfuscated with R8.** `v1.0` is
  published and the site's button delivers it. See §3, "Signed with a real key,
  and R8 could not have touched the search path".
- **What is proven and what is not:** analyze clean, 94 Dart tests, 9 Rust parity
  tests, and 26 checks against the built APK
  (`scripts/verify-release-apk.mjs`). None of that is a phone, though. One
  handset has ever run this app; it has not run the R8-obfuscated build, and it
  has never played the launch video.

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

### A GitHub Pages PROJECT repo cannot host the file Android needs for auto-redirect

Opening a storefront link in the browser offers the app correctly, because the
intent filter is declared. It does not open *automatically* — Android still asks
which app to use.

Android decides that from `https://<host>/.well-known/assetlinks.json`, fetched
from the **domain root**. The storefront is a Pages *project* repo, so it is
published under `/store/` and the root belongs to a *user* site repo
(`shahzadp.github.io`) that does not exist:

```
$ curl -o /dev/null -w '%{http_code}' https://shahzadp.github.io/
404
```

A project repo cannot place a file above its own path prefix, so there is no
way to serve it from where the site actually lives. **The fix is a repo or a
domain, not a code change**: create the user-site repo, or put a custom domain
in front of the storefront. The `autoVerify="true"` flag is already in the
manifest and needs no edit when that file appears.

`docs/APP-LINKS.md` has the steps and `docs/assetlinks.json` the file.

**Publishing the debug fingerprint is a security bug.** The release build signs
with `signingConfigs.getByName("debug")` (`android/app/build.gradle.kts`), so
`assetlinks.json` would name the debug keystore. Anyone can generate a debug
keystore — that is what the toolchain does automatically — so any app signed
with any debug keystore could claim these links. Create a real release keystore
first.

A subtler half of this: a link can arrive **before the catalog has loaded**,
because the catalog is fetched on launch and the link does not wait. If the
router only checks what is loaded, it lands on "no longer available" for a
product that exists. `_openProductFromLink` in `main.dart` subscribes to the
catalog stream with a 20s timeout instead.

---

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

### `generated_at` changes on every regeneration, so comparing catalog.json raw text always reports "changed"

`catalog.json` is stamped by the site on export, so regenerating it with no edit
writes a different file — same products, same vectors, new timestamp. Any
"did the catalog change?" check that compares the raw text therefore says yes
forever, and a publish script built on it commits a point-zero change every time
it is run.

`scripts/publish-catalog.mjs` strips `generated_at` before comparing, and puts
the original file back when nothing real changed. Vectors regenerate
byte-identically — verified by regenerating and diffing all 8 — which is what
makes this a valid comparison to make.

### A failed refresh used to blank the storefront instead of keeping the catalog

`CatalogService.load` did this when the network failed and there was no cached
copy: emit `catalog: null`. Correct on first launch. Wrong on **refresh**, where
a good catalog was already on screen and a mid-refresh network drop replaced the
whole storefront with an error. The shopper reads that as "your store is gone",
not "you are offline".

Now it emits the existing catalog with the error alongside it, so the store stays
browsable. `test/catalog_refresh_test.dart` covers both directions, and is
written against the real service with only the transport swapped.

### Publishing a catalog is ONE command, and the app needs no update

`node scripts/publish-catalog.mjs` rebuilds `catalog.json` from `catalog.sql`
(vectors included), checks the two agree, shows the diff, bumps the site
cache-buster, commits, pushes, and waits for Pages to serve the result. It
replaced four separate commands in two repos, two of which fail silently when
skipped: skip the cache-buster and the *website* serves a stale copy while the
app is fine; skip check-vectors-agree and `catalog.json` can disagree with
`catalog.sql`.

Installed apps pick the change up on their next launch, or immediately with
pull-to-refresh. No app release — because the split is:

| baked into the APK | shipped in catalog.json |
| --- | --- |
| model weights, tokenizer, engine | product vectors and all product text |

**Changing the model is the one exception**, and the only case that needs a new
APK. The app refuses to search on a model mismatch rather than ranking wrongly.

### A UI pass that looks done, and the three places it had to change

The app looked built rather than made. Four things carried most of it, and none
of them were new features.

**Skeletons instead of a spinner.** Home, shop and search each showed a lone
`CircularProgressIndicator` on an otherwise blank page. A spinner says "loading";
a skeleton in the shape of what is coming says "about to be a shop", which is the
difference between an app that works and one that feels considered. `widgets/
skeleton.dart` sweeps a highlight rather than pulsing an opacity — a sweep reads
as progress, a pulse reads as indecision.

**One radius scale.** There were four different corner radii on one page: `3` on
the filter chips, `4` on buttons, `2` on inputs, none on the image tiles. Now
`StoreTheme.rSm/rMd/rLg` and nothing else. An app reads as deliberate when every
corner is a number from the same set.

**Sold-out is a state, not a styling.** It was grey text next to a normal price,
which is indistinguishable at a glance from a product that merely costs the same
as its neighbour. It is now a veil over the tile plus a badge, legible across a
room, because the expensive failure is a shopper tapping, reading, and finding out
too late that they cannot order.

**Depth and feedback.** `scrolledUnderElevation` was `0`, so the app bar never
gained depth and read as a static header rather than a pinned one. Cards now
confirm taps with `HapticFeedback.selectionClick`, and the product image runs a
`Hero` from card to product page — the cheapest "this was built properly" signal
there is, since the tile flies into place instead of cutting.

**`products.dart` placeholder is the product image.** Every `image_url` is null,
so the tile is what every shopper sees for every product. The old version dumped
the product name in 12px over a flat field, which reads as "image missing" —
accurate, but a shop where every product looks broken is a shop that looks
untrustworthy. It is now a two-stop gradient of the product's own tint with the
name set deliberately, and no invented photography, because MEMORY.md §4 allows
only what is verifiable.

### The card's height is derived, and a nested Padding broke it

Wrapping the card in `Material` for the ripple meant there were suddenly **two**
`Padding(vertical: cardVerticalPadding)` — the outer one from the card and one
inherited with the new wrapper. Every card grew by 36dp and overflowed its grid
cell, which is the exact overlap bug the derived-aspect-ratio fix had already
solved. `flutter analyze` said nothing.

`test/card_geometry_test.dart` now measures the real `ProductCard` at the cell
width the grid would hand it and asserts it fits, at four screen widths. Verified
by injecting 33px of unaccounted height and watching it fail with
`372.0 vs 339.0 reserved` — exactly the injected amount. A test that cannot fail
is not a guard.

The same golden pass also caught that `matchesGoldenFile` renders text as grey
boxes (no font assets in the test env). Useful for checking layout, useless for
type, and brittle as a regression test — so the harness and its goldens were
deleted rather than committed.

### The release is published, and the button delivers it byte-for-byte

`v1.0` is live at
`https://github.com/shahzadp/alex-store-app/releases/tag/v1.0` with `alex-store.apk`
attached, and the site's download button points at it.

The URL uses the **`latest`** form, not the tag:

    https://github.com/shahzadp/alex-store-app/releases/latest/download/alex-store.apk

so the next release needs no change to `Store/build.config.json`. Both that and
`/download/v1.0/alex-store.apk` return 200; the older note in the config file
said `/releases/download/latest/apk/...`, which 404s — the asset goes directly
after `download`, not under a `latest/` path.

Verified end to end rather than by inspection: fetched the **live** site's button
href, followed it, and compared the SHA-256 of the bytes delivered against the
APK that was built. Identical (`06BE7a33…`), so what a shopper downloads is the
binary that was tested, not something that merely has the right name.

`gh` and `api.github.com` both work from this machine now — the earlier note
that `api.github.com` was blocked no longer applies. `gh release create` needs
no separate setup; it uses the keyring account.

**Replacing the asset is NOT `gh release upload v1.0 <built path> --clobber`.**
`--clobber` matches on the *local filename*, not on the asset it is meant to
replace. The build output is `app-release.apk`, so that command quietly added a
**second** asset named `app-release.apk` and left `alex-store.apk` — the name the
site's URL ends in — untouched. The button went on serving the old APK while the
release page showed the new one, which is a genuinely confusing state. Stage the
file under the right name first:

```bash
cp build/app/outputs/flutter-apk/app-release.apk /tmp/alex-store.apk
gh release upload v1.0 /tmp/alex-store.apk --clobber
gh release delete-asset v1.0 app-release.apk --yes   # undo the mistake
```

Then expect a stale **edge cache** to keep serving the old bytes for a minute or
two. Right after the swap, `repos/.../releases/tags/v1.0` and `gh release
download` both reported the new asset while a plain GET of
`.../releases/download/v1.0/alex-store.apk` still returned the old one, with
`Age: 30` and `X-Cache: MISS, HIT` in the headers — Fastly, not GitHub's API.
It cleared on its own. The way to tell a cache from a real problem is exactly
that disagreement: the API and `gh release download` are authoritative, the
plain GET is not.

The `_apkUrlNote` field was deleted from `build.config.json`. It documented the
inert-control behaviour for a state that no longer applies, and leaving it would
suggest an empty `apkUrl` is still the expected configuration.

### Signed with a real key, and R8 could not have touched the search path

`android/app/build.gradle.kts` used to sign release builds with
`signingConfigs.getByName("debug")`. Two things were wrong with that, and only
the first is obvious.

The obvious one: the Android debug keystore is a public file — every SDK install
has the same one and its password is literally `android` — so anyone could have
built an APK that Android would accept as an update to this app.

The one that bites later: **Android refuses to install an update whose signing
key differs.** So the moment a real key appeared, every existing install would
have had to be uninstalled first. That trap springs exactly once, and it springs
whenever it is finally addressed — which is why swapping the key was worth doing
immediately rather than at the next release.

Now: a real RSA-4096 key in `android/app/release-keystore.jks`, used through
`android/key.properties`, both gitignored (the `.gitignore` entries were already
there). Release builds also carry APK Signature Scheme **v3**, not just v2 — v3
is what carries a key's rotation history, so *this* key can be rotated later
without that surgery. `enableV3Signing = true` is explicit, because AGP does not
enable it by default; the verifier fails if it goes missing. A release build with
no keystore now **stops with instructions** rather than quietly falling back to
the debug key.

#### Why R8 is not a threat here, and why that is checked rather than asserted

Enabling obfuscation invites the worry that R8 will mangle the FFI symbol names
and silently break search. It cannot, and the reason is structural:

- R8 rewrites **JVM bytecode only**. Search is `dart:ffi`:
  `lib/src/services/native_engine.dart` resolves ten symbols (`alex_search`,
  `alex_embed`, …) from **string literals at runtime**, and those literals are
  compiled into the Dart AOT snapshot.
- `rust/src/ffi.rs` is `extern "C"` + `#[no_mangle]` throughout, with no
  `JNI_OnLoad` and no `Java_…` export. There is no class or method name anywhere
  in the search path for R8 to rename. That is a direct dividend of hand-writing
  the boundary rather than generating it — see §6.

The shrinker that *could* have broken the FFI path is Dart's own AOT
tree-shaker, not R8, and `libapp.so` is checked for all ten strings.

It follows that `android/app/proguard-rules.pro` needs almost no rules, and it
has almost none. The rules that matter come from elsewhere and apply
automatically:

- Flutter's Gradle plugin adds
  `$FLUTTER/packages/flutter_tools/gradle/flutter_proguard_rules.pro` to the
  release build type (`FlutterPlugin.kt`). That keeps every `FlutterPlugin`
  implementation, which is how `app_links`, `path_provider` and `url_launcher`
  survive.
- `GeneratedPluginRegistrant` must keep its **name**: Flutter's embedding finds
  it with `Class.forName("io.flutter.plugins.GeneratedPluginRegistrant")` from
  `GeneratedPluginRegister.class` and then calls `registerWith` by name. It is
  `@Keep`-annotated, and AGP's `proguard-android-optimize.txt` honours that, so
  no rule is needed. If the name *were* obfuscated, no plugin would register: the
  app would open, browse and search, but WhatsApp would not open, the offline
  catalog would not load and deep links would not work — with no error message,
  and nothing about the symptom that looks like obfuscation.
- `path_provider_android` 2.3.x depends on the **`jni`** package, whose Android
  library ships `consumer-rules.pro` via `consumerProguardFiles`. AGP applies a
  library's consumer rules automatically. That package does use JNI; the search
  engine does not.

R8 emitted **zero warnings**, which is why `proguard-rules.pro` has no
`-dontwarn com.google.android.play.core.**`. That line is cargo-culted into
Flutter projects routinely; here the build says it is not needed. 683 of 740
classes were renamed.

#### `scripts/verify-release-apk.mjs`

A claim about obfuscation ages badly, so it is checked against the artifact
instead. The script reads its expectations out of the repository — symbol names
from `native_engine.dart`, the certificate from `docs/assetlinks.json`, model
hashes from `model-from-wasm.json` — so adding a symbol to the engine adds a
check automatically, and the expectations cannot drift from the code. 24 checks:

- the signing certificate matches `assetlinks.json` and is not the debug key; v2
  and v3 present; v1 absent is *correct* at minSdk 24, and that is asserted in
  both directions rather than only one.
- R8 ran (683/740 renamed) and **no FFI symbol name appears anywhere in
  `mapping.txt`**.
- every symbol is exported by the packaged `.so` (`llvm-nm`) **and** still a
  string in `libapp.so`.
- the model is embedded in the `.so` and satisfies its own SHA-256.
- every packaged ABI has both `libflutter.so` and `libapp.so`.
- `GeneratedPluginRegistrant`, `registerWith` and `MainActivity` all still exist
  in the DEX by name.

The ABI check earned its place by finding something real. `jni_flutter` ships
`libdartjni.so` for arm64, armv7 and x86_64, so the APK contained `armeabi-v7a/`
and `x86_64/` directories holding *only* that library, even though Flutter was
told to build arm64 alone. Android read those directories as support, would
install on such a device, and the app would die at launch because `libflutter.so`
was never built for it. Fixed by deriving `abiFilters` from whatever
`build-apk.mjs` left in `jniLibs`, so the APK advertises exactly what it can run.
That also took the APK from 27.69 MB to 27.49 MB.

The check that looked most like confirmation bias turned out to be the other real
find. `rust/src/assets/model-from-wasm.json` recorded a `sha256` and `bytes` that
matched nothing on disk, because it documented the **wrong** extraction — the
file-shaped slice that `extract-model-from-wasm.mjs`'s own notes identify as
producing a file that still loads, still passes a checksum the extractor
recomputed, and still returns unit-length vectors. `model.bin` itself was fine:
`--check` reproduces it from the WASM byte for byte, and it satisfies its own
trailing SHA-256. The provenance record was the stale thing. Corrected, and the
verifier now cross-checks the two, so it cannot rot again in silence.

**What this does not prove.** There was no emulator and no device, so none of the
above is a phone running the obfuscated build. What is verified is the artifact:
the exact bytes that get published, containing the exact `.so` the app will
`dlopen` and resolve symbols from. That is a large part of the claim — but "R8
did not break search on a handset" still needs a handset.

---

### The launch video: an overlay, an exact fade, and three places that must agree

The app now opens with `assets/splash/alex-store.mp4` — the storefront's own title
animation, rendered from `AlexStore.tsx` in the Remotion project, 1080x1920, 30
fps, 150 frames, **with its audio**.

**It is an overlay, not a route, and that is the whole design.** `SplashScreen`
is stacked *above* `MaterialApp`'s navigator through `builder:`, so `home` builds
on the first frame underneath it. The catalog fetch and the entire home layout
therefore happen while the video plays, and the reveal is instant. Pushing it as
a route would delay the fetch by the length of the clip and then show a loading
state — the opposite of what a splash is for. This is the same reasoning as §3's
"the first frame renders immediately"; it is the app's one stated rule about
first impressions.

**"Fade out matching" means matching the composition, not picking a nice
duration.** `AlexStore.tsx` ends with `interpolate(frame, [140, 150], [1, 0])`:
the whole composition fades over its last 10 frames, which at 30 fps is 333 ms,
ending on near-black. `SplashScreen.defaultFadeOut` is that same 333 ms. A test
recomputes 10/30s from the frame numbers and fails if the two ever disagree, so
re-rendering the composition with a longer tail does not silently leave the app
fading at the old speed.

**The cold start had a white — or black — flash in front of the video, and it
took three files to remove.** The video's opening frame is a
`#f5f3ff → #fdf2f8 → #ecfeff` wash. `res/values/colors.xml` holds those stops,
`res/drawable/launch_background.xml` paints them into the Android window, and
`SplashScreen._backdrop` paints the same three in Dart to cover the gap between
Flutter's first frame and the decoder's first frame. Change one and the launch
gains a visible seam a few hundred milliseconds in — and no single file is wrong
on its own, which is exactly the kind of drift nothing notices. Two tests close
it: one asserts the XML and the Dart gradient carry the same three values, and
the verifier checks the clip is in the APK byte for byte (`isShrinkResources` is
on).

That work also turned up a Flutter-template trap: `drawable-v21/launch_background.xml`
**always wins** at minSdk 24, because the version qualifier is satisfied by every
API level the app supports — so editing `drawable/launch_background.xml` alone
changes nothing at runtime. The `-v21` file existed only to pick
`?android:colorBackground` on API 21+, which is moot here, so it was deleted
rather than kept in step.

**Android 12 needed its own files, and dark mode needed two of them.**
`windowBackground` is not what API 31+ reads for its system splash; it reads
`windowSplashScreenBackground`. Worse, **night mode outranks platform version in
Android's resource selection**, so a device in dark mode on Android 12+ would
have taken `LaunchTheme` from `values-night/` and lost the v31 attributes
entirely. Hence `values-v31/` *and* `values-night-v31/`. `aapt2 dump resources`
on the built APK confirms all four variants landed: `windowBackground` four times,
`windowSplashScreenBackground` twice.

**A splash is the one screen that can lock a user out of a working app.** Every
path out of `SplashScreen` ends in `onFinished`: an asset that will not load, a
decoder that reports an error, and a playback that stalls all fall through a
deadline sized to `duration + fade + 1s`. `video_player` also brings its own
lifecycle observer, so the audio pauses if the shopper leaves mid-splash instead
of continuing to play over the launcher. All three paths are tested, and the
tests were checked by mutation: making `_finish` hand over immediately fails two
of them with the intended message.

**Cost, stated plainly.** The clip is 1.1 MB and `video_player` pulls in
ExoPlayer (AndroidX Media3, plus its hls/dash/rtsp/smoothstreaming modules) on
Android. The APK went 27.49 MB → 29.32 MB; 1.1 MB of that is the video and the
rest survived R8. That is a real cost for a five-second title sequence, and it is
the price of the request rather than an accident.

**What this does not prove.** Nobody has watched this play. The artifact is
verified and the failure paths are tested, but ExoPlayer decoding the file, the
audio being audible, and Android 12's system splash were not observed on any
device — there is still no emulator and no handset here.

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
node scripts/verify-release-apk.mjs           # must be 26/26 before publishing
```

`flutter` and `cargo` are not on `PATH` in a bare shell here; both `scripts` call
them by name, so prepend `C:\dev\flutter\bin` and `%USERPROFILE%\.cargo\bin`.

**`flutter config` points at `D:\android-sdk`, a junction onto the real SDK under
`D:\GitHub Projects\DoL-by-Alex\devTools\androidsdk`.** Gradle does not use it —
it reads `sdk.dir` from `android/local.properties`, so a `gradlew` build succeeds
even when the junction is missing. `flutter build apk` does, so it fails with
"No Android SDK found" and the error looks like a Flutter problem rather than a
missing junction. The junction exists because the real path contains spaces,
which Flutter refuses. Recreate it with no admin rights needed:

```
mklink /J D:\android-sdk "D:\GitHub Projects\DoL-by-Alex\devTools\androidsdk"
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

- [ ] **Run the signed, obfuscated APK on a device.** Everything about it is
      verified at the artifact level (§3); nothing has been *executed* on
      hardware. This is the one part of the claim `verify-release-apk.mjs` cannot
      make for you.
- [ ] **Watch the launch video on a device.** Same gap, specific to the splash:
      the clip is in the APK byte for byte and the fade matches the composition,
      but ExoPlayer decoding it, the audio, and Android 12's system splash have
      not been seen. See §3, "The launch video".
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
- [x] ~~Build the Android `.so` and the APK~~ — `scripts/build-apk.mjs` is the
      whole pipeline. The GNU host toolchain is required for build scripts (see
      `rust/.cargo/config.toml`) and the target must be installed *for that
      toolchain*: rustup keeps targets per toolchain, so `aarch64-linux-android`
      under `msvc` does not help.
- [x] ~~Release, then set `apkUrl`~~ — `v1.0` is published as a release asset and
      `../Store/build.config.json` points at the `latest` URL.
- [x] ~~Sign with a real key, and turn on R8~~ — done, and verified against the
      built artifact rather than asserted; see §3.
- [x] ~~Decide `armv7`~~ — not shipping it, and no longer *claiming* it either.
      `abiFilters` is derived from what `build-apk.mjs` leaves in `jniLibs`, so
      the APK advertises exactly the ABIs the engine was built for.
      `--abis android-arm,x64` still builds others on demand.

**Should do**

- [ ] **NEON matmul** for `bitlinear_inner_simd`. See `docs/PERF.md`.
- [ ] **Measure on a device.** Every latency claim is currently a guess.
- [ ] **Wire up `path_provider`.** `CatalogService` takes `readCache`/
      `writeCache` callbacks for exactly this and nothing passes them yet, so
      offline mode does not work.

**Housekeeping**

- [ ] No CI. `cargo test`, `flutter test` and `verify-release-apk.mjs` would
      catch a stale fixture, a catalog that stopped being searchable, or an R8
      rule that quietly stopped applying.
- [ ] Back up `android/app/release-keystore.jks` and `android/key.properties`.
      They are gitignored, so git is not a backup, and losing them means this app
      can never be updated again — only re-released under a new identity, which
      every existing install would have to uninstall first.
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
| Release signing, R8, `abiFilters` | `android/app/build.gradle.kts` |
| R8 rules (deliberately near-empty) | `android/app/proguard-rules.pro` |
| Release APK verification | `scripts/verify-release-apk.mjs` |
| App Links fingerprint | `docs/assetlinks.json` |
| Model recovery + SHA-256 | `scripts/extract-model-from-wasm.mjs` |
| Fixture extraction | `scripts/extract-site-vectors.mjs` |
| Domain model | `lib/src/models/catalog.dart` |
| Paisa arithmetic | `lib/src/models/price.dart` |
| Catalog fetch / cache / validate | `lib/src/services/catalog_service.dart` |
| Search interface | `lib/src/services/search_engine.dart` |
| Bridge implementation | `lib/src/services/rust_search_engine.dart` |
| Card height constants | `lib/src/theme.dart` |
| Architecture and rationale | `README.md` |
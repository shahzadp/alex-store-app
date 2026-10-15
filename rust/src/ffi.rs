//! The C ABI surface — everything Dart can call.
//!
//! # Why this is hand-written rather than generated
//!
//! This started as a `flutter_rust_bridge` surface (`src/api.rs`, with
//! `#[frb(async)]` attributes and a codegen step emitting `lib/src/api/`).
//! It was replaced by this module because FRB 2.13 cannot be built here:
//! `flutter_rust_bridge_codegen` shells out to `cargo expand`, which needs
//! `-Zunpretty=expanded`, i.e. a nightly toolchain, and the binary it builds
//! crashes under this toolchain regardless. That is a permanent tax on
//! `flutter build apk` for a seven-function interface.
//!
//! Writing the boundary by hand removes the codegen step entirely: there is no
//! generated tree to version-match against `pubspec.yaml`, and a clean checkout
//! builds with nothing but `cargo` and `flutter`. See MEMORY.md §6.
//!
//! # Rules for this file
//!
//! * Every entry point is `extern "C"` and `#[no_mangle]`, because Dart's FFI
//!   resolves symbols by name.
//! * **No Rust panic may cross this boundary.** Unwinding into Dart is
//!   undefined behaviour, and a panic in the engine (a corrupt `model.bin`,
//!   say) is entirely plausible. Every entry point wraps its body in
//!   [`catch_unwind`] and reports failure as an error code.
//! * No Rust type crosses the boundary. Strings are NUL-terminated UTF-8;
//!   vectors are raw pointers into memory Dart owns.
//!
//! # Error reporting
//!
//! Failing calls return a negative code and stash a message in a thread-local,
//! readable with [`alex_last_error`]. The returned string is owned by Rust and
//! is valid until the next bridged call on the same thread; Dart copies it out
//! immediately.
//!
//! # Threading
//!
//! Dart calls these synchronously on whichever isolate invokes them, so the
//! thread-locals are per-isolate in practice. The index sits behind a `Mutex`,
//! so concurrent calls are safe if Dart ever fans out.

use crate::index::ProductIndex;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, OnceLock};

/// Success.
pub const ALEX_OK: i32 = 0;
/// The call failed, or a panic was caught. Read [`alex_last_error`].
pub const ALEX_ERR: i32 = -1;

fn slot() -> &'static Mutex<Option<ProductIndex>> {
    static SLOT: OnceLock<Mutex<Option<ProductIndex>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

thread_local! {
    /// Last error message, kept alive so Dart can read a stable pointer.
    static LAST_ERROR: std::cell::RefCell<Option<CString>> =
        const { std::cell::RefCell::new(None) };
    /// Slug strings for the most recent `alex_search`. They must outlive the
    /// pointers handed back, so they live until the next search.
    static HITS: std::cell::RefCell<Vec<CString>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

fn set_error(msg: impl Into<String>) {
    let msg = msg.into();
    LAST_ERROR.with(|s| *s.borrow_mut() = Some(CString::new(msg).unwrap_or_default()));
}

/// Run `f`, converting a panic into `ALEX_ERR` plus a readable message.
fn guard<F: FnOnce() -> i32>(f: F) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(code) => code,
        Err(payload) => {
            let msg = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "engine panicked".to_string());
            set_error(msg);
            ALEX_ERR
        }
    }
}

/// Borrow a C string argument. Null or non-UTF-8 is an error, not a crash.
unsafe fn borrow_str<'a>(p: *const c_char) -> Result<&'a str, ()> {
    if p.is_null() {
        return Err(());
    }
    // SAFETY: checked non-null above; the caller guarantees NUL termination,
    // which is the C string contract Dart's ffi pointer marshalling upholds.
    unsafe { CStr::from_ptr(p) }.to_str().map_err(|_| ())
}

// ── Introspection ───────────────────────────────────────────────────────────

/// The most recent error message. Never null; returns `"ok"` when there is none.
#[no_mangle]
pub extern "C" fn alex_last_error() -> *const c_char {
    LAST_ERROR.with(|s| s.borrow().as_ref().map_or(c"ok".as_ptr(), |e| e.as_ptr()))
}

/// The model header as parsed from `model.bin`, for the app's debug screen.
///
/// Owned by Rust; valid until the next bridged call on this thread.
#[no_mangle]
pub extern "C" fn alex_engine_info() -> *const c_char {
    thread_local! {
        static INFO: std::cell::RefCell<CString> =
            std::cell::RefCell::new(CString::new(crate::model::config_summary()).unwrap_or_default());
    }
    INFO.with(|s| s.borrow().as_ptr())
}

/// `'ternlight/base@0.1.1'` — the `SEARCH_MODEL` the site's vectors are tagged
/// with. If this changes, both sides need a full reindex at the same time.
///
/// A static NUL-terminated literal: no allocation, valid forever.
#[no_mangle]
pub extern "C" fn alex_search_model() -> *const c_char {
    b"ternlight/base@0.1.1\0".as_ptr() as *const c_char
}

/// The embedding dimensionality, so Dart can size its buffers from the engine
/// rather than hardcoding 384.
#[no_mangle]
pub extern "C" fn alex_embedding_dims() -> usize {
    crate::EMBEDDING_DIMS
}

// ── Lifecycle ───────────────────────────────────────────────────────────────

/// Force the model, tokenizer and unpacked weights to initialise.
///
/// Idempotent, and worth calling once at app start: it moves ~150 ms of
/// one-time work off the first search, and turns a corrupt `model.bin` into a
/// launch error rather than a query error.
#[no_mangle]
pub extern "C" fn alex_warm_up() -> i32 {
    guard(|| {
        crate::warm_up();
        ALEX_OK
    })
}

/// Load the product vectors. Call once per catalog fetch.
///
/// `slugs` is `count` NUL-terminated UTF-8 strings. `vectors` is `count * dims`
/// f32 in row-major order. Both buffers are owned by Dart.
///
/// A dimension mismatch is refused: it means the catalog was indexed by a
/// different model and every score would be silently wrong.
#[no_mangle]
pub unsafe extern "C" fn alex_set_index(
    slugs: *const *const c_char,
    vectors: *const f32,
    count: usize,
    dims: usize,
) -> i32 {
    guard(|| unsafe {
        if count > 0 && (slugs.is_null() || vectors.is_null()) {
            set_error("set_index: null slugs or vectors pointer");
            return ALEX_ERR;
        }
        if dims != crate::EMBEDDING_DIMS {
            set_error(format!(
                "catalog vectors have {dims} dims, engine produces {}",
                crate::EMBEDDING_DIMS
            ));
            return ALEX_ERR;
        }

        let mut names = Vec::with_capacity(count);
        for i in 0..count {
            match borrow_str(*slugs.add(i)) {
                Ok(s) => names.push(s.to_string()),
                Err(()) => {
                    set_error(format!("slug {i} is not valid UTF-8"));
                    return ALEX_ERR;
                }
            }
        }

        let flat = if count == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(vectors, count * dims)
        };
        let rows: Vec<Vec<f32>> = flat.chunks_exact(dims).map(|r| r.to_vec()).collect();

        let idx = match ProductIndex::build(names, rows) {
            Ok(i) => i,
            Err(e) => {
                set_error(e.to_string());
                return ALEX_ERR;
            }
        };
        match slot().lock() {
            Ok(mut g) => {
                *g = Some(idx);
                ALEX_OK
            }
            Err(_) => {
                set_error("index mutex poisoned");
                ALEX_ERR
            }
        }
    })
}

/// Drop the index. Called when the catalog is refetched and before the new
/// vectors have parsed, so a search cannot rank against a stale catalog.
#[no_mangle]
pub extern "C" fn alex_clear_index() {
    if let Ok(mut g) = slot().lock() {
        *g = None;
    }
}

/// Number of products currently indexed, or 0 if none.
#[no_mangle]
pub extern "C" fn alex_index_size() -> usize {
    slot().lock()
        .map(|g| g.as_ref().map_or(0, ProductIndex::len))
        .unwrap_or(0)
}

// ── Querying ────────────────────────────────────────────────────────────────

/// Embed `text` into `out`, which the caller sizes for
/// [`alex_embedding_dims`] floats. That is the only length the engine produces.
#[no_mangle]
pub unsafe extern "C" fn alex_embed(text: *const c_char, out: *mut f32) -> i32 {
    guard(|| unsafe {
        let t = match borrow_str(text) {
            Ok(s) => s,
            Err(()) => {
                set_error("embed: null or non-UTF-8 text");
                return ALEX_ERR;
            }
        };
        if out.is_null() {
            set_error("embed: null output buffer");
            return ALEX_ERR;
        }
        let v = crate::inference::embed(t);
        if v.len() != crate::EMBEDDING_DIMS {
            set_error(format!(
                "engine returned {} dims, expected {}",
                v.len(),
                crate::EMBEDDING_DIMS
            ));
            return ALEX_ERR;
        }
        std::ptr::copy_nonoverlapping(v.as_ptr(), out, v.len());
        ALEX_OK
    })
}

/// Semantic search over the loaded index, best match first.
///
/// Writes up to `capacity` slug pointers (NUL-terminated, owned by Rust and
/// valid until the next `alex_search`) into `out_slugs`, and the matching
/// scores into `out_scores`. Returns the number of hits, or a negative code on
/// failure.
///
/// `limit` <= 0 means "no limit". An empty or whitespace-only query returns 0
/// hits without touching the engine — a user backspacing to nothing should not
/// pay for an embedding.
#[no_mangle]
pub unsafe extern "C" fn alex_search(
    query: *const c_char,
    limit: i32,
    out_slugs: *mut *const c_char,
    out_scores: *mut f64,
    capacity: usize,
) -> i32 {
    guard(|| unsafe {
        let q = match borrow_str(query) {
            Ok(s) => s,
            Err(()) => {
                set_error("search: null or non-UTF-8 query");
                return ALEX_ERR;
            }
        };
        let trimmed = q.trim();
        if trimmed.is_empty() {
            return 0;
        }

        let held = match slot().lock() {
            Ok(g) => g,
            Err(_) => {
                set_error("index mutex poisoned");
                return ALEX_ERR;
            }
        };
        let idx = match held.as_ref() {
            Some(i) => i,
            None => {
                set_error("no index loaded - call alex_set_index after fetching catalog.json");
                return ALEX_ERR;
            }
        };

        let n = idx.len();
        let take = if limit <= 0 { n } else { (limit as usize).min(n) };
        let hits = match idx.search_text(trimmed, take) {
            Ok(h) => h,
            Err(e) => {
                set_error(e.to_string());
                return ALEX_ERR;
            }
        };
        drop(held);

        HITS.with(|cell| {
            let mut owned = cell.borrow_mut();
            owned.clear();
            owned.reserve(hits.len());
            for h in &hits {
                owned.push(CString::new(h.slug.as_str()).unwrap_or_default());
            }
            let want = hits.len().min(capacity);
            for (i, h) in hits.iter().take(want).enumerate() {
                if !out_slugs.is_null() {
                    *out_slugs.add(i) = owned[i].as_ptr();
                }
                if !out_scores.is_null() {
                    *out_scores.add(i) = h.score as f64;
                }
            }
            want as i32
        })
    })
}
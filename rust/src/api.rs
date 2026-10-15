//! The flutter_rust_bridge surface — everything Dart can call.
//!
//! Compiled only under `--features frb`.
//!
//! # Why the index lives in Rust, not Dart
//!
//! The obvious design is to bridge `embed(query) -> Vec<f32>` and do the
//! ranking in Dart. That works, but it pushes 8 x 384 floats across the FFI
//! boundary on *every keystroke*, and Flutter's FFI marshalling for
//! `Vec<Vec<f32>>` allocates per row. Instead the catalog's vectors are loaded
//! once via [`set_index`] and only a small `Vec<Hit>` comes back per query —
//! one crossing, no per-query allocation.
//!
//! # Why these are async
//!
//! `search` embeds the query through the full forward pass. That is a few
//! milliseconds of SIMD-less scalar f32 work (see `docs/PERF.md`), but "a few
//! milliseconds on the UI thread" is exactly the kind of jank a search field
//! should not have. Marking them `#[frb(async)]` moves them onto FRB's worker
//! pool. `embed` alone is left sync because it is used by the parity harness.

use flutter_rust_bridge::frb;

use crate::index::{Hit, IndexError, ProductIndex};
use std::sync::{Mutex, OnceLock};

/// The process-wide product index. `OnceLock` so a failed `set_index` does not
/// poison it — the app can retry with a freshly-fetched catalog.
fn slot() -> &'static Mutex<Option<ProductIndex>> {
    static SLOT: OnceLock<Mutex<Option<ProductIndex>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

fn err<E: std::fmt::Display>(e: E) -> crate::api::ApiError {
    crate::api::ApiError::Engine(e.to_string())
}

/// A flat, FFI-friendly error. `IndexError` has variants Dart would have to
/// match on to be useful; stringifying keeps the generated bindings small and
/// the messages are written to be shown to a human anyway.
#[derive(Debug, Clone)]
pub struct ApiError {
    pub message: String,
}

impl ApiError {
    pub fn engine<S: Into<String>>(message: S) -> Self {
        ApiError { message: message.into() }
    }
}

// ── Diagnostics ─────────────────────────────────────────────────────────────

/// Model header as parsed from `model.bin`, e.g.
/// `tern-engine v1 | embedding_format=int4 | vocab=30522 d_model=384 ...`.
///
/// Surfaces in the app's debug screen. If the format ever disagrees with the
/// site's `SEARCH_MODEL`, it shows up here first.
#[frb(async)]
pub fn engine_info() -> Result<String, ApiError> {
    Ok(crate::model::config_summary())
}

/// `'ternlight/base@0.1.1'` — the `SEARCH_MODEL` string the site's
/// `product_vectors` rows are tagged with.
///
/// When the model changes this constant must change with it, and both sides
/// need a full reindex at the same time. See MEMORY.md §4.
pub const SEARCH_MODEL: &str = "ternlight/base@0.1.1";

/// Force the model, tokenizer and unpacked weights to initialise.
///
/// Idempotent. Worth awaiting during app start: it moves ~150 ms of one-time
/// work off the first search and turns a corrupt `model.bin` into a launch
/// error instead of a query error.
#[frb(async)]
pub fn warm_up() {
    crate::warm_up();
}

// ── Index lifecycle ─────────────────────────────────────────────────────────

/// Load the product vectors. Call once per catalog fetch.
///
/// `slugs` and `vectors` are parallel arrays — `vectors[i]` belongs to
/// `slugs[i]`. Each vector must be exactly 384 floats; anything else is
/// refused, because a dimension mismatch means the catalog was indexed by a
/// different model and every score would be silently wrong.
#[frb(async)]
pub fn set_index(slugs: Vec<String>, vectors: Vec<Vec<f32>>) -> Result<usize, ApiError> {
    let idx = ProductIndex::build(slugs, vectors).map_err(err)?;
    let n = idx.len();
    *slot().lock().map_err(|_| ApiError::engine("index mutex poisoned"))? = Some(idx);
    Ok(n)
}

/// Drop the index. Used when the catalog is refetched and before the new
/// vectors have parsed, so a search cannot rank against a stale catalog.
#[frb(async)]
pub fn clear_index() {
    if let Ok(mut guard) = slot().lock() {
        *guard = None;
    }
}

/// Number of products currently indexed, or 0 if none.
#[frb(async)]
pub fn index_size() -> usize {
    slot().lock().map(|g| g.as_ref().map_or(0, ProductIndex::len)).unwrap_or(0)
}

// ── Querying ────────────────────────────────────────────────────────────────

/// Embed `query` and return its 384-dim L2-normalised vector.
///
/// Not used by the app's search path (which calls [`search`] so the index
/// stays on the Rust side); exposed for the parity harness and for debugging.
#[frb(sync)]
pub fn embed(text: String) -> Result<Vec<f32>, ApiError> {
    let v = crate::inference::embed(&text);
    if v.len() != crate::EMBEDDING_DIMS {
        return Err(ApiError::engine(format!(
            "engine returned {} dims, expected {}",
            v.len(),
            crate::EMBEDDING_DIMS
        )));
    }
    Ok(v)
}

/// Semantic search over the loaded index, best match first.
///
/// Returns an empty list for an empty or whitespace-only query without
/// touching the engine — a user backspacing to nothing should not pay for an
/// embedding.
///
/// An empty *index* is an error, not an empty result: the two look identical
/// on screen and MEMORY.md §4 is about exactly that confusion on the website.
#[frb(async)]
pub fn search(query: String, limit: i32) -> Result<Vec<Hit>, ApiError> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }

    let guard = slot().lock().map_err(|_| ApiError::engine("index mutex poisoned"))?;
    let idx = guard.as_ref().ok_or_else(|| {
        ApiError::engine("no index loaded — call set_index() after fetching catalog.json")
    })?;

    let n = idx.len();
    let take = if limit <= 0 { n } else { (limit as usize).min(n) };
    idx.search_text(trimmed, take).map_err(err)
}

impl From<IndexError> for ApiError {
    fn from(e: IndexError) -> Self {
        ApiError::engine(e.to_string())
    }
}
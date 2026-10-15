/// Low-level `dart:ffi` bindings for the native ternlight engine.
///
/// Hand-written rather than generated. The counterpart is `rust/src/ffi.rs`;
/// the two files are a matched pair and any change to one needs the same change
/// to the other.
///
/// # Why not flutter_rust_bridge
///
/// The bridge was tried first and abandoned. `flutter_rust_bridge_codegen`
/// shells out to `cargo expand`, which needs `-Zunpretty=expanded` — a nightly
/// toolchain. That is not installable in this environment without fighting the
/// whole GNU/MSVC/binutils chain, and the binary it produced crashed
/// (`0xC0000005`) under this toolchain anyway. For a seven-function interface
/// that is a permanent tax on every `flutter build apk`, so the boundary is
/// hand-written instead. See MEMORY.md §6.
///
/// # Marshalling rules
///
/// * Rust returns NUL-terminated UTF-8 that it owns. Dart reads it and copies
///   out immediately — the pointer is only valid until the next call.
/// * Dart allocates and owns anything it passes in, and frees it in a `finally`.
/// * Every fallible call returns 0 on success and a negative code on failure;
///   the message comes from `alexLastError()`.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _LastErrorC = Pointer<Char> Function();
typedef _LastErrorD = Pointer<Char> Function();

typedef _InfoC = Pointer<Char> Function();
typedef _InfoD = Pointer<Char> Function();

typedef _ModelC = Pointer<Char> Function();
typedef _ModelD = Pointer<Char> Function();

typedef _DimsC = Int64 Function();
typedef _DimsD = int Function();

typedef _WarmUpC = Int32 Function();
typedef _WarmUpD = int Function();

typedef _SetIndexC = Int32 Function(Pointer<Pointer<Char>>, Pointer<Float>, Int64, Int64);
typedef _SetIndexD = int Function(Pointer<Pointer<Char>>, Pointer<Float>, int, int);

typedef _ClearIndexC = Void Function();
typedef _ClearIndexD = void Function();

typedef _IndexSizeC = Int64 Function();
typedef _IndexSizeD = int Function();

typedef _EmbedC = Int32 Function(Pointer<Char>, Pointer<Float>);
typedef _EmbedD = int Function(Pointer<Char>, Pointer<Float>);

typedef _SearchC = Int32 Function(Pointer<Char>, Int32, Pointer<Pointer<Char>>, Pointer<Double>, Int64);
typedef _SearchD = int Function(Pointer<Char>, int, Pointer<Pointer<Char>>, Pointer<Double>, int);

/// Raised when the native library is missing or a call fails.
class NativeEngineException implements Exception {
  NativeEngineException(this.message);

  final String message;

  @override
  String toString() => 'NativeEngineException: $message';
}

/// The loaded `libalex_store_native.so` and its resolved symbols.
///
/// Opening the library is deliberately lazy and failure-tolerant: on a desktop
/// test run, or in a widget test, there is no `.so` and the app must still
/// work. Call [isAvailable] before relying on anything else.
class NativeEngine {
  NativeEngine._(this.lib)
      : _lastError = lib.lookupFunction<_LastErrorC, _LastErrorD>('alex_last_error'),
        _engineInfo = lib.lookupFunction<_InfoC, _InfoD>('alex_engine_info'),
        _searchModel = lib.lookupFunction<_ModelC, _ModelD>('alex_search_model'),
        _embeddingDims = lib.lookupFunction<_DimsC, _DimsD>('alex_embedding_dims'),
        _warmUp = lib.lookupFunction<_WarmUpC, _WarmUpD>('alex_warm_up'),
        _setIndex = lib.lookupFunction<_SetIndexC, _SetIndexD>('alex_set_index'),
        _clearIndex = lib.lookupFunction<_ClearIndexC, _ClearIndexD>('alex_clear_index'),
        _indexSize = lib.lookupFunction<_IndexSizeC, _IndexSizeD>('alex_index_size'),
        _embed = lib.lookupFunction<_EmbedC, _EmbedD>('alex_embed'),
        _search = lib.lookupFunction<_SearchC, _SearchD>('alex_search');

  final DynamicLibrary lib;

  final _LastErrorD _lastError;
  final _InfoD _engineInfo;
  final _ModelD _searchModel;
  final _DimsD _embeddingDims;
  final _WarmUpD _warmUp;
  final _SetIndexD _setIndex;
  final _ClearIndexD _clearIndex;
  final _IndexSizeD _indexSize;
  final _EmbedD _embed;
  final _SearchD _search;

  static NativeEngine? _instance;
  static String? _loadError;

  /// The process-wide instance, or null if the library could not be opened.
  static NativeEngine? get instance {
    if (_instance != null) return _instance;
    if (_loadError != null) return null;
    try {
      _instance = NativeEngine._(_open());
      return _instance;
    } on Object catch (e) {
      _loadError = '$e';
      return null;
    }
  }

  /// Why [instance] is null, or null if it loaded.
  static String? get loadError => _loadError;

  static DynamicLibrary _open() {
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libalex_store_native.so');
    }
    if (Platform.isWindows) return DynamicLibrary.open('alex_store_native.dll');
    if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.open('DynamicLibrary.process()');
    }
    throw UnsupportedError('no native engine for ${Platform.operatingSystem}');
  }

  /// Throws a descriptive exception if the library is not loaded.
  static NativeEngine get require {
    final e = instance;
    if (e == null) {
      throw NativeEngineException(
        'native engine not available: ${_loadError ?? "unknown reason"}',
      );
    }
    return e;
  }

  // ── String helpers ────────────────────────────────────────────────────────

  /// Copy a Rust-owned NUL-terminated UTF-8 string into a Dart string.
  String _readCString(Pointer<Char> p) => p.cast<Utf8>().toDartString();

  /// Copy a Dart string into fresh native memory, NUL-terminated.
  ///
  /// The caller must `free()` the result. Encoded as UTF-8 by hand rather than
  /// via `package:ffi`'s helper so the allocation is ours to free.
  static Pointer<Char> _toNative(String s) {
    final encoded = _utf8Encode(s);
    final p = calloc<Uint8>(encoded.length + 1);
    for (var i = 0; i < encoded.length; i++) {
      p[i] = encoded[i];
    }
    p[encoded.length] = 0;
    return p.cast<Char>();
  }

  /// Minimal UTF-8 encoder. Slugs are ASCII in practice, but product text and
  /// user queries are not guaranteed to be, and a query typed with an accent or
  /// an emoji must not be silently truncated at the first non-ASCII byte.
  static List<int> _utf8Encode(String s) {
    final out = <int>[];
    for (final unit in s.runes) {
      if (unit < 0x80) {
        out.add(unit);
      } else if (unit < 0x800) {
        out.add(0xc0 | (unit >> 6));
        out.add(0x80 | (unit & 0x3f));
      } else if (unit < 0x10000) {
        out.add(0xe0 | (unit >> 12));
        out.add(0x80 | ((unit >> 6) & 0x3f));
        out.add(0x80 | (unit & 0x3f));
      } else {
        out.add(0xf0 | (unit >> 18));
        out.add(0x80 | ((unit >> 12) & 0x3f));
        out.add(0x80 | ((unit >> 6) & 0x3f));
        out.add(0x80 | (unit & 0x3f));
      }
    }
    return out;
  }

  String _lastErrorMessage() => _readCString(_lastError());

  void _check(int code, String what) {
    if (code < 0) {
      throw NativeEngineException('$what failed: ${_lastErrorMessage()}');
    }
  }

  // ── Surface ───────────────────────────────────────────────────────────────

  /// The model header parsed from the bundled `model.bin`.
  String get engineInfo => _readCString(_engineInfo());

  /// The `SEARCH_MODEL` the native build expects its vectors to match.
  String get searchModel => _readCString(_searchModel());

  /// Width of a ternlight embedding, as the engine reports it.
  int get embeddingDims => _embeddingDims();

  /// Force the model, tokenizer and weights to initialise. Idempotent.
  void warmUp() => _check(_warmUp(), 'warm_up');

  /// Number of products currently indexed, or 0.
  int get indexSize => _indexSize();

  /// Drop the index.
  void clearIndex() => _clearIndex();

  /// Load `count` slugs and their `count * dims` vectors, row-major.
  void setIndex(List<String> slugs, Float32List vectors, {required int dims}) {
    final n = slugs.length;
    if (vectors.length != n * dims) {
      throw ArgumentError(
        'expected ${n * dims} floats for $n products at $dims dims, '
        'got ${vectors.length}',
      );
    }
    if (n == 0) {
      clearIndex();
      return;
    }

    final slugPtrs = calloc<Pointer<Char>>(n);
    final vecPtr = calloc<Float>(n * dims);
    try {
      for (var i = 0; i < n; i++) {
        slugPtrs[i] = _toNative(slugs[i]);
      }
      final dst = vecPtr.asTypedList(n * dims);
      dst.setAll(0, vectors);
      _check(_setIndex(slugPtrs, vecPtr, n, dims), 'set_index');
    } finally {
      for (var i = 0; i < n; i++) {
        final p = slugPtrs[i];
        if (p != nullptr) calloc.free(p);
      }
      calloc.free(slugPtrs);
      calloc.free(vecPtr);
    }
  }

  /// Embed `text`, returning a unit-length vector of [embeddingDims] floats.
  Float32List embed(String text) {
    final dims = embeddingDims;
    final out = calloc<Float>(dims);
    final p = _toNative(text);
    try {
      _check(_embed(p, out), 'embed');
      return Float32List.fromList(out.asTypedList(dims));
    } finally {
      calloc.free(p);
      calloc.free(out);
    }
  }

  /// Semantic search over the loaded index, best match first.
  ///
  /// Returns (slug, score) pairs. `limit <= 0` means "everything indexed".
  List<(String, double)> search(String query, {int limit = 10}) {
    final n = indexSize;
    if (n == 0) {
      throw NativeEngineException('search called before set_index');
    }
    final cap = limit <= 0 ? n : (limit < n ? limit : n);
    if (cap == 0) return const [];

    final slugPtrs = calloc<Pointer<Char>>(cap);
    final scores = calloc<Double>(cap);
    final q = _toNative(query);
    try {
      final count = _search(q, limit, slugPtrs, scores, cap);
      if (count < 0) {
        throw NativeEngineException('search failed: ${_lastErrorMessage()}');
      }
      final out = <(String, double)>[];
      for (var i = 0; i < count && i < cap; i++) {
        out.add((
          slugPtrs[i].cast<Utf8>().toDartString(),
          scores[i],
        ));
      }
      return out;
    } finally {
      calloc.free(q);
      calloc.free(slugPtrs);
      calloc.free(scores);
    }
  }
}
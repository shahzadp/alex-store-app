/// Saved for later, and recently viewed — the app's two on-device lists.
///
/// Neither is an account and neither touches the network. Two JSON files in
/// the app-support directory, one array of slugs each, written through on
/// every mutation. Reads that fail (no plugin, an unreadable disk, a value
/// from an older build that is not a list) read as an empty list rather than
/// throwing, because a broken wishlist must never take the shop down with it.
///
/// Both classes share the same shape so either can be exercised from a test
/// with a temporary directory, exactly like `VoucherStore`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A slug list with write-through persistence and a stream for the UI.
///
/// [maxItems] caps the list when set (recently viewed keeps six). Saved is
/// uncapped — a shopper can save as much as they like.
abstract class JsonSlugList {
  JsonSlugList({Future<Directory> Function()? directory, this.maxItems})
      : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  final int? maxItems;

  /// File name for the list, e.g. `saved.v1.json`.
  String get fileName;

  List<String> _items = const [];
  bool _loaded = false;
  final _controller = StreamController<List<String>>.broadcast();

  /// The current list. Empty until [load] has resolved, like `CatalogState`.
  List<String> get state => _items;

  /// Emits on every change, including the transition from not-loaded to
  /// loaded. Never emits null, never closes.
  Stream<List<String>> get stream => _controller.stream;

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _items = decoded.whereType<String>().toList();
        _controller.add(_items);
      }
    } catch (_) {
      _items = const [];
    }
  }

  Future<void> load() => _ensureLoaded();

  Future<void> _persist() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_items));
    } catch (_) {
      // Best effort; the in-memory list is already updated.
    }
  }

  Future<List<String>> _mutate(List<String> next) async {
    _items = next;
    await _persist();
    _controller.add(_items);
    return _items;
  }

  Future<void> toggle(String slug) async {
    await _ensureLoaded();
    final next = [..._items];
    final index = next.indexOf(slug);
    if (index >= 0) {
      next.removeAt(index);
    } else {
      next.insert(0, slug);
    }
    await _mutate(next);
  }

  Future<bool> contains(String slug) async {
    await _ensureLoaded();
    return _items.contains(slug);
  }

  Future<void> clear() async {
    await _ensureLoaded();
    await _mutate(const []);
  }

  /// Most-recent-first insert, used by recently viewed.
  Future<void> record(String slug) async {
    await _ensureLoaded();
    final next = [slug, ..._items.where((s) => s != slug)];
    final cap = maxItems;
    await _mutate(
        cap != null && next.length > cap ? next.sublist(0, cap) : next);
  }

  void dispose() {
    _controller.close();
  }
}

/// The wishlist. No cap — a shopper can save as much as they like.
class SavedStore extends JsonSlugList {
  SavedStore({super.directory});

  @override
  String get fileName => 'saved.v1.json';
}

/// Recently viewed, capped so the home row stays a glanceable strip.
class RecentStore extends JsonSlugList {
  RecentStore({super.directory}) : super(maxItems: 6);

  @override
  String get fileName => 'recent.v1.json';
}

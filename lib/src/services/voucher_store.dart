/// Remembers that the free-delivery voucher has been seen.
///
/// A file, not a preferences plugin: `path_provider` is already a dependency
/// and one boolean does not justify another. The version in the file name means
/// a future voucher can be shown afresh rather than being suppressed by a
/// marker left behind by an older build — the same reasoning as the site's
/// `alexstore.voucher.v1` key.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class VoucherStore {
  /// [directory] overrides the app-support directory, so the store can be
  /// exercised from a test without a plugin binding — the same seam
  /// `CatalogService` uses for its cache.
  VoucherStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  static const _fileName = 'voucher-seen.v1';

  Future<File> _file() async => File('${(await _directory()).path}/$_fileName');

  /// True when the voucher has already been claimed or dismissed.
  ///
  /// A failure here (no plugin, an unreadable disk) reads as "not seen":
  /// showing the offer again is the harmless direction to fail in.
  Future<bool> hasSeen() async {
    try {
      return await (await _file()).exists();
    } catch (_) {
      return false;
    }
  }

  /// Best effort. If the marker cannot be written the offer may repeat, which
  /// is preferable to blocking the shopper behind an error they cannot fix.
  Future<void> markSeen() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(DateTime.now().toIso8601String());
    } catch (_) {
      // Ignored on purpose; see above.
    }
  }
}

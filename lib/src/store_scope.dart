/// Access to the app's on-device lists.
///
/// Its own file rather than living in `main.dart`, mirroring `catalog_scope.dart`
/// — screens reach for it from `lib/src/screens/` and `lib/src/widgets/`, and
/// the app has more than one piece of shared state now. Plain `InheritedWidget`
/// again: no state-management package for three lists (MEMORY.md §3).
library;

import 'package:flutter/widgets.dart';

import 'services/local_stores.dart';

class StoreScope extends InheritedWidget {
  const StoreScope({
    super.key,
    required this.saved,
    required this.recent,
    required super.child,
  });

  final SavedStore saved;
  final RecentStore recent;

  static StoreScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<StoreScope>();
    assert(scope != null, 'StoreScope is missing from the widget tree');
    return scope!;
  }

  /// The scope when present, else null.
  ///
  /// The product card is pumped bare by the layout and geometry tests, so it
  /// reads the saved store through this rather than [of] — the absence of a
  /// scope degrades to "no heart", not an assertion.
  static StoreScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoreScope>();

  @override
  bool updateShouldNotify(StoreScope oldWidget) =>
      oldWidget.saved != saved || oldWidget.recent != recent;
}

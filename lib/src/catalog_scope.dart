/// Access to the one [CatalogService] in the tree.
///
/// Its own file rather than living in `main.dart`. Screens reach for it from
/// `lib/src/screens/`, and importing the app root from there meant a relative
/// path that pointed at a file that does not exist — `../main.dart` from
/// `lib/src/screens/` is `lib/src/main.dart`, not `lib/main.dart`. A widget
/// scope belongs next to the services it exposes anyway.
library;

import 'package:flutter/widgets.dart';

import 'services/catalog_service.dart';

/// A plain `InheritedWidget` rather than a state-management package.
///
/// The app has exactly one piece of shared state. Pulling in `provider` or
/// `riverpod` for it would be the Flutter equivalent of adding `package.json`
/// to a repo that deliberately has none (MEMORY.md §3).
class CatalogScope extends InheritedWidget {
  const CatalogScope({
    super.key,
    required this.service,
    required super.child,
  });

  final CatalogService service;

  static CatalogService of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<CatalogScope>();
    assert(scope != null, 'CatalogScope is missing from the widget tree');
    return scope!.service;
  }

  @override
  bool updateShouldNotify(CatalogScope oldWidget) => oldWidget.service != service;
}
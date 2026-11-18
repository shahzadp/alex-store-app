/// The heart toggle that saves a product for later.
///
/// Two variants of the same control: [SaveToggleVariant.onImage] floats a
/// disc over the product image on cards, and [SaveToggleVariant.appBar] is a
/// plain icon button for toolbars. Both read the one [SavedStore] in scope
/// and rebuild from the store's stream — so tapping either anywhere updates
/// every heart on screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../store_scope.dart';
import '../models/catalog.dart';
import '../services/local_stores.dart';

enum SaveToggleVariant { onImage, appBar }

class SaveToggle extends StatelessWidget {
  const SaveToggle({
    super.key,
    required this.product,
    this.variant = SaveToggleVariant.onImage,
  });

  final Product product;
  final SaveToggleVariant variant;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.maybeOf(context)?.saved;

    // No scope (the card pumped bare by layout tests): render nothing rather
    // than a dead control.
    if (store == null) return const SizedBox.shrink();

    return StreamBuilder<List<String>>(
      stream: store.stream,
      initialData: store.state,
      builder: (context, snapshot) {
        final saved = snapshot.data?.contains(product.slug) ?? false;

        final icon = Icon(
          saved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          size: variant == SaveToggleVariant.onImage ? 19 : 24,
          color: saved ? StoreTheme.accent : StoreTheme.ink,
        );

        if (variant == SaveToggleVariant.appBar) {
          return IconButton(
            icon: icon,
            tooltip: saved ? 'Remove from saved' : 'Save for later',
            onPressed: () => _toggle(store),
          );
        }

        return Semantics(
          button: true,
          label: saved
              ? 'Remove ${product.name} from saved'
              : 'Save ${product.name} for later',
          child: Tooltip(
            message: saved ? 'Remove from saved' : 'Save for later',
            child: Material(
              color: StoreTheme.surface.withValues(alpha: 0.88),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _toggle(store),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: icon,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _toggle(SavedStore store) {
    HapticFeedback.selectionClick();
    unawaited(store.toggle(product.slug));
  }
}

/// The heart toggle that saves a product for later.
///
/// Two variants of the same control: [SaveToggleVariant.onImage] floats a
/// disc over the product image on cards, and [SaveToggleVariant.appBar] is a
/// plain icon button for toolbars. Both read the one [SavedStore] in scope
/// and rebuild from the store's stream — so tapping either anywhere updates
/// every heart on screen.
///
/// The heart bounces with an elastic overshoot whenever it flips, and the
/// on-image variant fires one expanding ring when it lands in the saved
/// state — the same "acknowledged" gesture the voucher's confetti carries, at
/// card scale. Both are skipped when the shopper asked for less motion.
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
        final reduceMotion = MediaQuery.disableAnimationsOf(context);

        // A bounce keyed on the flip: it replays on every toggle instead of
        // playing once per element lifetime.
        Widget bounce(Widget child) {
          if (reduceMotion) return child;
          return TweenAnimationBuilder<double>(
            key: ValueKey<bool>(saved),
            tween: Tween<double>(begin: 0.55, end: 1.0),
            duration: const Duration(milliseconds: 260),
            curve: Curves.elasticOut,
            builder: (context, scale, _) => Transform.scale(
              scale: scale,
              child: child,
            ),
          );
        }

        final icon = bounce(Icon(
          saved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          size: variant == SaveToggleVariant.onImage ? 19 : 24,
          color: saved ? StoreTheme.accent : StoreTheme.ink,
        ));

        // One expanding ring as the heart lands in the saved state.
        Widget ring(Widget child) {
          if (!saved || reduceMotion) return child;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  key: const ValueKey<String>('saved-ring'),
                  tween: Tween<double>(begin: 1.0, end: 2.2),
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOut,
                  builder: (context, t, _) {
                    final opacity = (1 - ((t - 1.0) / 1.2)).clamp(0.0, 1.0);
                    return Opacity(
                      opacity: opacity,
                      child: Transform.scale(
                        scale: t,
                        child: Container(
                          width: 37,
                          height: 37,
                          decoration: ShapeDecoration(
                            shape: CircleBorder(
                              side: BorderSide(
                                color: StoreTheme.accent,
                                width: 2,
                              ),
                            ),
                            color: StoreTheme.accent.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              child,
            ],
          );
        }

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
            child: ring(
              Material(
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

/// Empty, error and "nothing matched" states.
///
/// Each of these used to be a single line of centred body text. An empty state
/// that says only "Nothing matches those filters" gives the shopper nowhere to
/// go — they have to work out for themselves that the Clear button exists. A
/// designed one names the situation, explains it in one line, and offers the
/// next action, which is the difference between a dead end and a prompt.
///
/// The reset button is deliberately present even on the states where it is not
/// strictly needed: a screen with no way out is the single most reliable way to
/// make an app feel untrustworthy.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class StoreEmptyState extends StatelessWidget {
  const StoreEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(StoreTheme.spaceXxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: StoreTheme.surface,
                shape: BoxShape.circle,
                boxShadow: StoreTheme.shadowSm,
              ),
              child: Icon(icon, size: 24, color: StoreTheme.inkMuted),
            ),
            const SizedBox(height: StoreTheme.spaceLg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: StoreTheme.spaceSm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: StoreTheme.spaceXl),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown when the catalog cannot be loaded.
class StoreErrorState extends StatelessWidget {
  const StoreErrorState({
    super.key,
    this.message,
    required this.onRetry,
  });

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return StoreEmptyState(
      icon: Icons.wifi_off_rounded,
      title: 'The store could not be loaded',
      message: message ??
          'The catalog is downloaded every time the app opens, so this is '
              'usually the connection rather than the app.',
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

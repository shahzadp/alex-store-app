/// The first-visit free-delivery voucher, and its confetti celebration.
///
/// This replaces the old announcement strip: the same offer, announced once
/// rather than pinned above every screen. It is a plain overlay — not a route —
/// so it sits above whatever the shopper was looking at (including the launch
/// video) without disturbing navigation.
///
/// The confetti is drawn by hand with a [CustomPainter] and one
/// [AnimationController]. A confetti package would be a dependency for a
/// one-off burst, and the site draws its own for the same reason.
library;

import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

class VoucherPrompt extends StatefulWidget {
  const VoucherPrompt({
    super.key,
    required this.title,
    required this.description,
    required this.code,
    required this.terms,
    required this.onClose,
  });

  final String title;
  final String description;
  final String code;
  final String terms;

  /// Called once when the shopper claims ([claimed] true) or dismisses.
  final void Function(bool claimed) onClose;

  @override
  State<VoucherPrompt> createState() => _VoucherPromptState();
}

class _VoucherPromptState extends State<VoucherPrompt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burst =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  List<_Piece> _pieces = const [];
  bool _claimed = false;
  bool _closing = false;

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  void _claim() {
    if (_claimed) return;
    setState(() {
      _claimed = true;
      // Respect a stated preference for less motion: no burst at all.
      if (!MediaQuery.disableAnimationsOf(context)) {
        _pieces = _makePieces();
        _burst.forward(from: 0);
      }
    });
    // Let the celebration read before the overlay goes.
    Future.delayed(Duration(milliseconds: _pieces.isEmpty ? 900 : 2000), _finishClaim);
  }

  void _finishClaim() {
    if (!mounted || _closing) return;
    _closing = true;
    widget.onClose(true);
  }

  void _dismiss() {
    if (_closing) return;
    _closing = true;
    widget.onClose(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: widget.title,
      child: Stack(
        children: [
          // The dimmed backdrop. It is a sibling *below* the card, so a tap on
          // the card never reaches it and a tap on the dim area dismisses.
          Positioned.fill(
            child: GestureDetector(
              onTap: _dismiss,
              child: const ColoredBox(color: Color(0x8C2E2638)),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(StoreTheme.spaceXl),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Material(
                  color: StoreTheme.surface,
                  borderRadius: StoreTheme.rMd,
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(26, 26, 26, 22),
                    decoration: BoxDecoration(
                      border: Border.all(color: StoreTheme.line),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('WELCOME OFFER',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: StoreTheme.inkAccent)),
                        const SizedBox(height: StoreTheme.spaceSm),
                        Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium,
                        ),
                        if (widget.description.isNotEmpty) ...[
                          const SizedBox(height: StoreTheme.spaceSm),
                          Text(
                            widget.description,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                        if (widget.code.isNotEmpty) ...[
                          const SizedBox(height: StoreTheme.spaceLg),
                          _CodeChip(code: widget.code),
                        ],
                        if (widget.terms.isNotEmpty) ...[
                          const SizedBox(height: StoreTheme.spaceMd),
                          Text(
                            widget.terms,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                        const SizedBox(height: StoreTheme.spaceXl),
                        if (_claimed)
                          Text(
                            'Voucher claimed — see you at checkout.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelLarge
                                ?.copyWith(color: StoreTheme.whatsapp),
                          )
                        else
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _claim,
                              child: const Text('Claim voucher'),
                            ),
                          ),
                        if (!_claimed)
                          TextButton(
                            onPressed: _dismiss,
                            child: const Text('No thanks'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Drawn last, so the confetti falls over the card rather than behind
          // it. IgnorePointer keeps it from eating a tap on the button.
          if (_pieces.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _burst,
                  builder: (context, _) => CustomPaint(
                    painter: _ConfettiPainter(_pieces, _burst.value),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CodeChip extends StatelessWidget {
  const _CodeChip({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        color: StoreTheme.bg,
        border: Border.fromBorderSide(BorderSide(color: StoreTheme.line)),
      ),
      child: Column(
        children: [
          Text('CODE', style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(
            code,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: StoreTheme.inkAccent,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// One confetti piece, with everything needed to place it at a given time.
class _Piece {
  const _Piece({
    required this.vx,
    required this.vy,
    required this.size,
    required this.spin,
    required this.color,
  });

  final double vx;
  final double vy;
  final double size;
  final double spin;
  final Color color;
}

const _pieceColors = <Color>[
  StoreTheme.accent,
  Color(0xFF25D366),
  Color(0xFFD9CCEA),
  Color(0xFFE3D6EE),
  Color(0xFFCFC3E3),
  Color(0xFFF2C94C),
];

/// Seeded so a burst looks the same every time it is drawn, which keeps the
/// animation honest and the widget testable.
List<_Piece> _makePieces() {
  final rnd = Random(7);
  return List<_Piece>.generate(140, (_) {
    return _Piece(
      vx: (rnd.nextDouble() - 0.5) * 480,
      vy: -240 - rnd.nextDouble() * 520,
      size: 6 + rnd.nextDouble() * 8,
      spin: (rnd.nextDouble() - 0.5) * 8,
      color: _pieceColors[rnd.nextInt(_pieceColors.length)],
    );
  });
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.pieces, this.t);

  final List<_Piece> pieces;

  /// Progress, 0 to 1, over the controller's duration.
  final double t;

  /// How long the burst lasts, matching the controller. Used to turn [t] into
  /// seconds so the physics below is in real units.
  static const _durationSeconds = 2.4;
  static const _gravity = 900.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;

    final seconds = t * _durationSeconds;
    final origin = Offset(size.width / 2, size.height * 0.38);
    final paint = Paint()..style = PaintingStyle.fill;
    final alpha = (1 - t).clamp(0.0, 1.0);

    for (final piece in pieces) {
      final dx = origin.dx + piece.vx * seconds;
      final dy = origin.dy + piece.vy * seconds + 0.5 * _gravity * seconds * seconds;
      if (dy > size.height + 40) continue;

      paint.color = piece.color.withValues(alpha: alpha);
      canvas.save();
      canvas.translate(dx, dy);
      canvas.rotate(piece.spin * seconds);
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: piece.size,
          height: piece.size * 0.6,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) =>
      old.t != t || !identical(old.pieces, pieces);
}

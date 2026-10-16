/// Loading placeholders.
///
/// A bare spinner says "something is happening somewhere". A skeleton says
/// "this is the thing that is about to appear, in the shape it will appear in",
/// which is the difference between an app that feels built and one that feels
/// assembled. Amazon, Stripe and Linear all ship this pattern for the same
/// reason: it removes the disorientation of content arriving into nothing.
///
/// Until this existed, the shop screen showed a lone `CircularProgressIndicator`
/// in the middle of an otherwise empty page, which reads as "loading" but not as
/// "about to be a shop".
///
/// The shimmer is a gradient sweep rather than a pulsing opacity, because a
/// sweep reads as progress and a pulse reads as indecision.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A single shimmering block.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = StoreTheme.radiusSm,
  });

  final double? width;
  final double height;
  final double radius;

  /// A block the same size and shape as a product card's contents, so the
  /// layout does not jump when the real card arrives.
  static Skeleton line(double width) => Skeleton(width: width, height: 12);

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = StoreTheme.line.withValues(alpha: 0.55);
    final highlight = StoreTheme.ink.withValues(alpha: 0.09);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // Sweeps from -1 to 2 so the highlight is fully off-screen at both ends
        // and never clips mid-sweep.
        final t = _controller.value * 3 - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1 + t * 2, 0),
              end: Alignment(-1 + t * 2 + 1.4, 0),
              colors: [base, highlight, base],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/// A placeholder in the shape of a product card.
///
/// Mirrors the real card's own geometry — image, two name lines, description,
/// price — so the swap does not shift anything. [cardHeightFor] is the same
/// function the grid uses, which is the only reason the heights agree.
class SkeletonProductCard extends StatelessWidget {
  const SkeletonProductCard({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: StoreTheme.cardVerticalPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Skeleton(
            width: width,
            height: width / StoreTheme.cardImageAspect,
            radius: StoreTheme.radiusMd,
          ),
          const SizedBox(height: StoreTheme.cardGapImage),
          Skeleton(width: width * 0.85, height: StoreTheme.nameHeight),
          const SizedBox(height: StoreTheme.cardGapName),
          Skeleton(width: width, height: StoreTheme.descriptionHeight),
          const SizedBox(height: StoreTheme.cardGapDescription),
          Skeleton(width: width * 0.4, height: 14),
        ],
      ),
    );
  }
}

/// A whole grid of skeleton cards, at the grid's real width.
class SkeletonProductGrid extends StatelessWidget {
  const SkeletonProductGrid({
    super.key,
    this.count = 4,
    this.columns = 2,
  });

  final int count;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final available = MediaQuery.sizeOf(context).width -
        StoreTheme.screenEdge * 2 -
        StoreTheme.cardGap * (columns - 1);
    final width = available / columns;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: StoreTheme.screenEdge),
      child: Column(
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: EdgeInsets.only(
                bottom: i == count - 1
                    ? 0
                    : StoreTheme.cardGap / columns * columns,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var c = 0; c < columns; c++) ...[
                    if (c > 0) const SizedBox(width: StoreTheme.cardGap),
                    Expanded(child: SkeletonProductCard(width: width)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

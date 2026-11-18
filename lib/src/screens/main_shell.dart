/// The app's persistent tab shell — Home / Shop / Search / Saved.
///
/// One `Scaffold` with a Material 3 `NavigationBar`, an `IndexedStack` so
/// each tab keeps its scroll position and state, and a [PopScope] that sends
/// back-navigation to Home instead of out of the app. The screens stay
/// exactly what they were — full-page `Scaffold`s; the shell only supplies
/// the persistent chrome.
///
/// Screens inside the shell switch tabs through [ShellSwitcher] when it is
/// present and fall back to a pushed route when it is not, so they can also
/// be used stand-alone (tests pump them straight into a `MaterialApp`).
library;

import 'package:flutter/material.dart';

import '../store_scope.dart';
import '../services/local_stores.dart';
import 'home_screen.dart';
import 'saved_screen.dart';
import 'search_screen.dart';
import 'shop_screen.dart';

/// Shell tab indices.
abstract final class ShellTab {
  static const home = 0;
  static const shop = 1;
  static const search = 2;
  static const saved = 3;
}

/// Switches the shell to a ShellTab. Absent outside [MainShell].
class ShellSwitcher extends InheritedWidget {
  const ShellSwitcher({
    super.key,
    required this.switchTo,
    required super.child,
  });

  final void Function(int index) switchTo;

  /// Switch to [index]. Returns false when there is no shell (stand-alone),
  /// so the caller can fall back to a pushed route.
  static bool maybeSwitchTo(BuildContext context, int index) {
    final shell = context.getInheritedWidgetOfExactType<ShellSwitcher>();
    if (shell == null) return false;
    shell.switchTo(index);
    return true;
  }

  @override
  bool updateShouldNotify(ShellSwitcher oldWidget) => false;
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = ShellTab.home;

  late final List<Widget> _tabs = const [
    HomeScreen(),
    ShopScreen(),
    SearchScreen(),
    SavedScreen(),
  ];

  void _switchTo(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final saved = StoreScope.of(context).saved;

    return PopScope(
      // Android back leaves the app only from Home. Anywhere else it is a
      // step back toward Home, which is what a tab bar implies.
      canPop: _index == ShellTab.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index != ShellTab.home) _switchTo(ShellTab.home);
      },
      child: ShellSwitcher(
        switchTo: _switchTo,
        child: Scaffold(
          body: IndexedStack(index: _index, children: _tabs),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _switchTo,
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              const NavigationDestination(
                icon: Icon(Icons.shopping_bag_outlined),
                selectedIcon: Icon(Icons.shopping_bag_rounded),
                label: 'Shop',
              ),
              const NavigationDestination(
                icon: Icon(Icons.search),
                selectedIcon: Icon(Icons.search_rounded),
                label: 'Search',
              ),
              NavigationDestination(
                icon: _SavedBadge(
                    store: saved,
                    child: const Icon(Icons.favorite_border_rounded)),
                selectedIcon: _SavedBadge(
                    store: saved, child: const Icon(Icons.favorite_rounded)),
                label: 'Saved',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The heart with a live count on the Saved tab — the one place the
/// wishlist size is worth surfacing without opening it.
class _SavedBadge extends StatelessWidget {
  const _SavedBadge({required this.store, required this.child});

  final SavedStore store;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<String>>(
      stream: store.stream,
      initialData: store.state,
      builder: (context, snapshot) {
        final count = snapshot.data?.length ?? 0;
        final icon = TweenAnimationBuilder<double>(
          // Replays when the number changes — a small acknowledgement, not a
          // celebration, on every save and every remove.
          key: ValueKey<int>(count),
          tween: Tween<double>(begin: 0.72, end: 1.0),
          duration: const Duration(milliseconds: 280),
          curve: Curves.elasticOut,
          builder: (context, scale, _) => Transform.scale(
            scale: scale,
            child: child,
          ),
        );
        if (count == 0) return icon;
        return Badge(label: Text('$count'), child: icon);
      },
    );
  }
}

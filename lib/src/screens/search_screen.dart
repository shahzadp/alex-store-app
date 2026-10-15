import 'dart:async';

import 'package:flutter/material.dart';

import '../catalog_scope.dart';
import '../models/catalog.dart';
import '../services/search_engine.dart';
import '../theme.dart';
import 'product_screen.dart';

/// Semantic search, backed by the native ternlight engine.
///
/// # How a query is answered
///
/// 1. Dart debounces the keystroke (see [_debounce]) — the engine embeds on
///    every call, and 250 ms is long enough to avoid embedding "mug" then
///    "mugs" then "mugs " for one keystroke.
/// 2. [CatalogService.search] hands the query to Rust.
/// 3. Rust embeds it natively and dots it against the index already resident
///    there, returning at most ten slugs and scores.
/// 4. Dart maps the slugs back to products.
///
/// No request leaves the device, and there is nothing to download: the model
/// ships inside the APK.
///
/// # Failure is shown, never hidden
///
/// A search that silently returns nothing is indistinguishable from a store
/// that does not stock the thing being asked for. So an incomplete index, a
/// model mismatch and a missing engine each get their own message
/// ([SearchProblem] exists for exactly this).
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  Timer? _debounce;

  List<(Product, double)> _results = const [];
  SearchProblem? _problem;
  bool _busy = false;
  bool _touched = false;

  /// Long enough to coalesce a word, short enough to feel live.
  static const _debounceFor = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // Move the keyboard up on open. On a phone the field is at the very top
    // and the suggestion row is below it, so waiting for a tap costs a
    // keystroke nobody asked for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();

    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _problem = null;
        _busy = false;
        _touched = false;
      });
      return;
    }

    setState(() {
      _touched = true;
      _busy = true;
    });

    _debounce = Timer(_debounceFor, () => _run(query));
  }

  Future<void> _run(String query) async {
    // A newer keystroke may have landed while this was queued.
    if (!mounted || query != _controller.text.trim()) return;

    final service = CatalogScope.of(context);
    try {
      final hits = await service.search(query);
      if (!mounted || query != _controller.text.trim()) return;
      setState(() {
        _results = hits;
        _problem = null;
        _busy = false;
      });
    } on SearchException catch (e) {
      if (!mounted || query != _controller.text.trim()) return;
      setState(() {
        _results = const [];
        _problem = e.problem;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = CatalogScope.of(context);
    final catalog = service.state.catalog;

    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: 'What are you looking for?',
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _controller.clear,
                      ),
              ),
            ),
          ),
          if (catalog != null && !catalog.isSearchable)
            _IndexWarning(slugs: catalog.unindexedSlugs),
          Expanded(child: _body(catalog)),
        ],
      ),
    );
  }

  Widget _body(Catalog? catalog) {
    if (!_touched) return _Suggestions(catalog: catalog);

    if (_busy && _results.isEmpty) {
      return const Center(
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: StoreTheme.inkMuted)),
      );
    }

    if (_problem != null) {
      return _ProblemView(problem: _problem!, onRetry: () {
        final q = _controller.text.trim();
        if (q.isNotEmpty) _run(q);
      });
    }

    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing matched "${_controller.text.trim()}".',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }

    return ListView.separated(
      // The extra bottom padding clears the three-button navigation bar, so
      // the last result can be scrolled out from under it.
      padding: EdgeInsets.fromLTRB(
          20, 4, 20, 28 + StoreTheme.bottomSafeInset(context)),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final (product, score) = _results[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(product.name, style: Theme.of(context).textTheme.titleSmall),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              product.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          trailing: Text(
            product.price.formatted,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ProductScreen(slug: product.slug)),
          ),
        );
      },
    );
  }
}

/// Shown before anything is typed.
///
/// Phrased as phrasings a shopper would use, not product names — the point of
/// a semantic index is that you do not have to know what things are called.
/// CATALOG-GUIDE.md §9 asks for exactly this when verifying a reindex.
class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.catalog});

  final Catalog? catalog;

  static const _examples = [
    'something to drink out of',
    'warm up my hands',
    'for the dinner table',
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, 28 + StoreTheme.bottomSafeInset(context)),
      children: [
        Text(
          'Search by what you need, not what it is called.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 18),
        for (final e in _examples)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.north_east, size: 15, color: StoreTheme.inkMuted),
            title: Text(e, style: Theme.of(context).textTheme.bodyLarge),
            onTap: () {
              final field = context.findAncestorStateOfType<_SearchScreenState>();
              field?._controller.text = e;
            },
          ),
        const SizedBox(height: 22),
        if (catalog != null)
          Text(
            'Search runs on this device. No query leaves the phone.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

/// Warns that the site's index is incomplete.
///
/// A missing vector means the app refuses to search rather than returning
/// whatever it can rank — which is the same trade the site makes in
/// `search.js`, and for the same reason (CATALOG-GUIDE.md §1).
class _IndexWarning extends StatelessWidget {
  const _IndexWarning({required this.slugs});

  final List<String> slugs;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6E5),
        border: Border.all(color: const Color(0xFFE8D9B0)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        slugs.isEmpty
            ? 'Search is unavailable while the catalog is being reindexed.'
            : 'Search is unavailable: ${slugs.join(', ')} ${slugs.length == 1 ? 'has' : 'have'} no '
                'search vector yet.',
        style: const TextStyle(fontSize: 12.5, height: 1.4, color: Color(0xFF6B5320)),
      ),
    );
  }
}

class _ProblemView extends StatelessWidget {
  const _ProblemView({required this.problem, required this.onRetry});

  final SearchProblem problem;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = switch (problem) {
      SearchProblem.noIndex => const SearchException(SearchProblem.noIndex, '').userMessage,
      SearchProblem.incompleteIndex =>
        const SearchException(SearchProblem.incompleteIndex, '').userMessage,
      SearchProblem.modelMismatch =>
        const SearchException(SearchProblem.modelMismatch, '').userMessage,
      SearchProblem.engineUnavailable =>
        const SearchException(SearchProblem.engineUnavailable, '').userMessage,
      SearchProblem.empty => 'Type something to search.',
    };

    final retryable = problem == SearchProblem.engineUnavailable || problem == SearchProblem.noIndex;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            if (retryable) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}
import 'dart:async';

import 'package:flutter/material.dart';

import 'src/catalog_scope.dart';
import 'src/screens/home_screen.dart';
import 'src/services/catalog_service.dart';
import 'src/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AlexStoreApp());
}

class AlexStoreApp extends StatefulWidget {
  const AlexStoreApp({super.key});

  @override
  State<AlexStoreApp> createState() => _AlexStoreAppState();
}

class _AlexStoreAppState extends State<AlexStoreApp> {
  late final CatalogService _service;

  @override
  void initState() {
    super.initState();
    _service = CatalogService();
    // Fire and forget. The first frame renders immediately and HomeScreen
    // shows a spinner off `service.stream` while this resolves — blocking on
    // the network would mean a white screen on a slow connection, which is the
    // single worst first impression a store can give.
    unawaited(_service.load());
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CatalogScope(
      service: _service,
      child: MaterialApp(
        title: 'Alex Store',
        debugShowCheckedModeBanner: false,
        theme: StoreTheme.light(),
        home: const HomeScreen(),
      ),
    );
  }
}
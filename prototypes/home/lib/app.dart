import 'package:flutter/material.dart';

import 'catalog_repo.dart';
import 'home_screen.dart';

class HomeProtoApp extends StatelessWidget {
  final CatalogRepo repo;
  const HomeProtoApp({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4), brightness: Brightness.dark)),
      home: Scaffold(body: HomeScreen(repo: repo)),
    );
  }
}

import 'package:flutter/material.dart';

import '../shell/tab_placeholder.dart';

/// Settings surface. Owned by the connect ticket (03) — the host registry,
/// warning gate, and scan live there. This scaffold provides the route and a
/// placeholder body so the connect-first view has somewhere to point.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const TabPlaceholder(title: 'Connect', icon: Icons.tune),
    );
  }
}

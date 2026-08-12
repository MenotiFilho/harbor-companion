import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/routes.dart';
import 'app/shell/shell_screen.dart';
import 'app/settings/settings_screen.dart';
import 'app/theme.dart';

class HarborCompanionApp extends StatelessWidget {
  const HarborCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Harbor Companion',
      theme: AppTheme.dark,
      initialRoute: AppRoutes.shell,
      routes: {
        AppRoutes.shell: (_) => const ShellScreen(),
        AppRoutes.settings: (_) => const SettingsScreen(),
      },
    );
  }
}

void main() {
  runApp(const ProviderScope(child: HarborCompanionApp()));
}

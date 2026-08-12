import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/connect/connect_controller.dart';
import 'app/connect/host_registry.dart';
import 'app/connect/lan_scan.dart';
import 'app/home/detail_screen.dart';
import 'app/routes.dart';
import 'app/shell/shell_screen.dart';
import 'app/settings/settings_screen.dart';
import 'app/theme.dart';

class HarborCompanionApp extends ConsumerStatefulWidget {
  const HarborCompanionApp({super.key});

  @override
  ConsumerState<HarborCompanionApp> createState() => _HarborCompanionAppState();
}

class _HarborCompanionAppState extends ConsumerState<HarborCompanionApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause reconnect timers while the app is backgrounded (story #15).
    ref
        .read(connectControllerProvider.notifier)
        .setBackgrounded(state != AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Harbor Companion',
      theme: AppTheme.dark,
      initialRoute: AppRoutes.shell,
      routes: {
        AppRoutes.shell: (_) => const ShellScreen(),
        AppRoutes.settings: (_) => const SettingsScreen(),
        AppRoutes.detail: (_) => const DetailScreen(),
      },
    );
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Poster-heavy screens (Home rails, detail) reuse far more images than
  // Flutter's default 1000-entry cache holds; raise the limits app-wide so a
  // long catalog scroll stays at cache-hit speed (Home perf spike #8).
  PaintingBinding.instance.imageCache
    ..maximumSize = 20000
    ..maximumSizeBytes = 100 << 20;

  runApp(
    ProviderScope(
      overrides: [
        // Real disk-backed persistence + subnet probing for the app; tests
        // override these with fakes.
        hostRegistryStoreProvider.overrideWithValue(SharedPrefsHostRegistryStore()),
        subnetScannerProvider.overrideWithValue(TcpProbeScanner()),
      ],
      child: const HarborCompanionApp(),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/background/background_controller.dart';
import 'app/background/foreground_task_background_platform.dart';
import 'app/background/media_surface_channel.dart';
import 'app/connect/connect_controller.dart';
import 'app/connect/host_registry.dart';
import 'app/connect/lan_scan.dart';
import 'app/home/detail_screen.dart';
import 'app/home/home_cache_disk_store.dart';
import 'app/home/home_controller.dart';
import 'app/home/home_rows_screen.dart';
import 'app/home/rail_grid_screen.dart';
import 'app/routes.dart';
import 'app/shell/shell_screen.dart';
import 'app/settings/settings_controller.dart';
import 'app/settings/settings_screen.dart';
import 'app/settings/settings_store.dart';
import 'app/theme.dart';
import 'app/update/update_controller.dart';

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
    // Instantiate the background controller so it folds connect/settings
    // changes into the foreground service for the whole app lifetime.
    ref.read(backgroundControllerProvider.notifier);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground/background transitions are recorded for self-update but never
    // trigger a re-check — the launch check fires once, and a foreground
    // return is a no-op (ticket 28). The reconnect schedule no longer reacts to
    // lifecycle at all (ADR-0006). The background module needs the transition:
    // Android only allows a foreground service to start while foregrounded.
    final foregrounded = state == AppLifecycleState.resumed;
    ref
        .read(selfUpdateControllerProvider.notifier)
        .setForegrounded(state != AppLifecycleState.resumed);
    ref
        .read(backgroundControllerProvider.notifier)
        .setForegrounded(foregrounded);
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
        AppRoutes.homeRows: (_) => const HomeRowsScreen(),
        AppRoutes.detail: (_) => const DetailScreen(),
        AppRoutes.railGrid: (_) => const RailGridScreen(),
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

  // Register the flutter_foreground_task plugin (communication port + options)
  // before the app runs; the real BackgroundPlatform adapter is wired below.
  initializeForegroundTask();

  runApp(
    ProviderScope(
      overrides: [
        // Real host registry + subnet probing for the app; tests
        // override these with fakes.
        hostRegistryStoreProvider.overrideWithValue(SharedPrefsHostRegistryStore()),
        subnetScannerProvider.overrideWithValue(TcpProbeScanner()),
        settingsStoreProvider.overrideWithValue(SharedPrefsSettingsStore()),
        // Persistent-connection foreground service (#64). The no-op default
        // keeps unit tests off the platform. The native MediaSession surface
        // (#66) publishes the media notification; absent it the adapter falls
        // back to the plugin's own notification buttons.
        backgroundPlatformProvider.overrideWithValue(
          FlutterForegroundTaskBackgroundPlatform(
            mediaSurface: MethodChannelMediaSurface(),
          ),
        ),
        // Per-rail disk cache (ADR-0004). Resolves <app-support>/home_cache on
        // first use; the in-memory store stays the provider default for tests.
        homeCacheStoreProvider.overrideWithValue(HomeCacheDiskStore()),
      ],
      child: const HarborCompanionApp(),
    ),
  );
}

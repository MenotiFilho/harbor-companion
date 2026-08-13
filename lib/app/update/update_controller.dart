// Riverpod controller for the self-update check + install halves (tickets 28,
// 30).
//
// Thin glue between the pure reducer (update_reducer.dart) and the outside
// world: the GitHub releases client (HTTP), the version provider
// (`package_info_plus` build number), the ota_update installer, and the
// install-permission adapter. It drains the reducer's effects into those
// side-channels and folds the results back in as events — never a decision of
// its own. Returning to the foreground is [SetForegrounded] and never re-checks
// (no double-fire), except to re-check a parked install-permission grant.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'github_releases_client.dart';
import 'install_permission.dart';
import 'update_installer.dart';
import 'update_reducer.dart';
import 'version_provider.dart';

/// Version provider seam. Defaults to package_info_plus; tests override.
final selfUpdateVersionProvider =
    Provider<VersionProvider>((ref) => PackageInfoVersionProvider());

/// GitHub releases client seam. Defaults to the real dart:io HTTP client;
/// tests override with a fake.
final releasesClientProvider =
    Provider<ReleasesClient>((ref) => HttpReleasesClient());

/// ota_update download/verify/install seam. Defaults to the real adapter;
/// tests override with a fake.
final updateInstallerProvider =
    Provider<UpdateInstaller>((ref) => OtaUpdateInstaller());

/// Install-permission seam. Defaults to the MethodChannel backed by
/// MainActivity.kt; tests override with a fake.
final installPermissionProvider =
    Provider<InstallPermissionAdapter>((ref) => MethodChannelInstallPermission());

class SelfUpdateController extends Notifier<SelfUpdateState> {
  bool _launched = false;

  @override
  SelfUpdateState build() {
    _init();
    return SelfUpdateState();
  }

  /// Loads the local version, then fires the one launch check. Mirrors the
  /// connect controller's `_restore()` → `Launch` ordering so the local
  /// versionCode is always present before a [RemoteResult] can be compared.
  Future<void> _init() async {
    final version = await ref.read(selfUpdateVersionProvider).load();
    if (!ref.mounted) return;
    _dispatch(LocalVersionLoaded(version.code, version.name));
    if (!_launched) {
      _launched = true;
      _dispatch(const Launch());
    }
  }

  // -- UI entry points -------------------------------------------------------

  /// Manual "Check for updates" from Settings; reuses the same check path.
  void checkNow() => _dispatch(const CheckRequested());

  /// The user tapped Update in the prompt. Begins the install half.
  void acceptUpdate() => _dispatch(const UpdateRequested());

  void setForegrounded(bool value) {
    _dispatch(SetForegrounded(value));
    // Returning to the foreground while an install is parked on the
    // "Install unknown apps" grant re-checks it, so a granted user resumes
    // straight into the download without a second tap.
    if (!value && state.awaitingInstallPermission) {
      _checkInstallPermission(state.installSeq);
    }
  }

  void dismissPrompt() => _dispatch(const DismissPrompt());

  // -- The one place state mutates -------------------------------------------

  void _dispatch(SelfUpdateEvent event) {
    state = updateReduce(state, event);
    _drain(state);
  }

  /// Maps the effects buffer onto the side-channels.
  void _drain(SelfUpdateState next) {
    if (next.effects.isEmpty) return;
    final effects = List<String>.from(next.effects);
    next.effects.clear();
    for (final effect in effects) {
      if (effect.startsWith('check:')) {
        final seq = int.parse(effect.substring('check:'.length));
        _runCheck(seq);
      } else if (effect == 'prompt') {
        // No side-channel: the UI reads `promptVisible` and shows the dialog.
      } else if (effect.startsWith('install:')) {
        final seq = int.parse(effect.substring('install:'.length));
        _checkInstallPermission(seq);
      } else if (effect == 'installApk') {
        _runInstall();
      } else if (effect == 'grantInstallPermission') {
        ref.read(installPermissionProvider).openInstallPermissionSettings();
      } else if (effect.startsWith('fail:')) {
        // Quiet: a network failure is logged, never surfaced as a modal.
        debugPrint('self-update check failed: ${effect.substring('fail:'.length)}');
      }
    }
  }

  Future<void> _runCheck(int seq) async {
    try {
      final info = await ref.read(releasesClientProvider).fetchLatestRelease();
      if (!ref.mounted) return;
      if (info == null) {
        _dispatch(NoRelease(seq));
      } else {
        _dispatch(RemoteResult(seq, info));
      }
    } catch (e) {
      if (!ref.mounted) return;
      _dispatch(CheckFailed(seq, '$e'));
    }
  }

  Future<void> _checkInstallPermission(int seq) async {
    final granted =
        await ref.read(installPermissionProvider).canRequestPackageInstalls();
    if (!ref.mounted) return;
    _dispatch(InstallPermission(seq, granted));
  }

  Future<void> _runInstall() async {
    // The reducer only emits `installApk` once an installable update is
    // present (downloadUrl + sha256 non-null), so these are safe to read.
    final update = state.update!;
    final stream = ref
        .read(updateInstallerProvider)
        .install(url: update.downloadUrl!, sha256: update.sha256!);
    stream.listen((status) {
      if (!ref.mounted) return;
      switch (status) {
        case InstallStatus.downloading:
          break; // progress, not a transition
        case InstallStatus.triggered:
        case InstallStatus.done:
          _dispatch(const InstallTriggered());
        case InstallStatus.checksumMismatch:
          _dispatch(const ChecksumMismatch());
        case InstallStatus.canceled:
          _dispatch(const InstallFailed('Update canceled'));
        case InstallStatus.failed:
          _dispatch(const InstallFailed('Update download failed'));
      }
    });
  }
}

final selfUpdateControllerProvider =
    NotifierProvider<SelfUpdateController, SelfUpdateState>(
  SelfUpdateController.new,
);

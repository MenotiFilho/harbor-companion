// Thin ota_update adapter for the self-update install half (ticket 30).
//
// The reducer owns every transition; this adapter carries none. Its only job is
// to translate the `installApk` effect into `OtaUpdate().execute(url,
// sha256checksum:)` and surface the plugin's `OtaStatus` stream as a neutral
// [InstallStatus] the controller folds back into reducer events. ota_update
// downloads to internal storage, verifies the SHA-256 (a mismatch reports
// CHECKSUM_ERROR and never installs), and triggers the system install dialog.
// On a checksum mismatch this adapter also deletes the bad APK ota_update left
// behind, so a corrupt file is never re-offered.

import 'dart:io';

import 'package:ota_update/ota_update.dart';
import 'package:path_provider/path_provider.dart';

enum InstallStatus {
  /// The APK is downloading (progress; not a state transition).
  downloading,

  /// The system install dialog has been triggered (the user's one tap).
  triggered,

  /// PackageInstaller reported a finished install (not used on the default
  /// intent path, which is handled by [triggered]).
  done,

  /// The downloaded file's SHA-256 did not match the release digest.
  checksumMismatch,

  /// The download/install failed (network, internal, or permission error).
  failed,

  /// The download was canceled.
  canceled,
}

abstract interface class UpdateInstaller {
  Stream<InstallStatus> install({required String url, required String sha256});
}

class OtaUpdateInstaller implements UpdateInstaller {
  static const _filename = 'harbor-companion.apk';

  @override
  Stream<InstallStatus> install({
    required String url,
    required String sha256,
  }) async* {
    final stream = OtaUpdate()
        .execute(url, destinationFilename: _filename, sha256checksum: sha256);
    await for (final event in stream) {
      if (event.status == OtaStatus.CHECKSUM_ERROR) {
        await _deletePartial();
      }
      yield _map(event.status);
    }
  }

  InstallStatus _map(OtaStatus status) => switch (status) {
        OtaStatus.DOWNLOADING => InstallStatus.downloading,
        OtaStatus.INSTALLING => InstallStatus.triggered,
        OtaStatus.INSTALLATION_DONE => InstallStatus.done,
        OtaStatus.CHECKSUM_ERROR => InstallStatus.checksumMismatch,
        OtaStatus.CANCELED => InstallStatus.canceled,
        OtaStatus.DOWNLOAD_ERROR ||
        OtaStatus.INSTALLATION_ERROR ||
        OtaStatus.PERMISSION_NOT_GRANTED_ERROR ||
        OtaStatus.ALREADY_RUNNING_ERROR ||
        OtaStatus.INTERNAL_ERROR =>
          InstallStatus.failed,
      };

  /// Removes the APK ota_update left in its internal storage dir after a
  /// checksum mismatch, so a corrupt download can't be re-installed.
  Future<void> _deletePartial() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/ota_update');
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.apk')) {
          await entity.delete();
        }
      }
    }
  }
}

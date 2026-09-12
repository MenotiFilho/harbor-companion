package dev.harbor.harbor_companion

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var mediaSurface: MediaSurfaceController? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Install-permission seam for the self-update install half: expose
        // canRequestPackageInstalls() and the package-scoped "Install unknown
        // apps" screen to Dart, so the reducer can gate the install on it.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestPackageInstalls" -> result.success(canRequestInstallPackages())
                    "openInstallPermissionSettings" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Notification-permission seam for #67 (ADR-0007): expose the
        // shouldShowRequestPermissionRationale-style permanent-denial state and
        // the app's notification-settings deep link that the plugin does not.
        // The OS prompt itself fires through flutter_foreground_task.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATION_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkStatus" -> result.success(notificationPermissionStatus())
                    "markRequested" -> {
                        markNotificationPermissionRequested()
                        result.success(null)
                    }
                    "openNotificationSettings" -> {
                        openNotificationSettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Native MediaSession/MediaStyle surface for the persistent-connection
        // notification (ticket #66). A cold start from the notification body
        // carries EXTRA_OPEN_REMOTE; hand it to Dart once its handler is ready.
        val controller = MediaSurfaceController(applicationContext)
        val mediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
        controller.attach(mediaChannel)
        mediaChannel.setMethodCallHandler { call, result -> controller.onMethodCall(call, result) }
        if (intent?.getBooleanExtra(MediaSurfaceController.EXTRA_OPEN_REMOTE, false) == true) {
            controller.markPendingOpened()
            intent.removeExtra(MediaSurfaceController.EXTRA_OPEN_REMOTE)
        }
        mediaSurface = controller
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Warm start: the engine is up, so signal the tap straight through.
        if (intent.getBooleanExtra(MediaSurfaceController.EXTRA_OPEN_REMOTE, false)) {
            intent.removeExtra(MediaSurfaceController.EXTRA_OPEN_REMOTE)
            mediaSurface?.signalOpened()
        }
    }

    private fun canRequestInstallPackages(): Boolean {
        // The per-app "Install unknown apps" gate exists on Android 8+; below
        // that, sideload installs are enabled globally, so nothing to request.
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    // -- notification permission (#67, ADR-0007) -----------------------------

    /**
     * `granted`, `denied` (re-askable) or `permanently_denied`. Below Android 13
     * the permission does not exist, so it is always granted. A never-asked app
     * reports `denied`, not permanent: only a real refusal with no rationale
     * left is permanent.
     */
    private fun notificationPermissionStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return "granted"
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            return "granted"
        }
        val asked = getSharedPreferences(NOTIFICATION_PREFS, MODE_PRIVATE)
            .getBoolean(NOTIFICATION_ASKED_KEY, false)
        if (!asked) return "denied"
        return if (shouldShowRequestPermissionRationale(permission)) {
            "denied"
        } else {
            "permanently_denied"
        }
    }

    private fun markNotificationPermissionRequested() {
        getSharedPreferences(NOTIFICATION_PREFS, MODE_PRIVATE)
            .edit()
            .putBoolean(NOTIFICATION_ASKED_KEY, true)
            .apply()
    }

    private fun openNotificationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            )
        }
        startActivity(intent)
    }

    companion object {
        private const val CHANNEL = "dev.harbor.harbor_companion/install_permission"
        private const val MEDIA_CHANNEL = "dev.harbor.harbor_companion/media_surface"
        private const val NOTIFICATION_CHANNEL =
            "dev.harbor.harbor_companion/notification_permission"
        private const val NOTIFICATION_PREFS = "harbor_companion.notification"
        private const val NOTIFICATION_ASKED_KEY = "post_notifications_asked"
    }
}

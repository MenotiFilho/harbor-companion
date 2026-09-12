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

    /** A local-network permission prompt awaiting its OS result (#69). */
    private var pendingLocalNetworkResult: MethodChannel.Result? = null

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

        // Generic battery-settings deep link for the OEM tips block (#68). The
        // exemption check, the direct request and the optimization list come
        // from flutter_foreground_task; only this generic screen is not exposed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BATTERY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openBatterySettings" -> {
                        openBatterySettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Android 17 (API 37) local network protection (#69): a LAN client
        // must hold the runtime ACCESS_LOCAL_NETWORK permission once it targets
        // 37. Below 37 the permission does not exist, so this reports "granted"
        // and the request is a no-op; the connection is never gated there.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCAL_NETWORK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkStatus" -> result.success(localNetworkPermissionStatus())
                    "request" -> requestLocalNetworkPermission(result)
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

    // -- local network permission (#69) --------------------------------------

    /**
     * Completes a pending `ACCESS_LOCAL_NETWORK` request. The channel's `request`
     * call suspends until the OS prompt resolves here. Below Android 17 the
     * request path never starts a prompt, so this only ever fires on 17+.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != LOCAL_NETWORK_REQUEST_CODE) return
        pendingLocalNetworkResult?.success(localNetworkPermissionStatus())
        pendingLocalNetworkResult = null
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

    // -- local network permission (#69, Android 17 / API 37) -----------------

    /**
     * `granted`, `denied` (re-askable) or `permanently_denied` for
     * `ACCESS_LOCAL_NETWORK`. Below Android 17 the permission does not exist and
     * LAN sockets are ungated, so it is always granted — the connection path
     * must never gate on it there.
     */
    private fun localNetworkPermissionStatus(): String {
        if (Build.VERSION.SDK_INT < LOCAL_NETWORK_API) return "granted"
        val permission = LOCAL_NETWORK_PERMISSION
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            return "granted"
        }
        val asked = getSharedPreferences(LOCAL_NETWORK_PREFS, MODE_PRIVATE)
            .getBoolean(LOCAL_NETWORK_ASKED_KEY, false)
        if (!asked) return "denied"
        return if (shouldShowRequestPermissionRationale(permission)) {
            "denied"
        } else {
            "permanently_denied"
        }
    }

    /**
     * Fires the `ACCESS_LOCAL_NETWORK` prompt on Android 17+, completing
     * [result] from [onRequestPermissionsResult]. A no-op success on older
     * versions, which do not gate LAN access.
     */
    private fun requestLocalNetworkPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < LOCAL_NETWORK_API) {
            result.success("granted")
            return
        }
        if (checkSelfPermission(LOCAL_NETWORK_PERMISSION) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success("granted")
            return
        }
        // One prompt at a time; a second caller resolves immediately rather
        // than stacking another OS dialog.
        if (pendingLocalNetworkResult != null) {
            result.success(localNetworkPermissionStatus())
            return
        }
        getSharedPreferences(LOCAL_NETWORK_PREFS, MODE_PRIVATE)
            .edit()
            .putBoolean(LOCAL_NETWORK_ASKED_KEY, true)
            .apply()
        pendingLocalNetworkResult = result
        requestPermissions(
            arrayOf(LOCAL_NETWORK_PERMISSION),
            LOCAL_NETWORK_REQUEST_CODE
        )
    }

    // -- generic battery settings (#68, ADR-0007) ----------------------------

    /**
     * Opens the system battery-settings screen. Not every OEM ships the battery
     * saver screen, so fall back to the top-level settings app rather than
     * throw.
     */
    private fun openBatterySettings() {
        val intent = Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
        val target = if (intent.resolveActivity(packageManager) != null) {
            intent
        } else {
            Intent(Settings.ACTION_SETTINGS)
        }
        startActivity(target)
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
        private const val BATTERY_CHANNEL = "dev.harbor.harbor_companion/battery"
        private const val LOCAL_NETWORK_CHANNEL =
            "dev.harbor.harbor_companion/local_network"
        private const val NOTIFICATION_PREFS = "harbor_companion.notification"
        private const val NOTIFICATION_ASKED_KEY = "post_notifications_asked"

        /** Android 17 (API 37) introduced the local network runtime gate. */
        private const val LOCAL_NETWORK_API = 37

        // Referenced as a literal because the project compiles against API 36;
        // the OS resolves it by name at runtime.
        private const val LOCAL_NETWORK_PERMISSION =
            "android.permission.ACCESS_LOCAL_NETWORK"
        private const val LOCAL_NETWORK_REQUEST_CODE = 4712
        private const val LOCAL_NETWORK_PREFS = "harbor_companion.local_network"
        private const val LOCAL_NETWORK_ASKED_KEY = "access_local_network_asked"
    }
}

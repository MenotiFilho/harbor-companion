package dev.harbor.harbor_companion

import android.content.Intent
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

    companion object {
        private const val CHANNEL = "dev.harbor.harbor_companion/install_permission"
        private const val MEDIA_CHANNEL = "dev.harbor.harbor_companion/media_surface"
    }
}

package dev.harbor.harbor_companion

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
    }
}

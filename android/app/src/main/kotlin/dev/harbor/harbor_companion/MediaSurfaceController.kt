package dev.harbor.harbor_companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * The app-owned native media surface for the persistent-connection
 * foreground service (ticket #66, ADR-0005).
 *
 * `flutter_foreground_task` 11.0.3 cannot render a `MediaStyle` notification
 * or a network bitmap, so this controller publishes a platform `MediaSession` +
 * `Notification.MediaStyle` notification under the SAME id as the plugin's
 * foreground service (4711), replacing the plugin's plain notification while
 * media is held. The service stays foreground; the notification morphs back to
 * the plugin's idle status when [clear] is called.
 *
 * No AndroidX dependency: platform `MediaSession`/`Notification.MediaStyle`
 * (API 21+) provide the artwork, the seek scrubber and the headset/Bluetooth
 * transport buttons. Everything is host-authoritative: the Dart side pushes the
 * last snapshot's state with `show`/`anchor`; a callback only reports a tapped
 * action back (`invokeMethod("action", ...)`), never flips state here.
 */
class MediaSurfaceController(private val context: Context) {
    private var channel: MethodChannel? = null
    private var session: MediaSession? = null
    private var pendingOpened = false
    private var receiverRegistered = false

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val posters = LruCache<String, Bitmap>(4)

    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val action = intent?.getStringExtra(EXTRA_ACTION) ?: return
            emit(action, intent.getDoubleExtra(EXTRA_POSITION, 0.0))
        }
    }

    fun attach(channel: MethodChannel) {
        this.channel = channel
        ensureChannel()
        ensureSession()
        registerActionReceiver()
    }

    fun markPendingOpened() {
        pendingOpened = true
    }

    fun signalOpened() = emit("opened")

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        when (call.method) {
            // Dart signals its handler is registered; flush a cold-start tap.
            "ready" -> {
                result.success(null)
                if (pendingOpened) {
                    pendingOpened = false
                    emit("opened")
                }
            }
            "show" -> {
                render(args, full = true)
                result.success(null)
            }
            "anchor" -> {
                render(args, full = false)
                result.success(null)
            }
            "clear" -> {
                clear()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // -- the media session ---------------------------------------------------

    private fun ensureSession() {
        if (session != null) return
        val s = MediaSession(context, "HarborCompanion")
        s.setFlags(
            MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
        )
        s.setCallback(object : MediaSession.Callback() {
            // The system tracks the PlaybackState we publish, so it sends the
            // opposite transport callback; both map to the app's toggle.
            override fun onPlay() = emit("togglePlay")
            override fun onPause() = emit("togglePlay")
            override fun onStop() = emit("togglePlay")
            override fun onSkipToNext() = emit("next")
            override fun onSkipToPrevious() = emit("previous")
            override fun onSeekTo(pos: Long) = emit("seek", pos / 1000.0)
        })
        session = s
    }

    private fun registerActionReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(ACTION_BROADCAST)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(actionReceiver, filter)
        }
        receiverRegistered = true
    }

    // -- rendering the surface -----------------------------------------------

    private fun render(args: Map<*, *>, full: Boolean) {
        ensureSession()
        if (args["idle"] as? Boolean == true) {
            clear()
            return
        }
        val title = args["title"] as? String ?: return
        val playing = args["playing"] as? Boolean ?: false
        val text = (args["text"] as? String)
            ?: (args["episodeLine"] as? String)
            ?: (if (playing) "Playing" else "Paused")
        val positionMs = secondsToMs(args["positionSec"])
        val durationMs = secondsToMs(args["durationSec"])
        val hasPrev = args["hasPrev"] as? Boolean ?: false
        val hasNext = args["hasNext"] as? Boolean ?: false
        val posterUrl = args["posterUrl"] as? String

        val cached = posterUrl?.let { posters.get(it) }
        post(title, text, cached, playing, positionMs, durationMs, hasPrev, hasNext)

        if (full && posterUrl != null && cached == null) {
            io.execute {
                val bitmap = download(posterUrl)
                if (bitmap != null) {
                    posters.put(posterUrl, bitmap)
                    main.post {
                        post(
                            title, text, bitmap, playing,
                            positionMs, durationMs, hasPrev, hasNext
                        )
                    }
                }
            }
        }
    }

    private fun post(
        title: String,
        text: String,
        bitmap: Bitmap?,
        playing: Boolean,
        positionMs: Long,
        durationMs: Long,
        hasPrev: Boolean,
        hasNext: Boolean,
    ) {
        val s = session ?: return
        s.isActive = true
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_SEEK_TO or
                        (if (hasPrev) PlaybackState.ACTION_SKIP_TO_PREVIOUS else 0L) or
                        (if (hasNext) PlaybackState.ACTION_SKIP_TO_NEXT else 0L)
                )
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    positionMs,
                    if (playing) 1f else 0f
                )
                .build()
        )
        s.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, text)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
                .apply {
                    if (bitmap != null) {
                        putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, bitmap)
                    }
                }
                .build()
        )

        // Distinct transport icons: previously every action reused the app's
        // play-mark small icon, so prev/next/toggle all looked like "play" and
        // the toggle never morphed. The toggle icon must follow `playing`; the
        // action id stays fixed (the host remains the source of truth).
        val actions = mutableListOf<Notification.Action>()
        if (hasPrev) {
            actions.add(action(R.drawable.ic_media_previous, "Previous", "previous"))
        }
        actions.add(
            action(
                if (playing) R.drawable.ic_media_pause else R.drawable.ic_media_play,
                if (playing) "Pause" else "Play",
                "togglePlay"
            )
        )
        if (hasNext) {
            actions.add(action(R.drawable.ic_media_next, "Next", "next"))
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_harbor)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(contentIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(s.sessionToken)
                    .setShowActionsInCompactView(*actions.indices.toList().toIntArray())
            )
        if (bitmap != null) builder.setLargeIcon(bitmap)
        for (a in actions) builder.addAction(a)

        notificationManager().notify(NOTIFICATION_ID, builder.build())
    }

    /**
     * Drop the media surface the instant the socket drops (ADR-0005): deactivate
     * the session so the lock-screen/Bluetooth controls vanish, and let the
     * plugin repost its idle notification on the next update.
     */
    private fun clear() {
        session?.let {
            it.setPlaybackState(null)
            it.isActive = false
        }
    }

    private fun contentIntent(): PendingIntent =
        PendingIntent.getActivity(
            context,
            REQUEST_OPEN,
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra(EXTRA_OPEN_REMOTE, true)
            },
            pendingFlags()
        )

    private fun action(icon: Int, title: String, id: String): Notification.Action {
        val intent = Intent(ACTION_BROADCAST)
            .setPackage(context.packageName)
            .putExtra(EXTRA_ACTION, id)
        val pending = PendingIntent.getBroadcast(
            context,
            id.hashCode(),
            intent,
            pendingFlags()
        )
        @Suppress("DEPRECATION")
        return Notification.Action.Builder(icon, title, pending).build()
    }

    private fun pendingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

    private fun notificationManager(): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = notificationManager()
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            // Same channel the plugin uses, so the single notification never
            // changes look when it morphs.
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Persistent connection",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
    }

    private fun emit(action: String, positionSec: Double = 0.0) {
        val args = HashMap<String, Any?>()
        args["action"] = action
        if (action == "seek") args["positionSec"] = positionSec
        main.post { channel?.invokeMethod("action", args) }
    }

    private fun download(url: String): Bitmap? {
        return try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.instanceFollowRedirects = true
            connection.doInput = true
            connection.inputStream.use { BitmapFactory.decodeStream(it) }
        } catch (_: Exception) {
            null
        }
    }

    private fun secondsToMs(value: Any?): Long =
        ((value as? Number)?.toDouble()?.times(1000))?.toLong() ?: 0L

    companion object {
        /** Must match `kBackgroundChannelId` / `kBackgroundServiceId` in Dart. */
        const val CHANNEL_ID = "harbor_companion.connection"
        const val NOTIFICATION_ID = 4711

        const val EXTRA_OPEN_REMOTE = "dev.harbor.harbor_companion.OPEN_REMOTE"
        private const val EXTRA_ACTION = "media_action"
        private const val EXTRA_POSITION = "media_position"
        private const val ACTION_BROADCAST = "dev.harbor.harbor_companion.MEDIA_ACTION"
        private const val REQUEST_OPEN = 1001
    }
}

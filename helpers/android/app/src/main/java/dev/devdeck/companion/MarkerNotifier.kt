package dev.devdeck.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.devdeck.companion.home.MainActivity

/** Posts, updates or cancels the device marker notification from what [MarkerStore] holds. */
object MarkerNotifier {
    private const val TAG = "DevDeckMarker"
    private const val CHANNEL_ID = "device_marker"
    private const val NOTIFICATION_ID = 1

    enum class Outcome { SHOWN, HIDDEN, DISABLED, DISMISSED, BLOCKED }

    fun ensureChannel(context: Context) {
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.channel_marker_name),
            // Not IMPORTANCE_LOW: Android 12+ hides the status bar icons of "silent" (low) notifications
            // by default. DEFAULT keeps the icon; no sound or vibration and no heads-up (that needs HIGH).
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = context.getString(R.string.channel_marker_description)
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    /** Brings the notification in line with the stored state and preferences. */
    fun render(context: Context): Outcome {
        val store = MarkerStore(context)
        val state = store.state
        val manager = NotificationManagerCompat.from(context)
        val outcome = when {
            !store.enabled -> Outcome.DISABLED
            state == null || state.kind == MarkerKind.FREE -> Outcome.HIDDEN
            store.isDismissed -> Outcome.DISMISSED
            !manager.areNotificationsEnabled() -> Outcome.BLOCKED
            else -> Outcome.SHOWN
        }
        if (outcome != Outcome.SHOWN || state == null) {
            manager.cancel(NOTIFICATION_ID)
            return outcome
        }
        ensureChannel(context)
        try {
            manager.notify(NOTIFICATION_ID, build(context, state))
        } catch (e: SecurityException) {
            Log.w(TAG, "POST_NOTIFICATIONS not granted", e)
            return Outcome.BLOCKED
        }
        return outcome
    }

    private fun build(context: Context, state: MarkerState): Notification {
        val details = MarkerText.details(context, state)
        val hint = MarkerText.hint(context, state)
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(MarkerText.icon(state))
            .setColor(ContextCompat.getColor(context, R.color.brand_green))
            .setContentTitle(MarkerText.title(context, state))
            .setContentText(details ?: hint)
            .setStyle(NotificationCompat.BigTextStyle().bigText(listOfNotNull(details, hint).joinToString("\n")))
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setOngoing(false)
            .setAutoCancel(false)
            .setShowWhen(state.since != null)
            .setWhen(state.since?.times(1000) ?: System.currentTimeMillis())
            .setContentIntent(openHome(context))
            .setDeleteIntent(onDismiss(context, state))
            .build()
    }

    private fun openHome(context: Context): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun onDismiss(context: Context, state: MarkerState): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, DismissReceiver::class.java).putExtra(DismissReceiver.EXTRA_HOLD_KEY, state.holdKey),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}

package dev.devdeck.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Remembers that the user swiped the marker away, so updates for the same hold don't bring it back. */
class DismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        MarkerStore(context).dismissedHoldKey = intent.getStringExtra(EXTRA_HOLD_KEY) ?: return
    }

    companion object {
        const val EXTRA_HOLD_KEY = "hold_key"
    }
}

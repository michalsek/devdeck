package dev.devdeck.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Receives the marker state from DevDeck:
 * `adb shell am broadcast -n dev.devdeck.companion/.StateReceiver -f 0x20 --es json '<json>'`
 *
 * The broadcast result (printed by `am broadcast`) reports what happened: code 1 and data
 * shown/hidden/disabled/dismissed/blocked on success, code 0 and data "invalid" otherwise.
 */
class StateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val json = intent.getStringExtra(EXTRA_JSON)
        val state = json?.let(MarkerState::parse)
        if (json == null || state == null) {
            Log.w(TAG, "Ignoring invalid marker state: $json")
            reply(0, "invalid")
            return
        }
        // The state is recorded even while the marker is off, so the home screen stays accurate
        // and turning the marker back on shows the current holder rather than a stale one.
        MarkerStore(context).saveState(json, state)
        val outcome = MarkerNotifier.render(context)
        reply(1, outcome.name.lowercase())
    }

    private fun reply(code: Int, data: String) {
        if (isOrderedBroadcast) setResult(code, data, null)
    }

    companion object {
        const val EXTRA_JSON = "json"
        private const val TAG = "DevDeckMarker"
    }
}

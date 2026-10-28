package dev.devdeck.companion

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit

/** Persists the last state from DevDeck and the on-device preferences. */
class MarkerStore(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences("marker", Context.MODE_PRIVATE)

    /** The last valid state DevDeck sent, or null if it never sent one. */
    val state: MarkerState? get() = prefs.getString(KEY_STATE, null)?.let(MarkerState::parse)

    /** Whether the marker notification is shown on this device (the home screen toggle). */
    var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, true)
        set(value) = prefs.edit {
            putBoolean(KEY_ENABLED, value)
            // Turning it back on means "show me the marker" again.
            if (value) remove(KEY_DISMISSED)
        }

    /** [MarkerState.holdKey] of the hold whose notification the user swiped away. */
    var dismissedHoldKey: String?
        get() = prefs.getString(KEY_DISMISSED, null)
        set(value) = prefs.edit { putString(KEY_DISMISSED, value) }

    val isDismissed: Boolean get() = state?.let { it.holdKey == dismissedHoldKey } ?: false

    fun saveState(json: String, state: MarkerState) = prefs.edit {
        putString(KEY_STATE, json)
        if (state.holdKey != dismissedHoldKey) remove(KEY_DISMISSED)
    }

    fun registerListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.registerOnSharedPreferenceChangeListener(listener)

    fun unregisterListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.unregisterOnSharedPreferenceChangeListener(listener)

    private companion object {
        const val KEY_STATE = "state_json"
        const val KEY_ENABLED = "enabled"
        const val KEY_DISMISSED = "dismissed_hold"
    }
}

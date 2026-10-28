package dev.devdeck.companion.home

import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import com.google.android.material.materialswitch.MaterialSwitch
import dev.devdeck.companion.MarkerNotifier
import dev.devdeck.companion.MarkerStore
import dev.devdeck.companion.R

/** Turns the marker off on this device and links to the app's notification settings. */
class MarkerSettingsSection(private val context: Context) : HomeSection {
    private lateinit var toggle: MaterialSwitch

    override fun createView(inflater: LayoutInflater, parent: ViewGroup): View =
        inflater.inflate(R.layout.section_marker, parent, false).also {
            toggle = it.findViewById(R.id.marker_toggle)
            toggle.setOnCheckedChangeListener { _, checked ->
                val store = MarkerStore(context)
                if (store.enabled != checked) {
                    store.enabled = checked
                    MarkerNotifier.render(context)
                }
            }
            it.findViewById<Button>(R.id.marker_notification_settings).setOnClickListener {
                context.startActivity(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                )
            }
        }

    override fun refresh() {
        toggle.isChecked = MarkerStore(context).enabled
    }
}

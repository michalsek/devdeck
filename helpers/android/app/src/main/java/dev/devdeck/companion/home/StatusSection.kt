package dev.devdeck.companion.home

import android.content.Context
import android.content.res.ColorStateList
import android.text.format.DateFormat
import android.text.format.DateUtils
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.core.app.NotificationManagerCompat
import androidx.core.view.isVisible
import com.google.android.material.color.MaterialColors
import dev.devdeck.companion.MarkerKind
import dev.devdeck.companion.MarkerStore
import dev.devdeck.companion.MarkerText
import dev.devdeck.companion.R
import java.util.Date

/** Shows who is using the device right now, as last reported by DevDeck. */
class StatusSection(private val context: Context) : HomeSection {
    private lateinit var icon: ImageView
    private lateinit var title: TextView
    private lateinit var details: TextView
    private lateinit var since: TextView
    private lateinit var hint: TextView
    private lateinit var note: TextView

    override fun createView(inflater: LayoutInflater, parent: ViewGroup): View =
        inflater.inflate(R.layout.section_status, parent, false).also {
            icon = it.findViewById(R.id.status_icon)
            title = it.findViewById(R.id.status_title)
            details = it.findViewById(R.id.status_details)
            since = it.findViewById(R.id.status_since)
            hint = it.findViewById(R.id.status_hint)
            note = it.findViewById(R.id.status_note)
        }

    override fun refresh() {
        val store = MarkerStore(context)
        val state = store.state
        val active = state != null && state.kind != MarkerKind.FREE

        icon.setImageResource(MarkerText.icon(state))
        icon.imageTintList = ColorStateList.valueOf(
            MaterialColors.getColor(
                icon,
                if (active) androidx.appcompat.R.attr.colorPrimary else com.google.android.material.R.attr.colorOutline,
            )
        )
        title.text = MarkerText.title(context, state)
        details.text = MarkerText.details(context, state)
        details.isVisible = details.text.isNotEmpty()
        since.text = state?.since?.takeIf { active }?.let(::formatSince)
        since.isVisible = since.text.isNotEmpty()
        hint.text = MarkerText.hint(context, state)

        note.text = when {
            !active -> null
            !store.enabled -> context.getString(R.string.status_note_disabled)
            !NotificationManagerCompat.from(context).areNotificationsEnabled() ->
                context.getString(R.string.status_note_blocked)
            store.isDismissed -> context.getString(R.string.status_note_dismissed)
            else -> null
        }
        note.isVisible = note.text.isNotEmpty()
    }

    private fun formatSince(seconds: Long): String {
        val millis = seconds * 1000
        return context.getString(
            R.string.status_since,
            DateFormat.getTimeFormat(context).format(Date(millis)),
            DateUtils.getRelativeTimeSpanString(millis, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS),
        )
    }
}

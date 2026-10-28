package dev.devdeck.companion

import android.content.Context
import androidx.annotation.DrawableRes

/** User-facing texts and icons for a [MarkerState], shared by the notification and the home screen. */
object MarkerText {
    fun title(context: Context, state: MarkerState?): String = when (state?.kind) {
        MarkerKind.AGENT -> context.getString(
            R.string.marker_agent_title,
            state.holder ?: context.getString(R.string.marker_agent_default_holder),
        )
        MarkerKind.USER ->
            if (state.holder == null || state.holder.equals("you", ignoreCase = true)) {
                context.getString(R.string.marker_user_title_you)
            } else {
                context.getString(R.string.marker_user_title, state.holder)
            }
        MarkerKind.FREE -> context.getString(R.string.marker_free_title)
        null -> context.getString(R.string.marker_unknown_title)
    }

    /** "project · via host · last: action", or null when DevDeck sent none of them. */
    fun details(context: Context, state: MarkerState?): String? {
        if (state == null || state.kind == MarkerKind.FREE) return null
        return listOfNotNull(
            state.project,
            state.host?.let { context.getString(R.string.marker_detail_host, it) },
            state.action?.let { context.getString(R.string.marker_detail_action, it) },
        ).joinToString(" · ").ifEmpty { null }
    }

    fun hint(context: Context, state: MarkerState?): String = context.getString(
        when (state?.kind) {
            MarkerKind.AGENT -> R.string.marker_agent_hint
            MarkerKind.USER -> R.string.marker_user_hint
            MarkerKind.FREE -> R.string.marker_free_hint
            null -> R.string.marker_unknown_hint
        }
    )

    @DrawableRes
    fun icon(state: MarkerState?): Int = when (state?.kind) {
        MarkerKind.AGENT -> R.drawable.ic_stat_agent
        MarkerKind.USER -> R.drawable.ic_stat_user
        MarkerKind.FREE, null -> R.drawable.ic_devdeck_glyph
    }
}

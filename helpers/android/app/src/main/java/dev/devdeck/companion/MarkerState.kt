package dev.devdeck.companion

import org.json.JSONException
import org.json.JSONObject

/** Who is using the device, as sent by DevDeck (see helpers/README.md, "Marker state"). */
enum class MarkerKind(val wire: String) {
    AGENT("agent"),
    USER("user"),
    FREE("free");

    companion object {
        fun fromWire(value: String?): MarkerKind? = entries.firstOrNull { it.wire == value }
    }
}

data class MarkerState(
    val kind: MarkerKind,
    val holder: String?,
    val host: String?,
    val project: String?,
    val action: String?,
    /** Unix seconds when the current hold started. */
    val since: Long?,
) {
    /** Identifies one hold; a dismissed marker stays hidden until this changes. */
    val holdKey: String get() = "${kind.wire}|${holder.orEmpty()}|${since ?: ""}"

    companion object {
        /** Parses DevDeck's state JSON; returns null when it is malformed or `state` is unknown. */
        fun parse(json: String): MarkerState? = try {
            val obj = JSONObject(json)
            MarkerKind.fromWire(obj.optText("state"))?.let { kind ->
                MarkerState(
                    kind = kind,
                    holder = obj.optText("holder"),
                    host = obj.optText("host"),
                    project = obj.optText("project"),
                    action = obj.optText("action"),
                    since = obj.optSeconds("since"),
                )
            }
        } catch (_: JSONException) {
            null
        }

        private fun JSONObject.optText(name: String): String? =
            if (isNull(name)) null else optString(name).trim().ifEmpty { null }

        private fun JSONObject.optSeconds(name: String): Long? =
            if (isNull(name)) null else optLong(name, 0L).takeIf { it > 0 }
    }
}

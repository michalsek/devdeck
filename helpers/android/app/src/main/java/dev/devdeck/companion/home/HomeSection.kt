package dev.devdeck.companion.home

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup

/**
 * One card on the home screen. To add a section (e.g. device controls), implement this and add
 * it to [MainActivity.createSections]; [refresh] runs whenever the marker state or settings change.
 */
interface HomeSection {
    fun createView(inflater: LayoutInflater, parent: ViewGroup): View

    fun refresh() {}
}

package dev.devdeck.companion.home

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import dev.devdeck.companion.R

/** Explains what DevDeck is and why this app is on the device. */
class AboutSection : HomeSection {
    override fun createView(inflater: LayoutInflater, parent: ViewGroup): View =
        inflater.inflate(R.layout.section_about, parent, false)
}

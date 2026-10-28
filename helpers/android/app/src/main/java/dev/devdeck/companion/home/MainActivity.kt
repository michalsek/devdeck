package dev.devdeck.companion.home

import android.Manifest
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.ViewGroup
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import dev.devdeck.companion.MarkerNotifier
import dev.devdeck.companion.MarkerStore
import dev.devdeck.companion.R

/** Home screen: explains DevDeck, shows the current marker state and the on-device settings. */
class MainActivity : AppCompatActivity() {
    private lateinit var store: MarkerStore
    private lateinit var sections: List<HomeSection>

    private val prefsListener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> refresh() }

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            MarkerNotifier.render(this)
            refresh()
        }

    private fun createSections(): List<HomeSection> = listOf(
        StatusSection(this),
        MarkerSettingsSection(this),
        AboutSection(),
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContentView(R.layout.activity_main)
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.scroll)) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.updatePadding(left = bars.left, top = bars.top, right = bars.right, bottom = bars.bottom)
            insets
        }

        store = MarkerStore(this)
        MarkerNotifier.ensureChannel(this)
        val container = findViewById<ViewGroup>(R.id.sections)
        sections = createSections()
        sections.forEach { container.addView(it.createView(layoutInflater, container)) }

        if (savedInstanceState == null) requestNotificationPermissionIfNeeded()
    }

    override fun onStart() {
        super.onStart()
        store.registerListener(prefsListener)
        // Notification settings may have changed while we were away (e.g. via the settings shortcut).
        MarkerNotifier.render(this)
        refresh()
    }

    override fun onStop() {
        store.unregisterListener(prefsListener)
        super.onStop()
    }

    private fun refresh() = sections.forEach(HomeSection::refresh)

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED) {
            notificationPermission.launch(permission)
        }
    }
}

package org.gridzero.gridzero

import android.content.Context
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSuggestion
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupAudioChannel(flutterEngine)
        setupLinkChannel(flutterEngine)
    }

    private fun setupAudioChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "gridzero/audio",
        ).setMethodCallHandler { call, result ->
            if (call.method == "forceSpeakerphone") {
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                // Route playback to the built-in speaker even when a headset
                // is connected, so response alerts stay audible in the field.
                am.isSpeakerphoneOn = true
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    /// Joins HQ's hosted link from an in-app QR scan. Android 10+ blocks
    /// silent wifi connects for normal apps, but network SUGGESTIONS are
    /// allowed: the system shows one approval dialog, after which it
    /// connects automatically whenever that network is in range.
    private fun setupLinkChannel(flutterEngine: FlutterEngine) {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE)
            as WifiManager
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "gridzero/link",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "suggest" -> {
                    val ssid = call.argument<String>("ssid")
                    val pass = call.argument<String>("pass")
                    if (ssid.isNullOrEmpty() || pass.isNullOrEmpty() || pass.length < 8) {
                        result.error("INVALID", "ssid/pass invalid", null)
                        return@setMethodCallHandler
                    }
                    val suggestion = WifiNetworkSuggestion.Builder()
                        .setSsid(ssid)
                        .setWpa2Passphrase(pass)
                        .setIsAppInteractionRequired(true)
                        .build()
                    // Replace any previous suggestion list so stale links do
                    // not linger after re-provisioning.
                    wifi.removeNetworkSuggestions(emptyList())
                    val status = wifi.addNetworkSuggestions(listOf(suggestion))
                    result.success(status == WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS)
                }
                "unsuggest" -> {
                    wifi.removeNetworkSuggestions(emptyList())
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}

package com.hermesagent.hermes_android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel = "hermes_audio"

    // Pending SCO waiters — each entry is a continuation that resolves when SCO
    // reaches a terminal state (connected or disconnected). Multiple Dart calls
    // can race; we service them in FIFO order.
    private val scoWaiters = ArrayDeque<(Boolean) -> Unit>()

    private val scoReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED) return
            val state = intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)
            // 0=disconnected, 1=connecting, 2=connected
            if (state != AudioManager.SCO_AUDIO_STATE_CONNECTING) {
                drainWaiters(state == AudioManager.SCO_AUDIO_STATE_CONNECTED)
            }
        }
    }

    private var scoReceiverRegistered = false

    private fun drainWaiters(connected: Boolean) {
        while (scoWaiters.isNotEmpty()) {
            scoWaiters.removeFirst().invoke(connected)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                try {
                    when (call.method) {
                        "startCallAudio" -> startCallAudio(am, result)
                        "stopCallAudio" -> stopCallAudio(am, result)
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("AUDIO_ERROR", e.message, null)
                }
            }
    }

    private fun startCallAudio(am: AudioManager, result: MethodChannel.Result) {
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        am.isSpeakerphoneOn = false

        if (!am.isBluetoothScoAvailableOffCall) {
            // No BT earpiece — fall back to wired/handset routing immediately.
            result.success(false)
            return
        }

        registerReceiver(
            scoReceiver,
            IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED),
        )
        scoReceiverRegistered = true

        scoWaiters.addLast { connected -> result.success(connected) }
        am.startBluetoothSco()

        // Safety: if SCO never reports back within ~3s (some OEMs never fire
        // the broadcast), unblock the waiter so the call proceeds on the
        // handset mic instead of hanging forever.
        mainHandler.postDelayed({
            if (scoWaiters.isNotEmpty()) {
                drainWaiters(false)
            }
        }, 3000)
    }

    private fun stopCallAudio(am: AudioManager, result: MethodChannel.Result) {
        if (scoReceiverRegistered) {
            try {
                unregisterReceiver(scoReceiver)
            } catch (_: IllegalArgumentException) {
                // Not registered — ignore.
            }
            scoReceiverRegistered = false
        }
        drainWaiters(false)
        if (am.isBluetoothScoOn) {
            am.stopBluetoothSco()
        }
        am.mode = AudioManager.MODE_NORMAL
        result.success(true)
    }

    override fun onDestroy() {
        // Activity going away — make sure the SCO receiver is released even
        // if Dart never called stopCallAudio (process death, config change).
        if (scoReceiverRegistered) {
            try {
                unregisterReceiver(scoReceiver)
            } catch (_: IllegalArgumentException) {}
            scoReceiverRegistered = false
        }
        drainWaiters(false)
        super.onDestroy()
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
}
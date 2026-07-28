package com.hermesagent.hermes_android

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel = "hermes_audio"
    private val bluetoothConnectRequestCode = 4242

    // Pending SCO waiters — each entry is a continuation that resolves when SCO
    // reaches a terminal state (connected or disconnected). Multiple Dart calls
    // can race; we service them in FIFO order.
    private val scoWaiters = ArrayDeque<(Boolean) -> Unit>()

    // Continuation for an in-flight BLUETOOTH_CONNECT permission request.
    // Null when no request is pending. Resolved by onRequestPermissionsResult.
    private var bluetoothConnectContinuation: ((Boolean) -> Unit)? = null

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
                        "setSpeakerphone" -> setSpeakerphone(am, call, result)
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

        // Android 12+ requires a runtime BLUETOOTH_CONNECT grant before we
        // touch SCO. Without it, isBluetoothScoAvailableOffCall / startBluetoothSco
        // throw SecurityException. Request it; if denied, skip the BT path
        // (call proceeds on the handset earpiece) and return false so Dart
        // knows the earpiece isn't live.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.BLUETOOTH_CONNECT,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            ensureBluetoothConnectPermission { granted ->
                if (!granted) {
                    // Denied or cancelled — fall back to handset routing.
                    result.success(false)
                    return@ensureBluetoothConnectPermission
                }
                proceedWithBluetoothSco(am, result)
            }
            return
        }

        proceedWithBluetoothSco(am, result)
    }

    private fun ensureBluetoothConnectPermission(onResult: (Boolean) -> Unit) {
        // Already granted (re-entry from the request callback) or pre-S where
        // the runtime grant isn't needed.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.BLUETOOTH_CONNECT,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            onResult(true)
            return
        }
        if (bluetoothConnectContinuation != null) {
            // Request already in flight — chain onto the existing one. The
            // single continuation resolves once and fans out to all waiters.
            val existing = bluetoothConnectContinuation!!
            bluetoothConnectContinuation = { granted ->
                existing(granted)
                onResult(granted)
            }
            return
        }
        bluetoothConnectContinuation = onResult
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
            bluetoothConnectRequestCode,
        )
    }

    private fun proceedWithBluetoothSco(am: AudioManager, result: MethodChannel.Result) {
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

    /// Toggle the loudspeaker while the call is active. Keeps the existing
    /// MODE_IN_COMMUNICATION; only flips isSpeakerphoneOn. Returns the resulting
    /// speakerphone state so the Dart side can verify and update its UI.
    private fun setSpeakerphone(
        am: AudioManager,
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val enabled = call.argument<Boolean>("enabled")
            ?: throw IllegalArgumentException("enabled (bool) is required")
        am.isSpeakerphoneOn = enabled
        result.success(am.isSpeakerphoneOn)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != bluetoothConnectRequestCode) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        // Consume the pending continuation (only first waiter actually owns
        // the field; chained waiters in ensureBluetoothConnectPermission run
        // via that callback).
        val waiter = bluetoothConnectContinuation
        bluetoothConnectContinuation = null
        waiter?.invoke(granted)
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
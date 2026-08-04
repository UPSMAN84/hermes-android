package com.hermesagent.hermes_android

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.SystemClock
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

internal fun selectCommunicationDeviceType(
    availableTypes: List<Int>,
    speakerEnabled: Boolean,
): Int? {
    if (speakerEnabled) {
        return availableTypes.firstOrNull {
            it == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        }
    }

    return listOf(
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
    ).firstOrNull { it in availableTypes }
        ?: availableTypes.firstOrNull {
            it == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
        }
}

internal fun communicationRouteResult(
    activeType: Int,
    requireBluetooth: Boolean,
    requestedSpeakerState: Boolean?,
): Boolean {
    if (requestedSpeakerState != null) return requestedSpeakerState
    val bluetooth = activeType == AudioDeviceInfo.TYPE_BLE_HEADSET ||
        activeType == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
    return !requireBluetooth || bluetooth
}

class MainActivity : FlutterActivity() {

    private val channel = "hermes_audio"
    private val focusChannel = "hermes_audio_focus"
    private var focusSink: EventChannel.EventSink? = null
    private var focusRequest: AudioFocusRequest? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        mainHandler.post { focusSink?.success(change) }
    }
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
                        "requestCallAudioFocus" -> result.success(requestAudioFocus(am))
                        "abandonCallAudioFocus" -> {
                            abandonAudioFocus(am)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("AUDIO_ERROR", e.message, null)
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, focusChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    focusSink = events
                }

                override fun onCancel(arguments: Any?) {
                    focusSink = null
                }
            })
    }

    @Suppress("DEPRECATION")
    private fun requestAudioFocus(am: AudioManager): Boolean {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener, mainHandler)
                .build()
            focusRequest = request
            am.requestAudioFocus(request)
        } else {
            am.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            )
        }
        return granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    @Suppress("DEPRECATION")
    private fun abandonAudioFocus(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            am.abandonAudioFocus(focusListener)
        }
    }

    private fun startCallAudio(am: AudioManager, result: MethodChannel.Result) {
        am.mode = AudioManager.MODE_IN_COMMUNICATION

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
                setCommunicationRoute(
                    am = am,
                    speakerEnabled = false,
                    requireBluetooth = true,
                    result = result,
                )
            }
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            setCommunicationRoute(
                am = am,
                speakerEnabled = false,
                requireBluetooth = true,
                result = result,
            )
        } else {
            // Android 11 and older only expose the legacy SCO API.
            am.isSpeakerphoneOn = false
            proceedWithBluetoothSco(am, result)
        }
    }

    private fun setCommunicationRoute(
        am: AudioManager,
        speakerEnabled: Boolean,
        requireBluetooth: Boolean,
        requestedSpeakerState: Boolean? = null,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(false)
            return
        }

        val devices = am.availableCommunicationDevices
        val selectedType = selectCommunicationDeviceType(
            availableTypes = devices.map { it.type },
            speakerEnabled = speakerEnabled,
        )
        val selected = devices.firstOrNull { it.type == selectedType }
        if (selected == null) {
            result.success(false)
            return
        }

        if (!am.setCommunicationDevice(selected)) {
            result.success(false)
            return
        }

        waitForCommunicationRoute(
            am = am,
            selected = selected,
            requireBluetooth = requireBluetooth,
            requestedSpeakerState = requestedSpeakerState,
            result = result,
        )
    }

    private fun waitForCommunicationRoute(
        am: AudioManager,
        selected: AudioDeviceInfo,
        requireBluetooth: Boolean,
        requestedSpeakerState: Boolean?,
        result: MethodChannel.Result,
    ) {
        val deadline = SystemClock.uptimeMillis() + 3000L
        val check = object : Runnable {
            override fun run() {
                val active = am.communicationDevice
                if (active?.id == selected.id) {
                    result.success(communicationRouteResult(
                        active.type, requireBluetooth, requestedSpeakerState,
                    ))
                    return
                }

                if (SystemClock.uptimeMillis() >= deadline) {
                    result.success(false)
                    return
                }

                mainHandler.postDelayed(this, 50L)
            }
        }
        check.run()
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice()
        } else {
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
        }
        am.mode = AudioManager.MODE_NORMAL
        result.success(true)
    }

    /// Toggle the loudspeaker while the call is active.
    private fun setSpeakerphone(
        am: AudioManager,
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val enabled = call.argument<Boolean>("enabled")
            ?: throw IllegalArgumentException("enabled (bool) is required")
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            setCommunicationRoute(
                am = am,
                speakerEnabled = enabled,
                requireBluetooth = false,
                requestedSpeakerState = enabled,
                result = result,
            )
        } else {
            am.isSpeakerphoneOn = enabled
            result.success(am.isSpeakerphoneOn)
        }
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
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        abandonAudioFocus(am)
        focusSink = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice()
        } else if (am.isBluetoothScoOn) {
            am.stopBluetoothSco()
        }
        am.mode = AudioManager.MODE_NORMAL
        super.onDestroy()
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
}

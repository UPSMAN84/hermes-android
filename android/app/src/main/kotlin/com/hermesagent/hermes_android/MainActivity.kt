package com.hermesagent.hermes_android

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {

    private val channel = "hermes_audio"
    private val focusChannel = "hermes_audio_focus"
    private var focusSink: EventChannel.EventSink? = null
    private var focusRequest: AudioFocusRequest? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        mainHandler.post { focusSink?.success(change) }
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
        // Set MODE_IN_COMMUNICATION for echo cancellation and voice-quality audio
        // processing, but do NOT force a specific communication device via
        // setCommunicationDevice() or startBluetoothSco(). On Samsung OneUI,
        // explicitly enumerating availableCommunicationDevices and calling
        // setCommunicationDevice() triggers an AppOps UID attribution bug inside
        // com.android.phone that throws SecurityException and can destabilize the
        // telephony stack. Letting the platform choose the route automatically
        // (as CHARA does) avoids this entirely while still enabling AEC and
        // proper voice-call audio behavior.
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        result.success(true)
    }

    private fun stopCallAudio(am: AudioManager, result: MethodChannel.Result) {
        am.mode = AudioManager.MODE_NORMAL
        result.success(true)
    }

    /// Toggle the loudspeaker while the call is active. Uses the legacy
    /// isSpeakerphoneOn API which works reliably under MODE_IN_COMMUNICATION
    /// without triggering Samsung's AppOps bug (unlike setCommunicationDevice).
    @Suppress("DEPRECATION")
    private fun setSpeakerphone(
        am: AudioManager,
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val enabled = call.argument<Boolean>("enabled")
            ?: throw IllegalArgumentException("enabled (bool) is required")
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        am.isSpeakerphoneOn = enabled
        result.success(am.isSpeakerphoneOn)
    }

    override fun onDestroy() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        abandonAudioFocus(am)
        focusSink = null
        am.mode = AudioManager.MODE_NORMAL
        super.onDestroy()
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
}
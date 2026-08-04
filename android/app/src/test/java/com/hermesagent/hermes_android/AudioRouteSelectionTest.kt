package com.hermesagent.hermes_android

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Test

class AudioRouteSelectionTest {
    @Test
    fun speakerRouteReportsRequestedDisabledStateOnSuccess() {
        assertEquals(false, communicationRouteResult(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, false, false))
    }

    @Test
    fun callStartReportsWhetherBluetoothActuallyWon() {
        assertEquals(true, communicationRouteResult(AudioDeviceInfo.TYPE_BLE_HEADSET, true, null))
        assertEquals(false, communicationRouteResult(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, true, null))
    }

    @Test
    fun bluetoothIsPreferredWhenSpeakerIsOff() {
        val selected = selectCommunicationDeviceType(
            availableTypes = listOf(
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            ),
            speakerEnabled = false,
        )

        assertEquals(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, selected)
    }

    @Test
    fun speakerIsSelectedWhenSpeakerIsOn() {
        val selected = selectCommunicationDeviceType(
            availableTypes = listOf(
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            ),
            speakerEnabled = true,
        )

        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, selected)
    }
}

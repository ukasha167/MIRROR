package dev.mirror.continuity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit test validating PresenceWakeService state invariants without Android runtime.
 */
class PresenceWakeServiceTest {

    @Test
    fun testInitialDisconnectedState() {
        PresenceWakeService.setConnectedForTesting(false)
        assertFalse(PresenceWakeService.isDeviceConnected)
        assertEquals(false, PresenceWakeService.isDeviceConnectedFlow.value)
    }

    @Test
    fun testPresenceStateTransition() {
        PresenceWakeService.setConnectedForTesting(true)
        assertTrue(PresenceWakeService.isDeviceConnected)
        assertEquals(true, PresenceWakeService.isDeviceConnectedFlow.value)

        PresenceWakeService.setConnectedForTesting(false)
        assertFalse(PresenceWakeService.isDeviceConnected)
    }
}

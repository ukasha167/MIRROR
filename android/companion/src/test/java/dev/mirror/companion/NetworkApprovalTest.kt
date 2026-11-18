package dev.mirror.companion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NetworkApprovalTest {
    private val home = setOf("HUAWEI-5G-9fDV")

    @Test fun stripsQuotesAroundUtf8Names() {
        assertEquals("HUAWEI-5G-9fDV", NetworkApproval.normalize("\"HUAWEI-5G-9fDV\""))
    }

    @Test fun keepsHexNamesAsTheyAre() {
        assertEquals("e4bda0e5a5bd", NetworkApproval.normalize("e4bda0e5a5bd"))
    }

    @Test fun hiddenOrEmptyNamesAreNull() {
        assertNull(NetworkApproval.normalize("<unknown ssid>"))
        assertNull(NetworkApproval.normalize("\"\""))
        assertNull(NetworkApproval.normalize("  "))
        assertNull(NetworkApproval.normalize(null))
    }

    @Test fun turnsOnOnlyOnApprovedNetworks() {
        assertEquals(WifiDecision.TurnOn, NetworkApproval.decide("\"HUAWEI-5G-9fDV\"", home, false, true))
        assertEquals(WifiDecision.NotApproved("Cafe"), NetworkApproval.decide("\"Cafe\"", home, false, true))
    }

    @Test fun permissionIsCheckedFirst() {
        assertEquals(WifiDecision.NoPermission, NetworkApproval.decide("\"HUAWEI-5G-9fDV\"", home, true, false))
    }

    @Test fun leavesItAloneWhenAlreadyOn() {
        assertEquals(WifiDecision.AlreadyOn, NetworkApproval.decide("<unknown ssid>", home, true, true))
    }

    @Test fun hiddenNameNeverTurnsOn() {
        assertEquals(WifiDecision.UnknownNetwork, NetworkApproval.decide("<unknown ssid>", home, false, true))
    }

    @Test fun namesMatchExactly() {
        assertEquals(
            WifiDecision.NotApproved("huawei-5g-9fdv"),
            NetworkApproval.decide("\"huawei-5g-9fdv\"", home, false, true),
        )
    }
}

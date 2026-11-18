package dev.mirror.companion

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

/** Snapshot of everything the screen shows. Read again on every resume. */
data class CompanionState(
    val canWrite: Boolean,
    val canReadName: Boolean,
    val wirelessOn: Boolean,
    val ssid: String?,
    val approved: List<String>,
)

class MainActivity : ComponentActivity() {
    private var state by mutableStateOf<CompanionState?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                Surface(Modifier.fillMaxSize()) {
                    state?.let { Screen(it) }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (AdbWifi.canWrite(this)) WifiWatch.register(this)
        reload()
    }

    private fun reload() {
        state = CompanionState(
            canWrite = AdbWifi.canWrite(this),
            canReadName = AdbWifi.canReadNetworkName(this),
            wirelessOn = AdbWifi.isOn(this),
            ssid = AdbWifi.currentSsid(this),
            approved = ApprovedNetworks(this).all().toList(),
        )
    }

    @Composable
    private fun Screen(s: CompanionState) {
        Column(
            Modifier.safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Mirror", style = MaterialTheme.typography.headlineMedium)
            Text(
                "Turns Wireless debugging back on after a restart, on networks you approve, " +
                    "so the Mac finds this phone without the cable.",
                style = MaterialTheme.typography.bodyMedium,
            )
            if (!s.canWrite) SetupCard() else {
                WirelessRow(s)
                NetworkCard(s)
            }
        }
    }

    @Composable
    private fun SetupCard() {
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("One-time setup", style = MaterialTheme.typography.titleMedium)
                Text("Plug the phone into the Mac and open Mirror's menu. The Mac grants this app permission to change the Wireless debugging setting. Or run:")
                SelectionContainer {
                    Text(
                        "adb shell pm grant $packageName android.permission.WRITE_SECURE_SETTINGS",
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }

    @Composable
    private fun WirelessRow(s: CompanionState) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Wireless debugging", style = MaterialTheme.typography.titleMedium)
                Text(if (s.wirelessOn) "On. The Mac can connect." else "Off", style = MaterialTheme.typography.bodySmall)
            }
            Switch(checked = s.wirelessOn, onCheckedChange = { AdbWifi.set(this@MainActivity, it); reload() })
        }
    }

    @Composable
    private fun NetworkCard(s: CompanionState) {
        val store = ApprovedNetworks(this)
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Approved networks", style = MaterialTheme.typography.titleMedium)
                when {
                    !s.canReadName -> Text("Android hides the Wi-Fi name until the Mac grants location access. Plug into the Mac once more.")
                    s.ssid == null -> Text("Not on Wi-Fi, or location is off.")
                    s.ssid in s.approved -> Text("This network (${s.ssid}) is approved.")
                    else -> Button(onClick = { store.add(s.ssid); reload() }) { Text("Approve ${s.ssid}") }
                }
                if (s.approved.isNotEmpty()) HorizontalDivider()
                for (name in s.approved) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(name, Modifier.weight(1f))
                        TextButton(onClick = { store.remove(name); reload() }) { Text("Remove") }
                    }
                }
            }
        }
    }
}

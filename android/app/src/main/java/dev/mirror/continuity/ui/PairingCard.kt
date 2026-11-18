package dev.mirror.continuity.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.mirror.continuity.network.DiscoveredMacPeer
import dev.mirror.continuity.network.PairingAttemptState
import dev.mirror.continuity.pairing.ContinuityPairingCodec
import dev.mirror.continuity.ui.theme.ContinuityRed

@Composable
fun PairingCard(
    localPairCode: String,
    discoveredMacs: List<DiscoveredMacPeer>,
    pairingState: PairingAttemptState,
    isUsbAttached: Boolean,
    onOpenQrScanner: () -> Unit,
    onPairWithMacCode: (DiscoveredMacPeer?, String?, String) -> Unit,
    onRotateLocalCode: () -> Unit,
    onClearError: () -> Unit,
    modifier: Modifier = Modifier
) {
    var selectedTab by remember { mutableIntStateOf(0) } // 0 = Enter Mac Code, 1 = Show Phone Code
    var codeInput by remember { mutableStateOf("") }
    var manualAddress by remember { mutableStateOf("") }
    var showManualIp by remember { mutableStateOf(false) }
    var selectedMacId by remember(discoveredMacs) {
        mutableStateOf(discoveredMacs.firstOrNull()?.id)
    }

    val isPairing = pairingState is PairingAttemptState.Pairing
    val errorText = (pairingState as? PairingAttemptState.Error)?.message

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = "Pair with Mac",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = "Scan Mac's QR code, enter its 6-digit code, or share this phone's code.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Button(
                onClick = onOpenQrScanner,
                enabled = !isPairing,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth().height(46.dp)
            ) {
                Icon(Icons.Rounded.QrCodeScanner, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(8.dp))
                Text("Scan Mac QR Code", fontWeight = FontWeight.SemiBold)
            }

            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                SegmentedButton(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2)
                ) {
                    Text("Enter Mac Code")
                }
                SegmentedButton(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2)
                ) {
                    Text("Phone Code")
                }
            }

            if (selectedTab == 0) {
                val chosenMac = discoveredMacs.firstOrNull { it.id == selectedMacId } ?: discoveredMacs.firstOrNull()
                if (discoveredMacs.isNotEmpty()) {
                    Text(
                        text = "Mirror open & ready to pair",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        discoveredMacs.forEach { mac ->
                            FilterChip(
                                selected = mac.id == chosenMac?.id,
                                onClick = { selectedMacId = mac.id },
                                label = { Text("${mac.name} (${if (mac.viaUsb) "USB" else "Wi-Fi"})") }
                            )
                        }
                    }
                } else {
                    Text(
                        text = if (isUsbAttached) {
                            "USB cable ready · Open Mirror on Mac or enter IP below"
                        } else {
                            "Searching local network for Mirror on Mac..."
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    OutlinedTextField(
                        value = codeInput,
                        onValueChange = { raw ->
                            onClearError()
                            codeInput = ContinuityPairingCodec.normalizePin(raw)
                        },
                        placeholder = { Text("6-digit Mac code") },
                        singleLine = true,
                        textStyle = MaterialTheme.typography.titleMedium.copy(
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.Bold
                        ),
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Number,
                            imeAction = ImeAction.Done
                        ),
                        keyboardActions = KeyboardActions(
                            onDone = {
                                if (codeInput.length == 6 && !isPairing) {
                                    onPairWithMacCode(chosenMac, if (showManualIp) manualAddress else null, codeInput)
                                }
                            }
                        ),
                        modifier = Modifier.weight(1f)
                    )

                    OutlinedButton(
                        onClick = {
                            onPairWithMacCode(chosenMac, if (showManualIp) manualAddress else null, codeInput)
                        },
                        enabled = codeInput.length == 6 && !isPairing,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.height(52.dp)
                    ) {
                        if (isPairing) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Text("Pair", fontWeight = FontWeight.SemiBold)
                        }
                    }
                }

                Text(
                    text = if (showManualIp) "Hide manual Mac IP" else "Enter Mac IP manually",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.clickable { showManualIp = !showManualIp }
                )

                if (showManualIp) {
                    OutlinedTextField(
                        value = manualAddress,
                        onValueChange = { manualAddress = it },
                        placeholder = { Text("e.g. 192.168.1.25:53318") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            } else {
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                text = "THIS PHONE'S CODE",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Text(
                                text = ContinuityPairingCodec.formatPin(localPairCode),
                                style = MaterialTheme.typography.headlineSmall.copy(
                                    fontFamily = FontFamily.Monospace,
                                    fontWeight = FontWeight.Bold
                                )
                            )
                            Text(
                                text = "Enter this code on your Mac (Enter Code tab)",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        IconButton(onClick = onRotateLocalCode) {
                            Icon(Icons.Rounded.Refresh, contentDescription = "Refresh code")
                        }
                    }
                }
            }

            if (errorText != null) {
                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = ContinuityRed.copy(alpha = 0.12f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = errorText,
                            color = ContinuityRed,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.weight(1f)
                        )
                        TextButton(onClick = onClearError) {
                            Text("Dismiss")
                        }
                    }
                }
            }
        }
    }
}

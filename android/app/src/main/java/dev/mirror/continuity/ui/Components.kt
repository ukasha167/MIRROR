package dev.mirror.continuity.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.Usb
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.mirror.continuity.network.ContinuityUiConnectionStatus
import dev.mirror.continuity.ui.theme.ContinuityAmber
import dev.mirror.continuity.ui.theme.ContinuityGreen

@Composable
fun DeviceConnectionHeader(
    status: ContinuityUiConnectionStatus,
    viaUsb: Boolean,
    hasPairedMacRecord: Boolean,
    pairedMacName: String?,
    onUnpair: () -> Unit,
    modifier: Modifier = Modifier
) {
    val isConnected = status is ContinuityUiConnectionStatus.Connected
    val isUsbWaiting = status is ContinuityUiConnectionStatus.UsbWaitingForMacApp

    val badgeColor = when {
        isConnected -> ContinuityGreen
        isUsbWaiting -> ContinuityAmber
        else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
    }

    val title = when (status) {
        is ContinuityUiConnectionStatus.Connected -> status.macName
        is ContinuityUiConnectionStatus.UsbWaitingForMacApp -> "Not Connected"
        is ContinuityUiConnectionStatus.Disconnected -> "Not Connected"
    }

    val subtitle = when (status) {
        is ContinuityUiConnectionStatus.Connected ->
            if (viaUsb) "Connected to Mirror on Mac · USB Tunnel" else "Connected to Mirror on Mac · Wi-Fi"
        is ContinuityUiConnectionStatus.UsbWaitingForMacApp ->
            "USB cable plugged · Open Mirror on Mac to connect"
        is ContinuityUiConnectionStatus.Disconnected ->
            if (!pairedMacName.isNullOrBlank()) "Waiting for Mirror on $pairedMacName" else "Pair your Mac below to connect"
    }

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Rounded.LaptopMac,
                    contentDescription = null,
                    tint = if (isConnected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(22.dp)
                )
            }

            Spacer(modifier = Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(badgeColor)
                    )
                    Text(
                        text = subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (isConnected) ContinuityGreen else if (isUsbWaiting) ContinuityAmber else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            if (isConnected) {
                Icon(
                    imageVector = if (viaUsb) Icons.Rounded.Usb else Icons.Rounded.Wifi,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp)
                )
            }
            if (isConnected || hasPairedMacRecord) {
                TextButton(onClick = onUnpair) {
                    Text("Unpair", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

@Composable
fun NotificationPermissionBanner(
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier
) = PermissionBanner(
    icon = Icons.Rounded.NotificationsActive,
    message = "Enable Notification Access for 2FA & alerts",
    actionLabel = "Enable",
    onAction = onOpenSettings,
    modifier = modifier
)

@Composable
fun LocalNetworkPermissionBanner(
    onRequestPermission: () -> Unit,
    modifier: Modifier = Modifier
) = PermissionBanner(
    icon = Icons.Rounded.Wifi,
    message = "Allow Local Network access to discover your Mac over Wi-Fi",
    actionLabel = "Allow",
    onAction = onRequestPermission,
    modifier = modifier
)

@Composable
private fun PermissionBanner(
    icon: ImageVector,
    message: String,
    actionLabel: String,
    onAction: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        color = ContinuityAmber.copy(alpha = 0.12f),
        border = BorderStroke(1.dp, ContinuityAmber.copy(alpha = 0.45f))
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = ContinuityAmber,
                modifier = Modifier.size(20.dp)
            )
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                text = message,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.weight(1f)
            )
            TextButton(onClick = onAction) {
                Text(actionLabel)
            }
        }
    }
}

data class ContinuityToggleItem(
    val icon: ImageVector,
    val title: String,
    val description: String,
    val enabled: Boolean,
    val onToggle: (Boolean) -> Unit
)

@Composable
fun GroupedFeatureSettingsCard(
    items: List<ContinuityToggleItem>,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            items.forEachIndexed { index, item ->
                FeatureToggleRow(
                    icon = item.icon,
                    title = item.title,
                    description = item.description,
                    enabled = item.enabled,
                    onToggle = item.onToggle
                )
                if (index < items.lastIndex) {
                    HorizontalDivider(
                        modifier = Modifier.padding(horizontal = 16.dp),
                        color = MaterialTheme.colorScheme.outlineVariant
                    )
                }
            }
        }
    }
}

@Composable
fun FeatureToggleRow(
    icon: ImageVector,
    title: String,
    description: String,
    enabled: Boolean,
    onToggle: (Boolean) -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp)
        )
        Spacer(modifier = Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium
            )
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Switch(checked = enabled, onCheckedChange = onToggle)
    }
}

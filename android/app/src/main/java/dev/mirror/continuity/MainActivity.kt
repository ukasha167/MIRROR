package dev.mirror.continuity

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.mirror.continuity.network.ContinuityConnectionPolicy
import dev.mirror.continuity.network.ContinuityLinkManager
import dev.mirror.continuity.network.ContinuityLinkState
import dev.mirror.continuity.network.ContinuityPrefsStore
import dev.mirror.continuity.ui.ContinuityToggleItem
import dev.mirror.continuity.ui.DeviceConnectionHeader
import dev.mirror.continuity.ui.GroupedFeatureSettingsCard
import dev.mirror.continuity.ui.NotificationPermissionBanner
import dev.mirror.continuity.ui.PairingCard
import dev.mirror.continuity.ui.QrScannerDialog
import dev.mirror.continuity.ui.theme.ContinuityTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ContinuityLinkManager.ensureStarted(applicationContext)

        setContent {
            ContinuityTheme {
                MainContinuityScreen()
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainContinuityScreen() {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val prefsStore = remember { ContinuityPrefsStore(context) }

    LaunchedEffect(Unit) {
        ContinuityLinkManager.ensureStarted(context)
    }

    var features by remember { mutableStateOf(prefsStore.getFeaturePrefs()) }
    var showQrScanner by remember { mutableStateOf(false) }
    var hasNotificationAccess by remember {
        mutableStateOf(
            NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)
        )
    }
    val localNetworkPermission = "android.permission.ACCESS_LOCAL_NETWORK"
    val requiresLocalNetworkPermission = Build.VERSION.SDK_INT >= 36
    var hasLocalNetworkAccess by remember {
        mutableStateOf(
            !requiresLocalNetworkPermission ||
                ContextCompat.checkSelfPermission(context, localNetworkPermission) == PackageManager.PERMISSION_GRANTED
        )
    }
    val localNetworkLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasLocalNetworkAccess = granted
        if (granted) ContinuityLinkManager.restartDiscovery(context)
    }
    LaunchedEffect(requiresLocalNetworkPermission) {
        if (requiresLocalNetworkPermission && !hasLocalNetworkAccess) {
            localNetworkLauncher.launch(localNetworkPermission)
        }
    }

    // Refresh notification & Local Network permission grants when returning from Settings
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                hasNotificationAccess =
                    NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)
                if (requiresLocalNetworkPermission) {
                    val grantedNow = ContextCompat.checkSelfPermission(context, localNetworkPermission) == PackageManager.PERMISSION_GRANTED
                    if (grantedNow && !hasLocalNetworkAccess) ContinuityLinkManager.restartDiscovery(context)
                    hasLocalNetworkAccess = grantedNow
                }
                ContinuityLinkManager.triggerReconnectAttempt()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Monitor actual USB data attachment (works even on USB-C PD chargers that set BATTERY_PLUGGED_AC)
    DisposableEffect(context) {
        val usbReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                val connected = intent?.getBooleanExtra("connected", false) == true
                val adb = intent?.getBooleanExtra("adb", false) == true
                val configured = intent?.getBooleanExtra("configured", false) == true
                ContinuityLinkManager.updateUsbDataAttached(connected || adb || configured)
            }
        }
        val initialUsb = ContextCompat.registerReceiver(
            context,
            usbReceiver,
            IntentFilter("android.hardware.usb.action.USB_STATE"),
            ContextCompat.RECEIVER_EXPORTED
        )
        if (initialUsb != null) usbReceiver.onReceive(context, initialUsb)
        onDispose { runCatching { context.unregisterReceiver(usbReceiver) } }
    }

    // Monitor physical USB/AC charging cable live (never marks connected unless Mac app handshakes!)
    DisposableEffect(context) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
                val isUsb = (plugged and BatteryManager.BATTERY_PLUGGED_USB) != 0
                val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, 100) ?: 100
                val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100)?.coerceAtLeast(1) ?: 100
                val pct = (level * 100) / scale
                val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
                ContinuityLinkManager.updatePowerAndUsbState(isUsb, pct, charging)
            }
        }
        val initial = context.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        receiver.onReceive(context, initial)
        onDispose { runCatching { context.unregisterReceiver(receiver) } }
    }

    val linkState by ContinuityLinkManager.connectionState.collectAsState()
    val isUsbAttached by ContinuityLinkManager.isUsbCableAttachedFlow.collectAsState()
    val localPairCode by ContinuityLinkManager.localPairCodeFlow.collectAsState()
    val discoveredMacs by ContinuityLinkManager.discoveredMacsFlow.collectAsState()
    val pairingState by ContinuityLinkManager.pairingStateFlow.collectAsState()
    val trustedMac by ContinuityLinkManager.trustedMacFlow.collectAsState()

    val connectedInfo = linkState as? ContinuityLinkState.Connected
    val uiStatus = ContinuityConnectionPolicy.evaluateMutualConnection(
        isHandshakeVerified = connectedInfo != null,
        verifiedMacName = connectedInfo?.macName,
        isUsbCableAttached = isUsbAttached
    )

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Mirror Continuity", fontWeight = FontWeight.SemiBold) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    titleContentColor = MaterialTheme.colorScheme.onBackground
                )
            )
        },
        containerColor = MaterialTheme.colorScheme.background
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            DeviceConnectionHeader(
                status = uiStatus,
                viaUsb = connectedInfo?.viaUsb == true,
                hasPairedMacRecord = trustedMac != null,
                pairedMacName = trustedMac?.name,
                onUnpair = { ContinuityLinkManager.unpairMac() },
                modifier = Modifier.padding(top = 4.dp)
            )

            if (!hasNotificationAccess) {
                NotificationPermissionBanner(
                    onOpenSettings = {
                        context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    }
                )
            }
            if (!hasLocalNetworkAccess) {
                dev.mirror.continuity.ui.LocalNetworkPermissionBanner(
                    onRequestPermission = { localNetworkLauncher.launch(localNetworkPermission) }
                )
            }

            if (connectedInfo == null) {
                PairingCard(
                    localPairCode = localPairCode,
                    discoveredMacs = discoveredMacs,
                    pairingState = pairingState,
                    isUsbAttached = isUsbAttached,
                    onOpenQrScanner = { showQrScanner = true },
                    onPairWithMacCode = { mac, manualIp, code ->
                        ContinuityLinkManager.pairWithMacCode(mac, manualIp, code)
                    },
                    onRotateLocalCode = { ContinuityLinkManager.rotateLocalPairCode() },
                    onClearError = { ContinuityLinkManager.clearPairingError() }
                )
            }

            Text(
                text = "Continuity Services",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary
            )

            GroupedFeatureSettingsCard(
                items = listOf(
                    ContinuityToggleItem(
                        icon = Icons.Rounded.ContentCopy,
                        title = "Universal Clipboard",
                        description = "Share copied text and images seamlessly with your Mac",
                        enabled = features.clipboardSync,
                        onToggle = { v -> features = features.copy(clipboardSync = v); prefsStore.saveFeaturePrefs(features) }
                    ),
                    ContinuityToggleItem(
                        icon = Icons.Rounded.Notifications,
                        title = "Notification Mirroring",
                        description = "Mirror phone alerts and reply directly from macOS",
                        enabled = features.notificationMirror,
                        onToggle = { v -> features = features.copy(notificationMirror = v); prefsStore.saveFeaturePrefs(features) }
                    ),
                    ContinuityToggleItem(
                        icon = Icons.Rounded.Key,
                        title = "2FA Code Handoff",
                        description = "Send incoming verification SMS codes to your Mac",
                        enabled = features.otpAutofill,
                        onToggle = { v -> features = features.copy(otpAutofill = v); prefsStore.saveFeaturePrefs(features) }
                    ),
                    ContinuityToggleItem(
                        icon = Icons.Rounded.CameraAlt,
                        title = "Continuity Camera",
                        description = "Stream rear camera feed as a macOS webcam",
                        enabled = features.mediaHandoff,
                        onToggle = { v -> features = features.copy(mediaHandoff = v); prefsStore.saveFeaturePrefs(features) }
                    ),
                    ContinuityToggleItem(
                        icon = Icons.Rounded.Share,
                        title = "Quick Share Target",
                        description = "Send files from Android's share sheet to your Mac",
                        enabled = features.quickShareTarget,
                        onToggle = { v -> features = features.copy(quickShareTarget = v); prefsStore.saveFeaturePrefs(features) }
                    )
                ),
                modifier = Modifier.padding(bottom = 24.dp)
            )
        }
    }

    if (showQrScanner) {
        QrScannerDialog(
            onQrScanned = { rawQr -> ContinuityLinkManager.pairWithQr(rawQr) },
            onDismiss = { showQrScanner = false }
        )
    }
}

//! Unified session multiplexer and UniFFI-ready `ContinuityEngine` facade.
//!
//! Bridges `continuity-proto` binary control frames, QR/mTLS pairing,
//! Keychain/Keystore persistence, 1Password/Maccy pasteboard privacy filters,
//! and resource/thermal budgets into a single stateful engine.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use continuity_proto::{
    ClipboardDataChunk, ClipboardOffer, ContinuityPairingQr, ControlFrame, ControlPacket,
    DragOutOffer, Heartbeat, LanEndpoint, MediaControlCommand, MediaSessionUpdate,
    NotificationInlineReply, NotificationMirror, OtpCodeDetected, PairingStateMachine,
    PinnedPeerIdentity, PowerStateUpdate,
};

use crate::error::{CoreError, CoreResult};
use crate::keystore::{KeystoreBridge, PairedDeviceStore};
use crate::resource::{
    AppleSiliconGeneration, ResourceBudgetMonitor, ResourceSnapshot, StreamThermalBudget,
};

/// Well-known logical stream IDs on the unified control multiplexer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u32)]
pub enum ControlStreamId {
    /// Global clipboard offers and deferred data chunks (`IClipboard` / `NSPasteboard`).
    Clipboard = 1,
    /// Notification mirroring, inline replies, and 2FA OTP extraction.
    Notifications = 2,
    /// Now Playing metadata and media playback controls.
    Media = 3,
    /// Phone-to-Mac drag-out promises (`NSFilePromiseProvider`).
    DragDrop = 4,
    /// Heartbeats, battery/thermal telemetry, and OLED screen-off state.
    Telemetry = 5,
}

/// High-level events emitted by [`ContinuityEngine`] to the Swift or Kotlin UI layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContinuityEvent {
    /// A peer completed mutual TLS verification and is now pinned.
    PeerPaired(PinnedPeerIdentity),
    /// A lazy clipboard promise was registered (`NSPasteboardItemDataProvider`).
    ClipboardLazyPromiseReady(ClipboardOffer),
    /// A deferred clipboard data chunk arrived for an active offer.
    ClipboardChunkReceived(ClipboardDataChunk),
    /// An Android notification arrived for `UNUserNotificationCenter`.
    NotificationArrived(NotificationMirror),
    /// An inline reply from macOS arrived for Android `RemoteInput`.
    InlineReplyRequested(NotificationInlineReply),
    /// A 2FA OTP code was detected for the macOS floating pill / auto-copy.
    OtpPillReady(OtpCodeDetected),
    /// Now Playing media metadata updated.
    NowPlayingChanged(MediaSessionUpdate),
    /// Media control command received.
    MediaCommandReceived(MediaControlCommand),
    /// Phone-to-Mac drag-out session crossed the mirror window boundary.
    DragOutPromiseStarted(DragOutOffer),
    /// Heartbeat received on the multiplexer.
    HeartbeatReceived(Heartbeat),
    /// Device battery, charging, thermal, and OLED power state updated.
    PowerAndThermalUpdated {
        /// Raw power/thermal packet.
        state: PowerStateUpdate,
        /// Recommended stream bitrate/fps budget for the reported thermal state.
        thermal_budget: StreamThermalBudget,
    },
}

/// Primary UniFFI-ready facade coordinating pairing, control multiplexing, and resource limits.
pub struct ContinuityEngine {
    device_id: String,
    device_name: String,
    allow_concealed_clipboard: bool,
    device_store: PairedDeviceStore,
    pairing_sm: PairingStateMachine,
    resource_monitor: ResourceBudgetMonitor,
    stream_sequences: HashMap<u32, u32>,
    active_clipboard_offers: HashMap<u64, ClipboardOffer>,
    active_drag_offers: HashMap<u64, DragOutOffer>,
    outbound_wire_queue: VecDeque<Vec<u8>>,
}

impl ContinuityEngine {
    /// Creates a new [`ContinuityEngine`] backed by the platform [`KeystoreBridge`].
    pub fn new(
        device_id: String,
        device_name: String,
        chip_generation: AppleSiliconGeneration,
        keystore: Arc<dyn KeystoreBridge>,
    ) -> CoreResult<Self> {
        let device_store = PairedDeviceStore::new(keystore)?;
        let pairing_sm = PairingStateMachine::new(device_store.local_cert_sha256());
        Ok(Self {
            device_id,
            device_name,
            allow_concealed_clipboard: false,
            device_store,
            pairing_sm,
            resource_monitor: ResourceBudgetMonitor::new(chip_generation),
            stream_sequences: HashMap::new(),
            active_clipboard_offers: HashMap::new(),
            active_drag_offers: HashMap::new(),
            outbound_wire_queue: VecDeque::new(),
        })
    }

    /// Configures whether concealed clipboard items (`1Password` / `Bitwarden`) may sync.
    pub fn set_allow_concealed_clipboard(&mut self, allow: bool) {
        self.allow_concealed_clipboard = allow;
    }

    /// Returns a reference to the [`PairedDeviceStore`].
    pub fn device_store(&self) -> &PairedDeviceStore {
        &self.device_store
    }

    /// Returns a reference to the [`ResourceBudgetMonitor`].
    pub fn resource_monitor(&self) -> &ResourceBudgetMonitor {
        &self.resource_monitor
    }

    /// Validates a runtime [`ResourceSnapshot`] against idle/active RAM & CPU budgets.
    pub fn check_resource_budget(&mut self, snapshot: ResourceSnapshot) -> CoreResult<()> {
        self.resource_monitor.verify_snapshot(snapshot)
    }

    /// Generates a unified Wireless ADB + Continuity mTLS QR payload and arms the pairing state machine.
    pub fn start_qr_pairing_session(
        &mut self,
        adb_service_name: String,
        adb_password: String,
        endpoints: Vec<LanEndpoint>,
        now_secs: u64,
        ttl_secs: u64,
    ) -> CoreResult<ContinuityPairingQr> {
        let qr = ContinuityPairingQr {
            adb_service_name,
            adb_password,
            device_id: self.device_id.clone(),
            device_name: self.device_name.clone(),
            cert_sha256: self.device_store.local_cert_sha256(),
            endpoints,
            expires_at_secs: now_secs.saturating_add(ttl_secs),
        };
        self.pairing_sm.begin_with_qr(qr.clone(), now_secs)?;
        Ok(qr)
    }

    /// Completes QR pairing by verifying the peer's X.509 certificate and persisting it in Keychain/Keystore.
    pub fn complete_qr_pairing(
        &mut self,
        peer_device_id: String,
        peer_device_name: String,
        presented_peer_cert_der: &[u8],
        expected_peer_sha256: &[u8; 32],
        now_secs: u64,
    ) -> CoreResult<ContinuityEvent> {
        let pinned = self.pairing_sm.verify_peer_certificate(
            peer_device_id,
            peer_device_name,
            presented_peer_cert_der,
            expected_peer_sha256,
            now_secs,
        )?;
        self.device_store.record_paired_peer(&pinned)?;
        Ok(ContinuityEvent::PeerPaired(pinned))
    }

    /// Verifies a reconnect from a paired peer with zero confirmation prompts.
    pub fn verify_zero_prompt_reconnect(
        &self,
        peer_device_id: &str,
        presented_peer_cert_der: &[u8],
    ) -> CoreResult<PinnedPeerIdentity> {
        self.device_store
            .verify_zero_prompt_peer(peer_device_id, presented_peer_cert_der)
    }

    /// Queues a lazy [`ClipboardOffer`] on the `Clipboard` stream after enforcing privacy rules.
    pub fn send_clipboard_offer(&mut self, offer: ClipboardOffer) -> CoreResult<()> {
        if !offer.should_auto_sync(self.allow_concealed_clipboard) {
            return Err(CoreError::ClipboardPrivacyBlocked {
                offer_id: offer.offer_id,
                is_concealed: offer.is_concealed,
                is_transient: offer.is_transient,
            });
        }
        self.active_clipboard_offers
            .insert(offer.offer_id, offer.clone());
        self.enqueue_packet(
            ControlStreamId::Clipboard,
            ControlPacket::ClipboardOffer(offer),
        )
    }

    /// Queues a [`ClipboardDataChunk`] for an existing clipboard offer.
    pub fn send_clipboard_chunk(&mut self, chunk: ClipboardDataChunk) -> CoreResult<()> {
        if !self.active_clipboard_offers.contains_key(&chunk.offer_id) {
            return Err(CoreError::OfferNotFound {
                offer_id: chunk.offer_id,
            });
        }
        if chunk.is_last {
            self.active_clipboard_offers.remove(&chunk.offer_id);
        }
        self.enqueue_packet(
            ControlStreamId::Clipboard,
            ControlPacket::ClipboardDataChunk(chunk),
        )
    }

    /// Queues a generic [`ControlPacket`] on its canonical [`ControlStreamId`].
    pub fn send_control_packet(&mut self, packet: ControlPacket) -> CoreResult<()> {
        let stream = match &packet {
            ControlPacket::ClipboardOffer(offer) => {
                return self.send_clipboard_offer(offer.clone());
            }
            ControlPacket::ClipboardDataChunk(chunk) => {
                return self.send_clipboard_chunk(chunk.clone());
            }
            ControlPacket::NotificationMirror(_)
            | ControlPacket::NotificationInlineReply(_)
            | ControlPacket::OtpCodeDetected(_) => ControlStreamId::Notifications,
            ControlPacket::MediaSessionUpdate(_) | ControlPacket::MediaControlCommand(_) => {
                ControlStreamId::Media
            }
            ControlPacket::DragOutOffer(drag) => {
                self.active_drag_offers.insert(drag.drag_id, drag.clone());
                ControlStreamId::DragDrop
            }
            ControlPacket::Heartbeat(_) | ControlPacket::PowerStateUpdate(_) => {
                ControlStreamId::Telemetry
            }
        };
        self.enqueue_packet(stream, packet)
    }

    /// Drains all encoded wire frames ready to be written to the mTLS socket.
    pub fn drain_outbound_frames(&mut self) -> Vec<Vec<u8>> {
        self.outbound_wire_queue.drain(..).collect()
    }

    /// Returns the number of queued outbound wire frames awaiting transmission.
    pub fn pending_frame_count(&self) -> usize {
        self.outbound_wire_queue.len()
    }

    /// Decodes an inbound wire frame and returns the corresponding [`ContinuityEvent`].
    pub fn ingest_wire_frame(&mut self, wire_bytes: &[u8]) -> CoreResult<ContinuityEvent> {
        let frame = ControlFrame::decode(wire_bytes)?;
        match frame.packet {
            ControlPacket::ClipboardOffer(offer) => {
                if !offer.should_auto_sync(self.allow_concealed_clipboard) {
                    return Err(CoreError::ClipboardPrivacyBlocked {
                        offer_id: offer.offer_id,
                        is_concealed: offer.is_concealed,
                        is_transient: offer.is_transient,
                    });
                }
                self.active_clipboard_offers
                    .insert(offer.offer_id, offer.clone());
                Ok(ContinuityEvent::ClipboardLazyPromiseReady(offer))
            }
            ControlPacket::ClipboardDataChunk(chunk) => {
                if chunk.is_last {
                    self.active_clipboard_offers.remove(&chunk.offer_id);
                }
                Ok(ContinuityEvent::ClipboardChunkReceived(chunk))
            }
            ControlPacket::NotificationMirror(n) => Ok(ContinuityEvent::NotificationArrived(n)),
            ControlPacket::NotificationInlineReply(r) => {
                Ok(ContinuityEvent::InlineReplyRequested(r))
            }
            ControlPacket::OtpCodeDetected(otp) => Ok(ContinuityEvent::OtpPillReady(otp)),
            ControlPacket::MediaSessionUpdate(m) => Ok(ContinuityEvent::NowPlayingChanged(m)),
            ControlPacket::MediaControlCommand(c) => Ok(ContinuityEvent::MediaCommandReceived(c)),
            ControlPacket::DragOutOffer(drag) => {
                self.active_drag_offers.insert(drag.drag_id, drag.clone());
                Ok(ContinuityEvent::DragOutPromiseStarted(drag))
            }
            ControlPacket::Heartbeat(hb) => Ok(ContinuityEvent::HeartbeatReceived(hb)),
            ControlPacket::PowerStateUpdate(state) => {
                let thermal_budget =
                    ResourceBudgetMonitor::compute_thermal_budget(state.thermal_state);
                Ok(ContinuityEvent::PowerAndThermalUpdated {
                    state,
                    thermal_budget,
                })
            }
        }
    }

    fn enqueue_packet(
        &mut self,
        stream: ControlStreamId,
        packet: ControlPacket,
    ) -> CoreResult<()> {
        let stream_id = stream as u32;
        let seq = self.stream_sequences.entry(stream_id).or_insert(0);
        let current_seq = *seq;
        *seq = seq.wrapping_add(1);

        let frame = ControlFrame {
            stream_id,
            flags: 0,
            sequence: current_seq,
            packet,
        };
        let encoded = frame.encode()?;
        self.outbound_wire_queue.push_back(encoded);
        Ok(())
    }
}

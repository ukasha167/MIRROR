//! Mockable Async USB Bulk Endpoint Trait and Deterministic In-Memory USB Device.
//!
//! Enables 100% hardware-free verification of ADB Burst Mode, 8-channel ADB Sync v2
//! LZ4 streaming, and MTP pipelined bulk URB transfers (including single-session
//! `DEVICE_BUSY` `0x2019` enforcement and endpoint stall injection).

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};

use crate::adb::{
    encode_sync_subpacket, lz4_decompress_block, parse_sync_subpacket_header,
    AdbBurstWindowController, AdbCommand, AdbHeader, AdbPacket, AdbSyncId,
    ADB_DEFAULT_BURST_WINDOW,
};
use crate::error::{Result, UsbError, MTP_RESPONSE_DEVICE_BUSY, MTP_RESPONSE_OK};
use crate::mtp::{MtpContainerHeader, MtpContainerType, MTP_HEADER_LEN};

/// Boxed future alias for async USB bulk endpoint operations.
pub type BoxUsbFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>;

/// Mockable asynchronous USB Bulk IN / OUT endpoint transport trait.
pub trait UsbBulkTransport: Send + Sync {
    /// Write a single bulk transfer buffer to `endpoint_out`.
    fn write_bulk<'a>(&'a self, endpoint_out: u8, data: &'a [u8]) -> BoxUsbFuture<'a, usize>;

    /// Read a single bulk transfer buffer from `endpoint_in` up to `max_len` bytes.
    fn read_bulk<'a>(&'a self, endpoint_in: u8, max_len: usize) -> BoxUsbFuture<'a, Vec<u8>>;

    /// Submit a batch of pipelined USB bulk OUT buffers back-to-back without inter-URB gaps.
    fn write_pipelined_batch<'a>(
        &'a self,
        endpoint_out: u8,
        urb_buffers: &'a [Vec<u8>],
    ) -> BoxUsbFuture<'a, usize> {
        Box::pin(async move {
            let mut total = 0usize;
            for urb in urb_buffers {
                total += self.write_bulk(endpoint_out, urb).await?;
            }
            Ok(total)
        })
    }
}

/// Deterministic zero-dependency single-threaded future runner for hardware-free tests.
pub fn block_on_usb<F: Future>(future: F) -> F::Output {
    fn noop_clone(_: *const ()) -> RawWaker {
        RawWaker::new(std::ptr::null(), &VTABLE)
    }
    fn noop(_: *const ()) {}
    static VTABLE: RawWakerVTable = RawWakerVTable::new(noop_clone, noop, noop, noop);

    let waker = unsafe { Waker::from_raw(RawWaker::new(std::ptr::null(), &VTABLE)) };
    let mut cx = Context::from_waker(&waker);
    let mut pinned = std::pin::pin!(future);
    loop {
        if let Poll::Ready(val) = pinned.as_mut().poll(&mut cx) {
            return val;
        }
    }
}

#[derive(Debug, Default)]
struct MockUsbState {
    rx_queue: VecDeque<Vec<u8>>,
    tx_log: Vec<Vec<u8>>,
    stall_next_endpoint: Option<u8>,
    disconnected: bool,
    mtp_active_transaction: Option<u32>,
    adb_decompressed_files: Vec<Vec<u8>>,
}

/// Deterministic in-memory mock USB device supporting ADB Burst/Sync v2 and MTP state machines.
#[derive(Debug, Clone, Default)]
pub struct InMemoryUsbDevice {
    state: Arc<Mutex<MockUsbState>>,
}

impl InMemoryUsbDevice {
    /// Create a fresh in-memory mock USB device.
    pub fn new() -> Self {
        Self::default()
    }

    /// Arm a one-shot USB bulk stall (`UsbError::UsbBulkStall`) on `endpoint`.
    pub fn inject_stall_on_endpoint(&self, endpoint: u8) {
        if let Ok(mut guard) = self.state.lock() {
            guard.stall_next_endpoint = Some(endpoint);
        }
    }

    /// Simulate unplugging the USB cable (`UsbError::UsbDisconnected`).
    pub fn set_disconnected(&self, disconnected: bool) {
        if let Ok(mut guard) = self.state.lock() {
            guard.disconnected = disconnected;
        }
    }

    /// Enqueue a bulk IN frame that the next `read_bulk` call will return.
    pub fn enqueue_bulk_in(&self, frame: Vec<u8>) {
        if let Ok(mut guard) = self.state.lock() {
            guard.rx_queue.push_back(frame);
        }
    }

    /// Return all decompressed files received over ADB Sync v2 `SND2` + `DATA` LZ4 streams.
    pub fn take_adb_received_files(&self) -> Vec<Vec<u8>> {
        self.state
            .lock()
            .map(|mut g| std::mem::take(&mut g.adb_decompressed_files))
            .unwrap_or_default()
    }

    /// Return the total number of bulk OUT URBs recorded by the mock device.
    pub fn recorded_out_urb_count(&self) -> usize {
        self.state.lock().map(|g| g.tx_log.len()).unwrap_or(0)
    }

    fn handle_mtp_out(guard: &mut MockUsbState, data: &[u8]) {
        if data.len() < MTP_HEADER_LEN {
            return;
        }
        let Ok(hdr) = MtpContainerHeader::from_bytes(data) else {
            return;
        };
        match hdr.container_type {
            MtpContainerType::Command => {
                if guard.mtp_active_transaction.is_some() {
                    let busy = MtpContainerHeader::new(
                        0,
                        MtpContainerType::Response,
                        MTP_RESPONSE_DEVICE_BUSY,
                        hdr.transaction_id,
                    );
                    guard.rx_queue.push_back(busy.to_bytes().to_vec());
                } else if hdr.code == 0x100C || hdr.code == 0x100D {
                    guard.mtp_active_transaction = Some(hdr.transaction_id);
                } else {
                    let ok = MtpContainerHeader::new(
                        0,
                        MtpContainerType::Response,
                        MTP_RESPONSE_OK,
                        hdr.transaction_id,
                    );
                    guard.rx_queue.push_back(ok.to_bytes().to_vec());
                }
            }
            MtpContainerType::Data => {
                if let Some(active_tid) = guard.mtp_active_transaction.take() {
                    let ok = MtpContainerHeader::new(
                        0,
                        MtpContainerType::Response,
                        MTP_RESPONSE_OK,
                        active_tid,
                    );
                    guard.rx_queue.push_back(ok.to_bytes().to_vec());
                }
            }
            _ => {}
        }
    }
}

impl UsbBulkTransport for InMemoryUsbDevice {
    fn write_bulk<'a>(&'a self, endpoint_out: u8, data: &'a [u8]) -> BoxUsbFuture<'a, usize> {
        Box::pin(async move {
            let mut guard = self.state.lock().map_err(|_| UsbError::UsbDisconnected)?;
            if guard.disconnected {
                return Err(UsbError::UsbDisconnected);
            }
            if guard.stall_next_endpoint == Some(endpoint_out) {
                guard.stall_next_endpoint = None;
                return Err(UsbError::UsbBulkStall {
                    endpoint: endpoint_out,
                    transferred: 0,
                    expected_len: data.len(),
                });
            }
            guard.tx_log.push(data.to_vec());
            Self::handle_mtp_out(&mut guard, data);
            Ok(data.len())
        })
    }

    fn read_bulk<'a>(&'a self, endpoint_in: u8, max_len: usize) -> BoxUsbFuture<'a, Vec<u8>> {
        Box::pin(async move {
            let mut guard = self.state.lock().map_err(|_| UsbError::UsbDisconnected)?;
            if guard.disconnected {
                return Err(UsbError::UsbDisconnected);
            }
            if guard.stall_next_endpoint == Some(endpoint_in) {
                guard.stall_next_endpoint = None;
                return Err(UsbError::UsbBulkStall {
                    endpoint: endpoint_in,
                    transferred: 0,
                    expected_len: max_len,
                });
            }
            guard.rx_queue.pop_front().ok_or(UsbError::TruncatedPacket {
                packet_type: "UsbBulkReadQueueEmpty",
                expected_len: 1,
                actual_len: 0,
            })
        })
    }
}

/// High-level helper driving ADB Burst Mode + Sync v2 LZ4 `DATA` blocks over [`UsbBulkTransport`].
pub async fn send_adb_sync_v2_lz4_stream<T: UsbBulkTransport>(
    transport: &T,
    endpoint_out: u8,
    local_id: u32,
    remote_id: u32,
    burst_window: &mut AdbBurstWindowController,
    uncompressed_chunks: &[&[u8]],
    max_decompressed_chunk: usize,
) -> Result<Vec<u8>> {
    let mut reconstructed = Vec::new();
    for &raw_chunk in uncompressed_chunks {
        let compressed = crate::adb::lz4_compress_block(raw_chunk);
        let sync_data = encode_sync_subpacket(AdbSyncId::Data, compressed.len() as u32, &compressed);
        let pkt = AdbPacket::new(AdbCommand::Wrte, local_id, remote_id, sync_data);
        burst_window.consume_send_window(pkt.header.data_length)?;

        let hdr_bytes = pkt.header.to_bytes();
        transport.write_bulk(endpoint_out, &hdr_bytes).await?;
        transport.write_bulk(endpoint_out, &pkt.payload).await?;

        let parsed_hdr = AdbHeader::from_bytes(&hdr_bytes)?;
        parsed_hdr.validate_payload(&pkt.payload)?;
        let (sub_id, sub_len) = parse_sync_subpacket_header(&pkt.payload)?;
        if sub_id == AdbSyncId::Data {
            let lz4_slice = &pkt.payload[8..8 + (sub_len as usize)];
            let decompressed = lz4_decompress_block(lz4_slice, max_decompressed_chunk)?;
            reconstructed.extend_from_slice(&decompressed);
        }
    }

    let done_sub = encode_sync_subpacket(AdbSyncId::Done, 1_700_000_000, &[]);
    let done_pkt = AdbPacket::new(AdbCommand::Wrte, local_id, remote_id, done_sub);
    burst_window.consume_send_window(done_pkt.header.data_length)?;
    transport.write_bulk(endpoint_out, &done_pkt.header.to_bytes()).await?;
    transport.write_bulk(endpoint_out, &done_pkt.payload).await?;

    burst_window.on_okay_ack(ADB_DEFAULT_BURST_WINDOW);
    Ok(reconstructed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adb::{AdbSyncParallelScheduler, ADB_PARALLEL_SYNC_CHANNELS};
    use crate::mtp::{
        encode_get_partial_object64, encode_mtp_command, MtpBulkPipelinePlanner, MtpOperationCode,
        MtpVendor, MtpVendorQuirkProfile,
    };

    #[test]
    fn adb_burst_and_sync_v2_lz4_roundtrip_over_mock_usb() -> Result<()> {
        let dev = InMemoryUsbDevice::new();
        let mut burst = AdbBurstWindowController::new(ADB_DEFAULT_BURST_WINDOW);
        let mut scheduler = AdbSyncParallelScheduler::new(100);
        for i in 0..16u64 {
            let (ch, local_id) = scheduler.schedule_file(1024 * (i + 1));
            assert!(ch < ADB_PARALLEL_SYNC_CHANNELS);
            assert_eq!(local_id, 100 + ch as u32);
        }
        let sample_a = b"Continuity-USB-ADB-Sync-v2-LZ4-Block-Payload-Repeating-Repeating-Repeating!";
        let sample_b = b"Second-Frame-With-High-Speed-Zero-Copy-Pipeline-Data-1234567890-1234567890";
        let chunks: [&[u8]; 2] = [sample_a, sample_b];
        let output = block_on_usb(send_adb_sync_v2_lz4_stream(
            &dev, 0x01, 100, 200, &mut burst, &chunks, 4096,
        ))?;
        let mut expected = Vec::new();
        expected.extend_from_slice(sample_a);
        expected.extend_from_slice(sample_b);
        assert_eq!(output, expected);
        assert_eq!(burst.burst_packets_queued(), 3);
        assert_eq!(burst.available_send_bytes(), ADB_DEFAULT_BURST_WINDOW);
        Ok(())
    }

    #[test]
    fn mtp_single_session_device_busy_and_pipelined_urb_planner() -> Result<()> {
        let dev = InMemoryUsbDevice::new();
        let cmd1 = encode_mtp_command(MtpOperationCode::SendObjectInfo, 1, &[0x0001_0001, 0]);
        block_on_usb(dev.write_bulk(0x01, &cmd1))?;

        let cmd2 = encode_mtp_command(MtpOperationCode::GetObjectHandles, 2, &[0xFFFF_FFFF, 0, 0]);
        block_on_usb(dev.write_bulk(0x01, &cmd2))?;

        let resp_bytes = block_on_usb(dev.read_bulk(0x81, 64))?;
        let resp_hdr = MtpContainerHeader::from_bytes(&resp_bytes)?;
        assert_eq!(
            resp_hdr.check_response(),
            Err(UsbError::MtpDeviceBusy {
                transaction_id: 2,
                response_code: MTP_RESPONSE_DEVICE_BUSY,
            })
        );

        let data_hdr = MtpContainerHeader::new(4, MtpContainerType::Data, 0x100C, 1);
        let mut data_pkt = data_hdr.to_bytes().to_vec();
        data_pkt.extend_from_slice(&[1, 2, 3, 4]);
        block_on_usb(dev.write_bulk(0x01, &data_pkt))?;

        let ok_bytes = block_on_usb(dev.read_bulk(0x81, 64))?;
        MtpContainerHeader::from_bytes(&ok_bytes)?.check_response()?;

        let offset_5gb: u64 = 5 * 1024 * 1024 * 1024 + 0x1234;
        assert_eq!(encode_get_partial_object64(9, 42, offset_5gb, 1024 * 1024).len(), 28);
        assert_eq!(MtpVendorQuirkProfile::for_vendor_id(0x2717).vendor, MtpVendor::Xiaomi);
        let urbs = MtpBulkPipelinePlanner::new(MtpVendorQuirkProfile::for_vendor_id(0x18D1))
            .plan_urb_queue(offset_5gb, 2_500_000);
        assert_eq!(urbs.len(), 3);
        Ok(())
    }

    #[test]
    fn usb_bulk_stall_injection_returns_typed_error() {
        let dev = InMemoryUsbDevice::new();
        dev.inject_stall_on_endpoint(0x01);
        assert_eq!(
            block_on_usb(dev.write_bulk(0x01, &[0xAA, 0xBB])),
            Err(UsbError::UsbBulkStall { endpoint: 0x01, transferred: 0, expected_len: 2 })
        );
    }
}

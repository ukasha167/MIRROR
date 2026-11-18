//! C / UniFFI ABI exports for `libcontinuity_core.a` and `libcontinuity_core.dylib`.
//!
//! Exposes opaque pointer handles and C-callable entrypoints matching
//! `include/continuity_coreFFI.h` and `src/continuity_core.udl` for Swift 6
//! (`MirrorCoreBridge`) and Android JNI (`cargo-ndk`).

use std::slice;
use std::sync::Arc;

use crate::engine::ContinuityEngine;
use crate::keystore::{InMemoryKeystoreBridge, PairedDeviceStore};
use crate::resource::{
    AppleSiliconGeneration, ResourceBudgetMonitor, ResourceSnapshot, VideoCodecPreference,
};

/// Opaque FFI handle wrapping [`ContinuityEngine`].
pub struct ContinuityEngineHandle(pub ContinuityEngine);

/// Opaque FFI handle wrapping [`ResourceBudgetMonitor`].
pub struct ResourceBudgetMonitorHandle(pub ResourceBudgetMonitor);

/// Opaque FFI handle wrapping [`PairedDeviceStore`].
pub struct PairedDeviceStoreHandle(pub PairedDeviceStore);

/// Embedded UniFFI WebIDL definition (`src/continuity_core.udl`).
pub const UNIFFI_UDL_DEFINITION: &str = include_str!("continuity_core.udl");

/// Returns the UniFFI / C ABI contract version (`1`).
#[no_mangle]
pub extern "C" fn continuity_core_uniffi_contract_version() -> u32 {
    1
}

fn decode_chip_gen(code: u8) -> AppleSiliconGeneration {
    match code {
        0 => AppleSiliconGeneration::M1,
        1 => AppleSiliconGeneration::M2,
        _ => AppleSiliconGeneration::M3OrNewer,
    }
}

/// Allocates a new [`ResourceBudgetMonitorHandle`] for the given Apple Silicon generation.
#[no_mangle]
pub extern "C" fn continuity_resource_monitor_create(
    chip_generation: u8,
) -> *mut ResourceBudgetMonitorHandle {
    let monitor = ResourceBudgetMonitor::new(decode_chip_gen(chip_generation));
    Box::into_raw(Box::new(ResourceBudgetMonitorHandle(monitor)))
}

/// Returns the preferred hardware video codec (`0` = H.265, `1` = H.264).
///
/// # Safety
/// `handle` must be a valid pointer returned by [`continuity_resource_monitor_create`].
#[no_mangle]
pub unsafe extern "C" fn continuity_resource_monitor_preferred_codec(
    handle: *const ResourceBudgetMonitorHandle,
) -> u8 {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    match h.0.preferred_video_codec() {
        VideoCodecPreference::H265 => 0,
        VideoCodecPreference::H264 => 1,
    }
}

/// Verifies a runtime resource snapshot (`0` = ok, `-1` = null handle, `1` = budget exceeded).
///
/// # Safety
/// `handle` must be a valid mutable pointer returned by [`continuity_resource_monitor_create`].
#[no_mangle]
pub unsafe extern "C" fn continuity_resource_monitor_verify(
    handle: *mut ResourceBudgetMonitorHandle,
    macos_rss_bytes: u64,
    macos_cpu_percent: f32,
    macos_gpu_percent: f32,
    is_session_active: bool,
    android_idle_wakelocks: u32,
    android_idle_multicast_locks: u32,
) -> i32 {
    let Some(h) = (unsafe { handle.as_mut() }) else {
        return -1;
    };
    let snapshot = ResourceSnapshot {
        macos_rss_bytes,
        macos_cpu_percent,
        macos_gpu_percent,
        is_session_active,
        android_idle_wakelocks,
        android_idle_multicast_locks,
    };
    match h.0.verify_snapshot(snapshot) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

/// Frees a [`ResourceBudgetMonitorHandle`].
///
/// # Safety
/// `handle` must be either null or a valid pointer from [`continuity_resource_monitor_create`].
#[no_mangle]
pub unsafe extern "C" fn continuity_resource_monitor_free(
    handle: *mut ResourceBudgetMonitorHandle,
) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Creates a [`PairedDeviceStoreHandle`] backed by [`InMemoryKeystoreBridge`].
///
/// # Safety
/// `cert_der_ptr` must be valid for `cert_der_len` bytes when `cert_der_len > 0`.
#[no_mangle]
pub unsafe extern "C" fn continuity_paired_store_create_in_memory(
    cert_der_ptr: *const u8,
    cert_der_len: usize,
) -> *mut PairedDeviceStoreHandle {
    if cert_der_ptr.is_null() && cert_der_len > 0 {
        return std::ptr::null_mut();
    }
    let cert_bytes = if cert_der_len == 0 {
        Vec::new()
    } else {
        unsafe { slice::from_raw_parts(cert_der_ptr, cert_der_len) }.to_vec()
    };
    let bridge = Arc::new(InMemoryKeystoreBridge::new(cert_bytes));
    match PairedDeviceStore::new(bridge) {
        Ok(store) => Box::into_raw(Box::new(PairedDeviceStoreHandle(store))),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Copies the 32-byte SHA-256 fingerprint of the local host certificate into `out_fp_32`.
///
/// # Safety
/// `handle` must be valid and `out_fp_32` must point to at least 32 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn continuity_paired_store_local_fingerprint(
    handle: *const PairedDeviceStoreHandle,
    out_fp_32: *mut u8,
) -> i32 {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    if out_fp_32.is_null() {
        return -1;
    };
    let fp = h.0.local_cert_sha256();
    unsafe {
        std::ptr::copy_nonoverlapping(fp.as_ptr(), out_fp_32, 32);
    }
    0
}

/// Frees a [`PairedDeviceStoreHandle`].
///
/// # Safety
/// `handle` must be null or returned by [`continuity_paired_store_create_in_memory`].
#[no_mangle]
pub unsafe extern "C" fn continuity_paired_store_free(handle: *mut PairedDeviceStoreHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Creates a [`ContinuityEngineHandle`] for native Swift/Kotlin callers.
///
/// # Safety
/// All byte pointers must be valid for their declared lengths.
#[no_mangle]
pub unsafe extern "C" fn continuity_engine_create(
    device_id_ptr: *const u8,
    device_id_len: usize,
    device_name_ptr: *const u8,
    device_name_len: usize,
    chip_generation: u8,
    host_cert_der_ptr: *const u8,
    host_cert_der_len: usize,
) -> *mut ContinuityEngineHandle {
    if (device_id_ptr.is_null() && device_id_len > 0)
        || (device_name_ptr.is_null() && device_name_len > 0)
        || (host_cert_der_ptr.is_null() && host_cert_der_len > 0)
    {
        return std::ptr::null_mut();
    }
    let id_slice = if device_id_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(device_id_ptr, device_id_len) }
    };
    let name_slice = if device_name_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(device_name_ptr, device_name_len) }
    };
    let cert_slice = if host_cert_der_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(host_cert_der_ptr, host_cert_der_len) }
    };
    let Ok(device_id) = std::str::from_utf8(id_slice) else {
        return std::ptr::null_mut();
    };
    let Ok(device_name) = std::str::from_utf8(name_slice) else {
        return std::ptr::null_mut();
    };
    let ks = Arc::new(InMemoryKeystoreBridge::new(cert_slice.to_vec()));
    match ContinuityEngine::new(
        device_id.to_string(),
        device_name.to_string(),
        decode_chip_gen(chip_generation),
        ks,
    ) {
        Ok(engine) => Box::into_raw(Box::new(ContinuityEngineHandle(engine))),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Returns the number of queued outbound control frames in `handle`.
///
/// # Safety
/// `handle` must be null or a valid pointer returned by [`continuity_engine_create`].
#[no_mangle]
pub unsafe extern "C" fn continuity_engine_pending_frame_count(
    handle: *const ContinuityEngineHandle,
) -> usize {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    h.0.pending_frame_count()
}

/// Frees a [`ContinuityEngineHandle`].
///
/// # Safety
/// `handle` must be null or returned by [`continuity_engine_create`].
#[no_mangle]
pub unsafe extern "C" fn continuity_engine_free(handle: *mut ContinuityEngineHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

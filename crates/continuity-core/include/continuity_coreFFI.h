#ifndef CONTINUITY_CORE_FFI_H
#define CONTINUITY_CORE_FFI_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ContinuityEngineHandle ContinuityEngineHandle;
typedef struct ResourceBudgetMonitorHandle ResourceBudgetMonitorHandle;
typedef struct PairedDeviceStoreHandle PairedDeviceStoreHandle;

/// Returns the UniFFI / FFI contract version (1).
uint32_t continuity_core_uniffi_contract_version(void);

/// Creates a ResourceBudgetMonitor for the given Apple Silicon generation (0 = M1, 1 = M2, 2 = M3+).
ResourceBudgetMonitorHandle* continuity_resource_monitor_create(uint8_t chip_generation);

/// Returns preferred hardware video codec (0 = H265, 1 = H264).
uint8_t continuity_resource_monitor_preferred_codec(const ResourceBudgetMonitorHandle* handle);

/// Verifies a resource snapshot; returns 0 on success, non-zero on budget violation.
int32_t continuity_resource_monitor_verify(
    ResourceBudgetMonitorHandle* handle,
    uint64_t macos_rss_bytes,
    float macos_cpu_percent,
    float macos_gpu_percent,
    bool is_session_active,
    uint32_t android_idle_wakelocks,
    uint32_t android_idle_multicast_locks
);

/// Frees a ResourceBudgetMonitorHandle.
void continuity_resource_monitor_free(ResourceBudgetMonitorHandle* handle);

/// Creates an in-memory PairedDeviceStore seeded with the host X.509 DER certificate.
PairedDeviceStoreHandle* continuity_paired_store_create_in_memory(
    const uint8_t* cert_der_ptr,
    size_t cert_der_len
);

/// Writes the 32-byte SHA-256 fingerprint of the host certificate into out_fp_32.
int32_t continuity_paired_store_local_fingerprint(
    const PairedDeviceStoreHandle* handle,
    uint8_t* out_fp_32
);

/// Frees a PairedDeviceStoreHandle.
void continuity_paired_store_free(PairedDeviceStoreHandle* handle);

/// Creates a ContinuityEngine instance with an in-memory keystore for native bridging.
ContinuityEngineHandle* continuity_engine_create(
    const uint8_t* device_id_ptr,
    size_t device_id_len,
    const uint8_t* device_name_ptr,
    size_t device_name_len,
    uint8_t chip_generation,
    const uint8_t* host_cert_der_ptr,
    size_t host_cert_der_len
);

/// Returns the number of queued outbound control frames on the engine.
size_t continuity_engine_pending_frame_count(const ContinuityEngineHandle* handle);

/// Frees a ContinuityEngineHandle.
void continuity_engine_free(ContinuityEngineHandle* handle);

#ifdef __cplusplus
}
#endif

#endif /* CONTINUITY_CORE_FFI_H */

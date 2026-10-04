#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Experimental ABI v1: success 0; invalid argument -1; invalid/stale handle -2;
// buffer too small -3; stale/inactive generation/stream -4; terminal queue overflow -5.
// Caller supplies valid accessible buffers; all input is borrowed only for the call.
// Never unload the Swift module. Destroy releases the host; close queues protocol CLOSE.
// Calls are serialized internally, with at most 16 hosts. Handles are never reused.
uint32_t lr_host_abi_version(void);
uint64_t lr_host_create(uint64_t pairing_id, const uint8_t* psk, int32_t psk_bytes, const uint8_t* reset_key, int32_t reset_bytes, int32_t bitrate, int32_t fps, int32_t fec_percent);
int32_t lr_host_destroy(uint64_t host);
int32_t lr_host_receive(uint64_t host, const uint8_t* data, int32_t size, const uint8_t* ip, int32_t ip_bytes, uint16_t port, uint64_t now_micros, uint64_t unix_seconds);
int32_t lr_host_tick(uint64_t host, uint64_t now_micros);
int32_t lr_host_close(uint64_t host, uint64_t now_micros);
uint64_t lr_host_generation(uint64_t host);
// No wakeup is UINT64_MAX. Use a monotonic, nondecreasing microsecond clock.
int32_t lr_host_next_wakeup(uint64_t host, uint64_t now_micros, uint64_t* next_micros);
// Returns written size, zero if empty, or a negative code. Too small does not consume.
// Datagram record: ip_bytes:u8, ip:4|16 bytes, port:u16 BE, original UDP datagram.
int32_t lr_host_pop_datagram(uint64_t host, uint8_t* out, int32_t capacity, int32_t* required);
// Event: kind:u8, generation:u64 BE, body. See host-bridge-progress.md for bodies.
int32_t lr_host_pop_event(uint64_t host, uint8_t* out, int32_t capacity, int32_t* required);
// Payload: HEVC NALs with u32 BE lengths; config: VPS/SPS/PPS with u32 BE lengths.
// At most 4 MiB payload and 65532 config bytes. IDR requires config; P forbids it.
// Capture age is at most 100 ms. Generation changes at session start and pause.
int32_t lr_host_submit(uint64_t host, uint64_t generation, uint8_t stream, const uint8_t* payload, int32_t payload_bytes, const uint8_t* config, int32_t config_bytes, int32_t idr, uint64_t capture_micros, uint64_t now_micros);
// Optional bounded durations; the original submit ABI remains available.
int32_t lr_host_submit_timed(uint64_t host, uint64_t generation, uint8_t stream, const uint8_t* payload, int32_t payload_bytes, const uint8_t* config, int32_t config_bytes, int32_t idr, uint64_t capture_micros, uint64_t now_micros, uint32_t capture_duration_us, uint32_t encode_duration_us, uint64_t sample_id);
int32_t lr_host_control(uint64_t host, uint64_t generation, const uint8_t* message, int32_t bytes, uint64_t now_micros);
#ifdef __cplusplus
}
#endif

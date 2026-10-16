#ifndef LIGHTRAY_H
#define LIGHTRAY_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1. Roles: 1 host control, 2 client. 0 handles/pointers indicate failure. */
uint32_t lr_abi_version(void);
uint64_t lr_create(uint32_t role);
/* Borrowed JSON input; 0 success, -1 invalid, -2 queue full. */
int32_t lr_command(uint64_t handle, const uint8_t *json, uint32_t length);
/* 0 event, 1 empty, 2 insufficient capacity with required length; event retained. */
int32_t lr_poll(uint64_t handle, uint8_t *buffer, uint32_t capacity, uint32_t *length);
/* One transferred COM reference; attach on the UI thread, then Release. */
void *lr_swap_chain(uint64_t handle, uint8_t stream);
int32_t lr_resize(uint64_t handle, uint8_t stream, uint32_t width, uint32_t height);
/* Detach every SwapChainPanel first. Releases workers and invalidates the handle. */
void lr_destroy(uint64_t handle);
#ifdef __cplusplus
}
#endif
#endif

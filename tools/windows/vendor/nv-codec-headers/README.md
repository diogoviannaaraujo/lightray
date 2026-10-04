# NVENC API header

`nvEncodeAPI.h` is the NVIDIA NVENC C interface, pinned from the nv-codec-headers tag `n13.0.19.0`.
Source: https://github.com/FFmpeg/nv-codec-headers/blob/n13.0.19.0/include/ffnvcodec/nvEncodeAPI.h
SHA-256: `4fe4094541ef0f8a13249d97a8692dc5f835a6e9dd42eeadb3e2f7321d54dc7e`.
The NVIDIA copyright and MIT permission notice are preserved in the header.
The permission applies to this header; it does not grant redistribution rights for driver binaries or unrelated SDK components.

The probe loads `nvEncodeAPI64.dll` exclusively from Windows System32, supplied by the installed NVIDIA driver.
It uses NVENC directly and does not link or invoke FFmpeg for encoding.
No CUDA toolkit or driver DLL is vendored here.
Driver API compatibility is checked before creating an encoding session; unsupported devices fail explicitly without a software encoder fallback.

#pragma once
#include <array>
#include <cstdint>
#include <limits>
#include <span>
#include <stdexcept>
#include <vector>

namespace lightray {
using Bytes = std::vector<std::uint8_t>;
struct AccessUnit {
    Bytes payload;
    Bytes config;
    bool idr = false;
};
inline void append_length(Bytes& output, std::size_t length) {
    if (length > std::numeric_limits<std::uint32_t>::max()) throw std::runtime_error("NAL too large");
    for (int shift : {24, 16, 8, 0}) output.push_back(static_cast<std::uint8_t>(length >> shift));
}
// Convert one complete NVENC access unit; this is not a streaming Annex B parser.
inline AccessUnit from_annex_b(std::span<const std::uint8_t> input) {
    if (input.empty() || input.size() > 32 * 1024 * 1024) throw std::runtime_error("Invalid access unit size");
    auto prefix = [&](std::size_t at) -> std::size_t {
        if (at + 3 <= input.size() && input[at] == 0 && input[at + 1] == 0) {
            if (input[at + 2] == 1) return 3;
            if (at + 4 <= input.size() && input[at + 2] == 0 && input[at + 3] == 1) return 4;
        }
        return 0;
    };
    std::size_t at = 0;
    while (at < input.size() && !prefix(at)) {
        if (input[at++] != 0) throw std::runtime_error("Missing Annex B start code");
    }
    AccessUnit result;
    std::array<Bytes, 3> sets;
    bool has_vcl = false;
    bool has_predicted = false;
    while (at < input.size()) {
        const auto start = at + prefix(at);
        at = start;
        while (at < input.size() && !prefix(at)) ++at;
        auto end = at;
        while (end > start && input[end - 1] == 0) --end;
        if (end - start < 2 || (input[start] & 0x80) || (input[start + 1] & 7) == 0) throw std::runtime_error("Invalid HEVC NAL header");
        const auto type = (input[start] >> 1) & 63;
        if (type <= 31) {
            has_vcl = true;
            if (type == 19 || type == 20) result.idr = true;
            else if (type <= 9) has_predicted = true;
            else throw std::runtime_error("Unsupported recovery picture; expected IDR or trailing picture");
        }
        if (type >= 32 && type <= 34) {
            auto& set = sets[type - 32];
            if (!set.empty()) throw std::runtime_error("Duplicate parameter set");
            set.assign(input.begin() + start, input.begin() + end);
        }
        append_length(result.payload, end - start);
        result.payload.insert(result.payload.end(), input.begin() + start, input.begin() + end);
    }
    if (!has_vcl || (result.idr && has_predicted)) throw std::runtime_error("Invalid picture access unit");
    if (result.idr) {
        for (const auto& set : sets) {
            if (set.empty()) throw std::runtime_error("IDR missing VPS/SPS/PPS");
            append_length(result.config, set.size());
            result.config.insert(result.config.end(), set.begin(), set.end());
        }
        if (result.config.size() > 65532) throw std::runtime_error("Codec configuration exceeds frame extension limit");
    }
    return result;
}
}

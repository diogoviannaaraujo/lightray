#include "hevc_annexb.hpp"
#include <iostream>

int main() {
    try {
        const lightray::Bytes predicted{0,0,1,2,1,128};
        const auto p = lightray::from_annex_b(predicted);
        if (p.idr || !p.config.empty() || p.payload != lightray::Bytes{0,0,0,3,2,1,128}) throw std::runtime_error("Predicted conversion failed");
        const lightray::Bytes idr{0,0,0,1,64,1,128,0,0,1,66,1,128,0,0,0,1,68,1,128,0,0,1,38,1,128,0,0};
        const auto i = lightray::from_annex_b(idr);
        if (!i.idr || i.config.size() != 21 || i.payload.size() != 28 || i.config[4] != 64 || i.config[11] != 66 || i.config[18] != 68) throw std::runtime_error("IDR conversion failed");
        const std::vector<lightray::Bytes> invalid{{}, {1,2,3}, {0,0,0}, {0,0,1,2}, {0,0,1,130,1,128}, {0,0,1,2,0,128}, {0,0,1,38,1,128}, {0,0,1,64,1,128}, {0,0,1,42,1,128}, {0,0,1,2,1,128,0,0,1}, {0,0,1,0,0,1,2,1,128}};
        for (const auto& bytes : invalid) {
            bool rejected = false;
            try { static_cast<void>(lightray::from_annex_b(bytes)); } catch (const std::runtime_error&) { rejected = true; }
            if (!rejected) throw std::runtime_error("Malformed access unit accepted");
        }
        auto duplicate = idr;
        duplicate.insert(duplicate.end(), {0,0,1,64,1,128});
        bool rejected = false;
        try { static_cast<void>(lightray::from_annex_b(duplicate)); } catch (const std::runtime_error&) { rejected = true; }
        if (!rejected) throw std::runtime_error("Duplicate parameter set accepted");
        std::cout << "{\"status\":\"passed\",\"cases\":14}\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

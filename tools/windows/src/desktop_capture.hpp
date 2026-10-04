#pragma once
#include "capture_recovery.hpp"
#include "windows_display.hpp"
#include "wgc_capture.hpp"
#include <cstdint>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdexcept>
#include <string>
#include <memory>
#include <wrl/client.h>
namespace lightray {
inline void capture_hr(HRESULT status, const char *action) {
    if (FAILED(status))
        throw std::runtime_error(std::string(action) + " HRESULT " + std::to_string(status));
}
class DesktopCapture {
    // Keep the apartment alive across capture-session recreation and until all COM objects die.
    std::unique_ptr<CaptureApartment> apartment_;
    Microsoft::WRL::ComPtr<IDXGIOutputDuplication> duplication_;
    Microsoft::WRL::ComPtr<ID3D11VideoDevice> video_;
    Microsoft::WRL::ComPtr<ID3D11VideoContext> video_context_;
    Microsoft::WRL::ComPtr<ID3D11VideoProcessorEnumerator> enumerator_;
    Microsoft::WRL::ComPtr<ID3D11VideoProcessor> processor_;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> output_;
    Microsoft::WRL::ComPtr<ID3D11VideoProcessorOutputView> output_view_;
    bool ready_ = false;
    CaptureRecovery recovery_;
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter_;
    DXGI_OUTDUPL_DESC original_{};
    std::unique_ptr<WgcCapture> wgc_;
    bool use_wgc_ = false;
    void convert(ID3D11Texture2D *texture) {
        D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC desc{};
        desc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
        Microsoft::WRL::ComPtr<ID3D11VideoProcessorInputView> view;
        capture_hr(video_->CreateVideoProcessorInputView(texture, enumerator_.Get(), &desc, &view), "Video input view");
        D3D11_VIDEO_PROCESSOR_STREAM stream{};
        stream.Enable = TRUE;
        stream.pInputSurface = view.Get();
        capture_hr(video_context_->VideoProcessorBlt(processor_.Get(), output_view_.Get(), 0, 1, &stream), "GPU BGRA to NV12");
        if (!recovery_.ready()) ++epoch;
        recovery_.frame();
        ready_ = true;
    }
    HRESULT recreate() {
        capture_hr(device_->GetDeviceRemovedReason(), "Capture device lost; host restart required");
        Microsoft::WRL::ComPtr<IDXGIOutput> output;
        auto status = adapter_->EnumOutputs(0, &output);
        if (FAILED(status)) return status;
        DXGI_OUTPUT_DESC desc{};
        capture_hr(output->GetDesc(&desc), "Describe recovered output");
        if (!desc.AttachedToDesktop) return DXGI_ERROR_NOT_CURRENTLY_AVAILABLE;
        if (!EqualRect(&desktop, &desc.DesktopCoordinates) || desc.Rotation != DXGI_MODE_ROTATION_IDENTITY)
            throw std::runtime_error("Capture geometry changed; host restart required");
        if (use_wgc_) {
            try { wgc_ = std::make_unique<WgcCapture>(device_.Get(), desc.Monitor, source_width, source_height); return S_OK; }
            catch (const winrt::hresult_error &error) { return error.code().value; }
        }
        Microsoft::WRL::ComPtr<IDXGIOutput1> output1;
        capture_hr(output.As(&output1), "Query recovered output");
        Microsoft::WRL::ComPtr<IDXGIOutputDuplication> next;
        status = output1->DuplicateOutput(device_.Get(), &next);
        if (FAILED(status)) return status;
        DXGI_OUTDUPL_DESC mode{};
        next->GetDesc(&mode);
        if (mode.ModeDesc.Width != original_.ModeDesc.Width || mode.ModeDesc.Height != original_.ModeDesc.Height || mode.ModeDesc.Format != original_.ModeDesc.Format || mode.Rotation != original_.Rotation)
            throw std::runtime_error("Capture format changed; host restart required");
        duplication_ = next;
        source_refresh_mhz = refresh_millihertz(mode.ModeDesc.RefreshRate.Numerator, mode.ModeDesc.RefreshRate.Denominator);
        if (mode.ModeDesc.RefreshRate.Denominator) source_refresh_hz = double(mode.ModeDesc.RefreshRate.Numerator) / mode.ModeDesc.RefreshRate.Denominator;
        return S_OK;
    }

  public:
    RECT desktop{};
    unsigned width = 0, height = 0, source_width = 0, source_height = 0;
    std::uint32_t source_refresh_mhz = 0;
    bool primary = false;
    double source_refresh_hz = 0;
    std::uint64_t desktop_updates = 0, cached_frames = 0, epoch = 0, recreations = 0, losses = 0, acquisition_timeouts = 0;
    HRESULT last_recreate_status = S_OK;
    DesktopCapture(ID3D11Device *device, ID3D11DeviceContext *context, IDXGIAdapter1 *adapter, unsigned maximum_width = 1920, unsigned fps = 30, bool use_wgc = false) : device_(device), adapter_(adapter), use_wgc_(use_wgc) {
        Microsoft::WRL::ComPtr<IDXGIOutput> output;
        capture_hr(adapter->EnumOutputs(0, &output), "Select output");
        DXGI_OUTPUT_DESC desc{};
        capture_hr(output->GetDesc(&desc), "Describe output");
        if (!desc.AttachedToDesktop || desc.Rotation != DXGI_MODE_ROTATION_IDENTITY)
            throw std::runtime_error("Initial host requires an attached unrotated output");
        desktop = desc.DesktopCoordinates;
        source_width = static_cast<unsigned>(desktop.right - desktop.left);
        source_height = static_cast<unsigned>(desktop.bottom - desktop.top);
        if (!source_width || !source_height || source_width > 65535 || source_height > 65535) throw std::runtime_error("Unsupported desktop dimensions");
        MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
        capture_hr(GetMonitorInfoW(desc.Monitor, &monitor) ? S_OK : HRESULT_FROM_WIN32(GetLastError()), "Describe capture monitor");
        primary = (monitor.dwFlags & MONITORINFOF_PRIMARY) != 0;
        width = source_width > maximum_width ? maximum_width : source_width;
        height = static_cast<unsigned>(static_cast<unsigned long long>(source_height) * width / source_width) & ~1u;
        width &= ~1u;
        if (use_wgc_) {
            apartment_ = std::make_unique<CaptureApartment>();
            DEVMODEW mode{}; mode.dmSize = sizeof(mode);
            if (EnumDisplaySettingsExW(desc.DeviceName, ENUM_CURRENT_SETTINGS, &mode, 0) && mode.dmDisplayFrequency > 1) {
                source_refresh_hz = mode.dmDisplayFrequency;
                source_refresh_mhz = refresh_millihertz(mode.dmDisplayFrequency, 1);
            }
            wgc_ = std::make_unique<WgcCapture>(device, desc.Monitor, source_width, source_height);
        } else {
            Microsoft::WRL::ComPtr<IDXGIOutput1> output1;
            capture_hr(output.As(&output1), "Query output duplication");
            HRESULT duplicate_status = E_FAIL;
            for (unsigned attempt = 0; attempt < 50; ++attempt) {
                duplicate_status = output1->DuplicateOutput(device, &duplication_);
                if (duplicate_status != DXGI_ERROR_MODE_CHANGE_IN_PROGRESS) break;
                Sleep(100);
            }
            capture_hr(duplicate_status, "Duplicate desktop (interactive unlocked session required)");
            DXGI_OUTDUPL_DESC duplicated{};
            duplication_->GetDesc(&duplicated);
            original_ = duplicated;
            source_refresh_mhz = refresh_millihertz(duplicated.ModeDesc.RefreshRate.Numerator, duplicated.ModeDesc.RefreshRate.Denominator);
            if (duplicated.ModeDesc.RefreshRate.Denominator)
                source_refresh_hz = double(duplicated.ModeDesc.RefreshRate.Numerator) / duplicated.ModeDesc.RefreshRate.Denominator;
        }
        capture_hr(device->QueryInterface(IID_PPV_ARGS(&video_)), "Video device");
        capture_hr(context->QueryInterface(IID_PPV_ARGS(&video_context_)), "Video context");
        D3D11_VIDEO_PROCESSOR_CONTENT_DESC content{};
        content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
        content.InputWidth = source_width;
        content.InputHeight = source_height;
        content.OutputWidth = width;
        content.OutputHeight = height;
        content.InputFrameRate = {60, 1};
        content.OutputFrameRate = {fps, 1};
        content.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
        capture_hr(video_->CreateVideoProcessorEnumerator(&content, &enumerator_), "Video processor enumerator");
        UINT support = 0;
        capture_hr(enumerator_->CheckVideoProcessorFormat(DXGI_FORMAT_NV12, &support), "NV12 support");
        if (!(support & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT))
            throw std::runtime_error("GPU NV12 conversion unavailable");
        capture_hr(video_->CreateVideoProcessor(enumerator_.Get(), 0, &processor_), "Video processor");
        D3D11_TEXTURE2D_DESC texture{};
        texture.Width = width;
        texture.Height = height;
        texture.MipLevels = texture.ArraySize = texture.SampleDesc.Count = 1;
        texture.Format = DXGI_FORMAT_NV12;
        texture.Usage = D3D11_USAGE_DEFAULT;
        texture.BindFlags = D3D11_BIND_RENDER_TARGET;
        capture_hr(device->CreateTexture2D(&texture, nullptr, &output_), "NV12 output texture");
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC view{};
        view.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        capture_hr(video_->CreateVideoProcessorOutputView(output_.Get(), enumerator_.Get(), &view, &output_view_), "Video output view");
        RECT source = {0, 0, static_cast<LONG>(source_width), static_cast<LONG>(source_height)}, destination = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
        video_context_->VideoProcessorSetStreamFrameFormat(processor_.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
        video_context_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &source);
        video_context_->VideoProcessorSetStreamDestRect(processor_.Get(), 0, TRUE, &destination);
        video_context_->VideoProcessorSetOutputTargetRect(processor_.Get(), TRUE, &destination);
        video_context_->VideoProcessorSetStreamAutoProcessingMode(processor_.Get(), 0, FALSE);
        D3D11_VIDEO_PROCESSOR_COLOR_SPACE input_color{}, output_color{};
        input_color.RGB_Range = 0;
        input_color.YCbCr_Matrix = 1;
        input_color.Nominal_Range = 2;
        output_color.YCbCr_Matrix = 1;
        output_color.Nominal_Range = 1;
        video_context_->VideoProcessorSetStreamColorSpace(processor_.Get(), 0, &input_color);
        video_context_->VideoProcessorSetOutputColorSpace(processor_.Get(), &output_color);
    }
    bool ready() const { return recovery_.ready() && ready_; }
    // Also used by the explicit laboratory fault hook; it releases the real DXGI interface.
    void invalidate(std::uint64_t now) {
        ready_ = false;
        duplication_.Reset();
        wgc_.reset();
        recovery_.lost(now);
        ++losses;
    }
    ID3D11Texture2D *acquire(std::uint64_t now) {
        const auto action = recovery_.action(now);
        if (action == CaptureRecovery::Action::fail) throw std::runtime_error("Capture unavailable: recovery deadline or attempt budget exhausted; acquisition_timeouts=" + std::to_string(acquisition_timeouts) + " recreations=" + std::to_string(recreations) + " losses=" + std::to_string(losses) + " last_recreate_hresult=" + std::to_string(last_recreate_status));
        if (action == CaptureRecovery::Action::wait) return nullptr;
        if (action == CaptureRecovery::Action::recreate) {
            ready_ = false;
            duplication_.Reset();
            wgc_.reset();
            const auto status = recreate();
            last_recreate_status = status;
            ++recreations;
            recovery_.attempted(now, SUCCEEDED(status));
            if (FAILED(status) && status != DXGI_ERROR_ACCESS_LOST && status != DXGI_ERROR_MODE_CHANGE_IN_PROGRESS && status != DXGI_ERROR_NOT_CURRENTLY_AVAILABLE && status != DXGI_ERROR_NOT_FOUND && status != E_ACCESSDENIED && status != DXGI_ERROR_ACCESS_DENIED)
                capture_hr(status, "Recreate desktop duplication");
            return nullptr;
        }
        if (use_wgc_) {
            auto texture = wgc_->next();
            if (!texture) { ++acquisition_timeouts; if (ready_) ++cached_frames; return ready_ ? output_.Get() : nullptr; }
            try { convert(texture.Get()); ++desktop_updates; }
            catch (...) { wgc_->release(); throw; }
            wgc_->release();
            return output_.Get();
        }
        DXGI_OUTDUPL_FRAME_INFO info{};
        Microsoft::WRL::ComPtr<IDXGIResource> resource;
        const auto status = duplication_->AcquireNextFrame(0, &info, &resource);
        if (status == DXGI_ERROR_WAIT_TIMEOUT) {
            ++acquisition_timeouts;
            if (ready_)
                ++cached_frames;
            return ready_ ? output_.Get() : nullptr;
        }
        if (status == DXGI_ERROR_ACCESS_LOST) { invalidate(now); return nullptr; }
        capture_hr(status, "Acquire desktop frame");
        try {
            Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
            capture_hr(resource.As(&texture), "Query desktop texture");
            convert(texture.Get());
            if (info.LastPresentTime.QuadPart)
                ++desktop_updates;
            else
                ++cached_frames;
        } catch (...) {
            duplication_->ReleaseFrame();
            throw;
        }
        const auto released = duplication_->ReleaseFrame();
        if (released == DXGI_ERROR_ACCESS_LOST) { invalidate(now); return nullptr; }
        capture_hr(released, "Release desktop frame");
        return output_.Get();
    }
};
} // namespace lightray

using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;

namespace Lightray;

// ABI v1. All JSON and event memory is copied; GPU pointers transfer one COM reference.
internal sealed class NativeBridge : IDisposable
{
    [DllImport("lightray_runtime.dll", CallingConvention = CallingConvention.Cdecl)] private static extern uint lr_abi_version();
    [DllImport("lightray_runtime.dll", CallingConvention = CallingConvention.Cdecl)] private static extern ulong lr_create(uint role);
    [DllImport("lightray_runtime.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int lr_command(ulong handle, [In] byte[] json, uint length);
    [DllImport("lightray_runtime.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int lr_poll(ulong handle, [Out] byte[] buffer, uint capacity, out uint length);
    [DllImport("lightray_runtime.dll", CallingConvention = CallingConvention.Cdecl)] private static extern nint lr_swap_chain(ulong handle, byte stream);
    [DllImport("lightray_runtime.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int lr_resize(ulong handle, byte stream, uint width, uint height);
    [DllImport("lightray_runtime.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void lr_destroy(ulong handle);
    private ulong handle;
    private byte[] buffer = new byte[64 * 1024];
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(25) };
    public event Action<JsonElement>? Event;
    public NativeBridge(uint role)
    {
        if (lr_abi_version() != 1) throw new InvalidOperationException("The installed Rust library has an incompatible version.");
        handle = lr_create(role);
        if (handle == 0) throw new InvalidOperationException("The Rust engine could not start.");
        timer.Tick += (_, _) => Poll();
        timer.Start();
    }
    public void Send(object command)
    {
        if (handle == 0) return;
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(command);
        if (lr_command(handle, bytes, checked((uint)bytes.Length)) != 0)
            Event?.Invoke(JsonSerializer.SerializeToElement(new { kind = "error", message = "The engine command queue is full or unavailable. Remote input has been released." }));
    }
    private void Poll()
    {
        if (handle == 0) return;
        for (int i = 0; i < 32; i++)
        {
            int status = lr_poll(handle, buffer, (uint)buffer.Length, out uint length);
            if (status == 1) break;
            if (status == 2 && length <= 1024 * 1024) { buffer = new byte[length]; continue; }
            if (status != 0) break;
            using var json = JsonDocument.Parse(buffer.AsMemory(0, checked((int)length)));
            Event?.Invoke(json.RootElement.Clone());
        }
    }
    public nint SwapChain(byte stream) => handle == 0 ? 0 : lr_swap_chain(handle, stream);
    public void Resize(byte stream, uint width, uint height) { if (handle != 0 && width > 0 && height > 0) lr_resize(handle, stream, width, height); }
    public void Dispose()
    {
        timer.Stop();
        ulong old = handle; handle = 0;
        if (old != 0) lr_destroy(old);
    }
}

internal static class JsonFields
{
    public static string Text(this JsonElement value, string key, string fallback = "") => value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() ?? fallback : fallback;
    public static int Number(this JsonElement value, string key, int fallback = 0) => value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.Number && item.TryGetInt32(out int result) ? result : fallback;
    public static uint Unsigned(this JsonElement value, string key, uint fallback = 0) => value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.Number && item.TryGetUInt32(out uint result) ? result : fallback;
    public static bool Flag(this JsonElement value, string key) => value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.True;
}

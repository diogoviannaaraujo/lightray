using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Windowing;
using System.Runtime.InteropServices;
using System.Text.Json;
using Windows.System;
using Windows.UI.Core;

namespace Lightray.Client;

[ComImport, Guid("63AAD0B8-7C24-40FF-85A8-640D944CC325"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ISwapChainPanelNative { [PreserveSig] int SetSwapChain(nint swapChain); }

internal sealed class StreamWindow : Window
{
    private readonly NativeBridge native;
    private readonly byte stream;
    private readonly VideoPanel panel = new() { IsTabStop = true };
    private readonly TextBlock stats = new() { Text = "Waiting for video…", Margin = new Thickness(12), Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White), IsHitTestVisible = false };
    private readonly ComboBox displayChoice = new() { MinWidth = 180, PlaceholderText = "Display" };
    private readonly HashSet<ushort> heldKeys = new();
    private readonly HashSet<int> heldButtons = new();
    private readonly ToggleMenuFlyoutItem showStats = new() { Text = "Statistics", IsChecked = true };
    private readonly ToggleMenuFlyoutItem swapItem = new() { Text = "Swap Control and Command/Windows" };
    private readonly ToggleMenuFlyoutItem cursorItem = new() { Text = "Show local pointer" };
    private readonly Action closed;
    private readonly Action? attached;
    private bool live, inputEnabled, updatingDisplays, closing, fullscreen, swap, localCursor;
    private int videoWidth = 1920, videoHeight = 1080;
    public uint Display { get; set; }
    private ISwapChainPanelNative? nativePanel;
    public StreamWindow(NativeBridge native, byte stream, uint display, Action closed, Action? attached = null)
    {
        this.native = native; this.stream = stream; Display = display; this.closed = closed; this.attached = attached;
        Title = "Lightray · Remote display"; AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 720));
        var root = new Grid(); root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); root.RowDefinitions.Add(new RowDefinition());
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(8) };
        controls.Children.Add(Button("Release input", (_, _) => Release()));
        controls.Children.Add(Button("Resume input", (_, _) => Resume()));
        controls.Children.Add(Button("Full screen", (_, _) => { Release(); fullscreen = !fullscreen; AppWindow.SetPresenter(fullscreen ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Default); }));
        controls.Children.Add(displayChoice);
        var menu = new MenuFlyout();
        showStats.Click += (_, _) => { stats.Visibility = showStats.IsChecked ? Visibility.Visible : Visibility.Collapsed; Preferences(); }; menu.Items.Add(showStats);
        swapItem.Click += (_, _) => { Release(); swap = swapItem.IsChecked; Preferences(); }; menu.Items.Add(swapItem);
        cursorItem.Click += (_, _) => { localCursor = cursorItem.IsChecked; UpdateCursor(); Preferences(); }; menu.Items.Add(cursorItem);
        var textItem = new MenuFlyoutItem { Text = "Send text…" }; textItem.Click += async (_, _) => {
            Release(); var text = new TextBox { AcceptsReturn = true, MaxLength = 256 };
            var dialog = new ContentDialog { Title = "Send committed text", Content = text, PrimaryButtonText = "Send", CloseButtonText = "Cancel", XamlRoot = root.XamlRoot };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) native.Send(new { command = "text", text = text.Text });
        }; menu.Items.Add(textItem);
        var add = new MenuFlyoutItem { Text = "Open selected display in another window" }; add.Click += (_, _) => {
            if (displayChoice.SelectedItem is ComboBoxItem item && item.Tag is uint id) native.Send(new { command = "open_display", display = id });
        }; menu.Items.Add(add);
        var disconnect = new MenuFlyoutItem { Text = "Disconnect" }; disconnect.Click += (_, _) => { Release(); native.Send(new { command = "disconnect" }); Close(); }; menu.Items.Add(disconnect);
        menu.Opening += (_, _) => Release();
        controls.Children.Add(new DropDownButton { Content = "Session", Flyout = menu });
        root.Children.Add(new ScrollViewer { Content = controls, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled });
        var video = new Grid { Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Black) }; video.Children.Add(panel); video.Children.Add(stats); Grid.SetRow(video, 1); root.Children.Add(video); Content = root;
        displayChoice.SelectionChanged += (_, _) => {
            if (!updatingDisplays && displayChoice.SelectedItem is ComboBoxItem item && item.Tag is uint id && id != Display)
            { Release(); native.Send(new { command = "select_display", stream, display = id }); }
        };
        displayChoice.DropDownOpened += (_, _) => Release();
        panel.Loaded += (_, _) => { Attach(); Resize(); UpdateCursor(); };
        panel.LostFocus += (_, _) => Release();
        panel.SizeChanged += (_, _) => Resize(); panel.CompositionScaleChanged += (_, _) => Resize();
        panel.PointerMoved += PointerMoved;
        panel.PointerPressed += (_, e) => {
            if (!inputEnabled) { Resume(); e.Handled = true; return; }
            var point = e.GetCurrentPoint(panel); SendPointer(point.Position.X, point.Position.Y);
            int button = point.Properties.PointerUpdateKind switch { Microsoft.UI.Input.PointerUpdateKind.LeftButtonPressed => 1, Microsoft.UI.Input.PointerUpdateKind.RightButtonPressed => 2, Microsoft.UI.Input.PointerUpdateKind.MiddleButtonPressed => 3, Microsoft.UI.Input.PointerUpdateKind.XButton1Pressed => 4, Microsoft.UI.Input.PointerUpdateKind.XButton2Pressed => 5, _ => 0 };
            if (button != 0) { heldButtons.Add(button); native.Send(new { command = "button", button, down = true }); }
            panel.CapturePointer(e.Pointer); e.Handled = true;
        };
        panel.PointerReleased += (_, e) => {
            if (!inputEnabled) return;
            int button = e.GetCurrentPoint(panel).Properties.PointerUpdateKind switch { Microsoft.UI.Input.PointerUpdateKind.LeftButtonReleased => 1, Microsoft.UI.Input.PointerUpdateKind.RightButtonReleased => 2, Microsoft.UI.Input.PointerUpdateKind.MiddleButtonReleased => 3, Microsoft.UI.Input.PointerUpdateKind.XButton1Released => 4, Microsoft.UI.Input.PointerUpdateKind.XButton2Released => 5, _ => 0 };
            if (button != 0) { heldButtons.Remove(button); native.Send(new { command = "button", button, down = false }); }
            if (heldButtons.Count == 0) panel.ReleasePointerCapture(e.Pointer); e.Handled = true;
        };
        panel.PointerCaptureLost += (_, _) => { if (inputEnabled && heldButtons.Count != 0) Release(); };
        panel.PointerWheelChanged += (_, e) => { if (inputEnabled) { var p = e.GetCurrentPoint(panel).Properties; native.Send(new { command = "scroll", dx = p.IsHorizontalMouseWheel ? -p.MouseWheelDelta : 0, dy = p.IsHorizontalMouseWheel ? 0 : p.MouseWheelDelta }); e.Handled = true; } };
        panel.KeyDown += (_, e) => Key(e, true); panel.KeyUp += (_, e) => Key(e, false);
        Activated += (_, e) => { if (e.WindowActivationState == WindowActivationState.Deactivated) Release(); };
        Closed += (_, _) => {
            closing = true; Release(); nativePanel?.SetSwapChain(0); nativePanel = null;
            native.Send(new { command = "select_display", stream, display = 0 }); closed();
        };
    }
    private void Preferences() => native.Send(new { command = "preferences", stats = showStats.IsChecked, swap_modifiers = swap, local_cursor = localCursor });
    public void ApplyPreferences(bool statistics, bool cursor, bool modifiers)
    {
        showStats.IsChecked = statistics; swapItem.IsChecked = modifiers; cursorItem.IsChecked = cursor;
        stats.Visibility = statistics ? Visibility.Visible : Visibility.Collapsed;
        swap = modifiers; localCursor = cursor; UpdateCursor();
    }
    public void SetDisplays(IEnumerable<JsonElement> displays)
    {
        updatingDisplays = true; displayChoice.Items.Clear();
        foreach (var display in displays)
        {
            var item = new ComboBoxItem { Content = display.Text("name"), Tag = display.Unsigned("id") }; displayChoice.Items.Add(item);
            if ((uint)item.Tag == Display) displayChoice.SelectedItem = item;
        }
        updatingDisplays = false;
    }
    public void Attach()
    {
        if (closing || !panel.IsLoaded) return;
        nint chain = native.SwapChain(stream); if (chain == 0) return;
        try { nativePanel ??= WinRT.CastExtensions.As<ISwapChainPanelNative>(panel); Marshal.ThrowExceptionForHR(nativePanel.SetSwapChain(chain)); Resize(); attached?.Invoke(); }
        finally { Marshal.Release(chain); }
    }
    public void Detach() { nativePanel?.SetSwapChain(0); Interrupted(); }
    private void Resize() => native.Resize(stream, (uint)Math.Max(1, panel.ActualWidth * panel.CompositionScaleX), (uint)Math.Max(1, panel.ActualHeight * panel.CompositionScaleY));
    public void UpdateStats(JsonElement e)
    {
        videoWidth = e.Number("width", videoWidth); videoHeight = e.Number("height", videoHeight);
        live = e.Flag("live");
        stats.Text = e.Text("message", $"{videoWidth} × {videoHeight} · {e.Number("fps")} fps");
        if (!live) Release();
    }
    public void Interrupted() { live = false; Release(); stats.Text = "Video interrupted · input released"; }
    private void Resume() { if (!live) return; inputEnabled = true; panel.Focus(FocusState.Programmatic); UpdateCursor(); native.Send(new { command = "resume_input" }); }
    private void Release() { inputEnabled = false; heldKeys.Clear(); heldButtons.Clear(); panel.ReleasePointerCaptures(); UpdateCursor(); native.Send(new { command = "release_input" }); }
    private void UpdateCursor() { if (panel.IsLoaded) panel.SetLocalCursor(!inputEnabled || localCursor); }
    private void PointerMoved(object sender, PointerRoutedEventArgs e)
    { if (inputEnabled) { var point = e.GetCurrentPoint(panel).Position; SendPointer(point.X, point.Y); e.Handled = true; } }
    private void SendPointer(double x, double y)
    {
        double scale = Math.Min(panel.ActualWidth / videoWidth, panel.ActualHeight / videoHeight);
        if (scale <= 0) return;
        double left = (panel.ActualWidth - videoWidth * scale) / 2, top = (panel.ActualHeight - videoHeight * scale) / 2;
        if (x < left || y < top || x > left + videoWidth * scale || y > top + videoHeight * scale) return;
        native.Send(new { command = "pointer", display = Display, x = (ushort)Math.Clamp((x - left) / (videoWidth * scale) * 65535, 0, 65535), y = (ushort)Math.Clamp((y - top) / (videoHeight * scale) * 65535, 0, 65535) });
    }
    private void Key(KeyRoutedEventArgs e, bool down)
    {
        bool control = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down);
        bool shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
        bool alt = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(CoreVirtualKeyStates.Down);
        if (down && control && shift && alt && e.Key == VirtualKey.F12) { Release(); e.Handled = true; return; }
        if (!inputEnabled) return;
        ushort usage = HidMap.Usage((uint)e.Key, e.KeyStatus.ScanCode, e.KeyStatus.IsExtendedKey);
        if (usage == 0) return;
        bool repeat = down && heldKeys.Contains(usage);
        if (down) heldKeys.Add(usage); else heldKeys.Remove(usage);
        native.Send(new { command = "key", usage, down, repeat }); e.Handled = true;
    }
    private static Button Button(string text, RoutedEventHandler handler) { var result = new Button { Content = text }; result.Click += handler; return result; }
}

internal sealed class VideoPanel : SwapChainPanel
{
    private Microsoft.UI.Input.InputSystemCursor? arrow;
    public void SetLocalCursor(bool visible) => ProtectedCursor = visible ? arrow ??= Microsoft.UI.Input.InputSystemCursor.Create(Microsoft.UI.Input.InputSystemCursorShape.Arrow) : null;
}

internal static class HidMap
{
    private static readonly ushort[] Letters = { 4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29 };
    public static ushort Usage(uint key, uint scan, bool extended)
    {
        // USB usages describe physical keys. VirtualKey letters depend on the local layout.
        if (key == 19) return 72; // Pause uses the exceptional E1 sequence.
        ushort physical = (scan | (extended ? 0x100u : 0)) switch {
            0x01 => 41, 0x02 => 30, 0x03 => 31, 0x04 => 32, 0x05 => 33, 0x06 => 34, 0x07 => 35, 0x08 => 36, 0x09 => 37, 0x0a => 38, 0x0b => 39,
            0x0c => 45, 0x0d => 46, 0x0e => 42, 0x0f => 43, 0x10 => 20, 0x11 => 26, 0x12 => 8, 0x13 => 21, 0x14 => 23, 0x15 => 28, 0x16 => 24,
            0x17 => 12, 0x18 => 18, 0x19 => 19, 0x1a => 47, 0x1b => 48, 0x1c => 40, 0x1d => 224, 0x1e => 4, 0x1f => 22, 0x20 => 7, 0x21 => 9,
            0x22 => 10, 0x23 => 11, 0x24 => 13, 0x25 => 14, 0x26 => 15, 0x27 => 51, 0x28 => 52, 0x29 => 53, 0x2a => 225, 0x2b => 49, 0x2c => 29,
            0x2d => 27, 0x2e => 6, 0x2f => 25, 0x30 => 5, 0x31 => 17, 0x32 => 16, 0x33 => 54, 0x34 => 55, 0x35 => 56, 0x36 => 229, 0x37 => 85,
            0x38 => 226, 0x39 => 44, 0x3a => 57, 0x3b => 58, 0x3c => 59, 0x3d => 60, 0x3e => 61, 0x3f => 62, 0x40 => 63, 0x41 => 64, 0x42 => 65,
            0x43 => 66, 0x44 => 67, 0x45 => 83, 0x46 => 71, 0x47 => 95, 0x48 => 96, 0x49 => 97, 0x4a => 86, 0x4b => 92, 0x4c => 93, 0x4d => 94,
            0x4e => 87, 0x4f => 89, 0x50 => 90, 0x51 => 91, 0x52 => 98, 0x53 => 99, 0x56 => 100, 0x57 => 68, 0x58 => 69,
            0x11c => 88, 0x11d => 228, 0x135 => 84, 0x137 => 70, 0x138 => 230, 0x145 => 72, 0x147 => 74, 0x148 => 82, 0x149 => 75,
            0x14b => 80, 0x14d => 79, 0x14f => 77, 0x150 => 81, 0x151 => 78, 0x152 => 73, 0x153 => 76, 0x15b => 227, 0x15c => 231, 0x15d => 101, _ => 0
        };
        if (physical != 0) return physical;
        if (key is >= 65 and <= 90) return Letters[key - 65];
        if (key is >= 49 and <= 57) return (ushort)(key - 49 + 30);
        if (key is >= 112 and <= 135) return (ushort)(key <= 123 ? key - 112 + 58 : key - 124 + 104);
        if (key is >= 97 and <= 105) return (ushort)(key - 97 + 89);
        return key switch {
            48 => 39, 13 => (ushort)(extended ? 88 : 40), 27 => 41, 8 => 42, 9 => 43, 32 => 44,
            189 => 45, 187 => 46, 219 => 47, 221 => 48, 220 => 49, 186 => 51, 222 => 52, 192 => 53, 188 => 54, 190 => 55, 191 => 56,
            20 => 57, 44 => 70, 145 => 71, 19 => 72, 45 => 73, 36 => 74, 33 => 75, 46 => 76, 35 => 77, 34 => 78,
            39 => 79, 37 => 80, 40 => 81, 38 => 82, 144 => 83, 111 => 84, 106 => 85, 109 => 86, 107 => 87, 96 => 98, 110 => 99,
            226 => 100, 93 => 101, 17 => (ushort)(extended ? 228 : 224), 16 => (ushort)(scan == 0x36 ? 229 : 225),
            18 => (ushort)(extended ? 230 : 226), 91 => 227, 92 => 231, _ => 0
        };
    }
}

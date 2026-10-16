using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;
using Windows.Storage.Pickers;
using WinRT.Interop;
namespace Lightray.Client;

internal sealed class ComputersWindow : Window
{
    private readonly NativeBridge native = new(2);
    private readonly TextBox address = new() { Header = "Host name or IP address", PlaceholderText = "192.168.1.10:7373" };
    private readonly PasswordBox pairing = new() { Header = "Pairing code", PlaceholderText = "lr1-…" };
    private readonly TextBox name = new() { Header = "Computer name", PlaceholderText = "Gaming PC" };
    private readonly CheckBox remember = new() { Content = "Remember this computer", IsChecked = true };
    private readonly ComboBox saved = new() { Header = "Saved computers", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock status = new() { Text = "Enter a host and import its pairing file.", TextWrapping = TextWrapping.Wrap };
    private readonly Dictionary<byte, StreamWindow> streams = new();
    private readonly List<JsonElement> displays = new();
    private bool closing, pruning;
    private bool showStatistics = true, localCursor, swapModifiers;
    private string? smokeReport;
    private DispatcherTimer? exitTimer;
    public ComputersWindow(string[] args)
    {
        Title = "Lightray"; AppWindow.Resize(new Windows.Graphics.SizeInt32(570, 700));
        int reportIndex = Array.IndexOf(args, "--smoke-report");
        if (reportIndex >= 0 && reportIndex + 1 < args.Length)
        {
            try { smokeReport = Path.GetFullPath(args[reportIndex + 1]); Directory.CreateDirectory(Path.GetDirectoryName(smokeReport)!); File.WriteAllText(smokeReport, ""); }
            catch (Exception error) { UiDiagnostics.Record(error.ToString()); smokeReport = null; }
        }
        var root = new StackPanel { Spacing = 18, Padding = new Thickness(28) };
        root.Children.Add(new TextBlock { Text = "Computers", FontSize = 28 }); root.Children.Add(saved);
        saved.SelectionChanged += (_, _) => {
            if (saved.SelectedItem is ComboBoxItem item && item.Tag is JsonElement computer)
            { address.Text = computer.Text("address"); name.Text = computer.Text("name"); pairing.Password = ""; }
        };
        root.Children.Add(address); root.Children.Add(name); root.Children.Add(pairing); root.Children.Add(remember);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        actions.Children.Add(Button("Import Pairing File…", async (_, _) => {
            var picker = new FileOpenPicker(); picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            var file = await picker.PickSingleFileAsync();
            if (file is not null)
            {
                try { if (new FileInfo(file.Path).Length > 4096) throw new InvalidDataException("Pairing file is too large."); pairing.Password = File.ReadAllText(file.Path).Trim(); }
                catch (Exception error) { status.Text = error.Message; }
            }
        }));
        actions.Children.Add(Button("Connect", (_, _) => Connect()));
        root.Children.Add(actions);
        root.Children.Add(Button("Forget Selected Computer", (_, _) => {
            if (saved.SelectedItem is ComboBoxItem item && item.Tag is JsonElement computer) native.Send(new { command = "forget", pairing_id = computer.Text("pairing_id") });
        }));
        root.Children.Add(status); Content = new ScrollViewer { Content = root };
        native.Event += OnEvent; native.Send(new { command = "computers" });
        Closed += (_, _) => { closing = true; exitTimer?.Stop(); foreach (var stream in streams.Values.ToArray()) stream.Close(); native.Dispose(); };
        int exitIndex = Array.IndexOf(args, "--exit-after");
        if (exitIndex >= 0 && exitIndex + 1 < args.Length && int.TryParse(args[exitIndex + 1], out int seconds) && seconds is >= 1 and <= 3600)
        {
            exitTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
            exitTimer.Tick += (_, _) => { exitTimer.Stop(); Close(); }; exitTimer.Start();
        }
        int hostIndex = Array.IndexOf(args, "--connect");
        int fileIndex = Array.IndexOf(args, "--pair-file");
        if (hostIndex >= 0 && hostIndex + 1 < args.Length)
        {
            address.Text = args[hostIndex + 1]; remember.IsChecked = false;
            if (fileIndex >= 0 && fileIndex + 1 < args.Length)
            {
                try
                {
                    string path = args[fileIndex + 1];
                    if (new FileInfo(path).Length > 4096) throw new InvalidDataException("Pairing file is too large.");
                    pairing.Password = File.ReadAllText(path).Trim();
                }
                catch (Exception error) { status.Text = error.Message; return; }
            }
            Connect();
        }
    }
    private void Connect()
    {
        string id = saved.SelectedItem is ComboBoxItem item && item.Tag is JsonElement computer ? computer.Text("pairing_id") : "";
        native.Send(new { command = "connect", address = address.Text.Trim(), token = pairing.Password.Trim(), pairing_id = id, name = name.Text.Trim(), remember = remember.IsChecked == true });
        status.Text = "Connecting…";
    }
    private void OnEvent(JsonElement e)
    {
        if (e.Text("kind") is "connected" or "disconnected" or "binding" or "surface" or "surface_detach" or "stats" or "error" or "session_reset")
        {
            var safe = new Dictionary<string, object?> { ["observed_at"] = DateTimeOffset.UtcNow };
            foreach (string key in new[] { "kind", "stream", "display", "width", "height", "fps", "live", "message", "decode_present_ms", "rtt_ms", "streams" })
                if (e.TryGetProperty(key, out var value)) safe[key] = value.Clone();
            Report(safe);
        }
        switch (e.Text("kind"))
        {
            case "computers":
                saved.Items.Clear();
                if (e.TryGetProperty("computers", out var list)) foreach (var computer in list.EnumerateArray()) saved.Items.Add(new ComboBoxItem { Content = computer.Text("name") + " · " + computer.Text("address"), Tag = computer.Clone() });
                break;
            case "connected": status.Text = "Connected. Waiting for video…"; pairing.Password = ""; break;
            case "session_reset":
                var accepted = e.TryGetProperty("streams", out var acceptedStreams) ? acceptedStreams.EnumerateArray().Select(x => x.GetByte()).ToHashSet() : new HashSet<byte>();
                pruning = true;
                try
                {
                    foreach (var existing in streams.ToArray())
                        if (!accepted.Contains(existing.Key)) { streams.Remove(existing.Key); existing.Value.Close(); }
                        else existing.Value.Detach();
                }
                finally { pruning = false; }
                break;
            case "preferences":
                showStatistics = e.Flag("stats"); localCursor = e.Flag("local_cursor"); swapModifiers = e.Flag("swap_modifiers");
                foreach (var stream in streams.Values) stream.ApplyPreferences(showStatistics, localCursor, swapModifiers);
                break;
            case "displays":
                displays.Clear(); if (e.TryGetProperty("displays", out var d)) displays.AddRange(d.EnumerateArray().Select(x => x.Clone()));
                foreach (var stream in streams.Values) stream.SetDisplays(displays); break;
            case "binding":
                byte id = checked((byte)e.Number("stream")); uint display = e.Unsigned("display");
                if (display == 0) { if (streams.Remove(id, out var old)) old.Close(); break; }
                if (!streams.TryGetValue(id, out var window))
                {
                    window = new StreamWindow(native, id, display, () => {
                        streams.Remove(id);
                        if (!closing && !pruning && streams.Count == 0) { native.Send(new { command = "disconnect" }); Activate(); }
                    }, () => Report(new { kind = "surface_attached", stream = id, observed_at = DateTimeOffset.UtcNow }));
                    streams[id] = window; window.SetDisplays(displays); window.ApplyPreferences(showStatistics, localCursor, swapModifiers); window.Activate();
                }
                window.Display = display; break;
            case "surface":
                if (streams.TryGetValue(checked((byte)e.Number("stream")), out var surface)) surface.Attach(); break;
            case "surface_detach":
                if (streams.TryGetValue(checked((byte)e.Number("stream")), out var detached)) detached.Detach(); break;
            case "stats":
                if (streams.TryGetValue(checked((byte)e.Number("stream")), out var target)) target.UpdateStats(e); break;
            case "disconnected":
                status.Text = e.Text("message", "Disconnected. Reconnecting…");
                foreach (var stream in streams.Values) stream.Interrupted(); break;
            case "error": status.Text = e.Text("message"); break;
        }
    }
    private void Report(object value)
    {
        if (smokeReport is null) return;
        try { File.AppendAllText(smokeReport, JsonSerializer.Serialize(value) + Environment.NewLine); }
        catch (Exception error) { UiDiagnostics.Record(error.ToString()); smokeReport = null; }
    }
    private static Button Button(string text, RoutedEventHandler handler) { var result = new Button { Content = text }; result.Click += handler; return result; }
}

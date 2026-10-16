using Microsoft.UI.Xaml;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Lightray.Host;

internal static class Program
{
    [STAThread] static void Main(string[] args)
    {
        UiDiagnostics.Record("Host: starting application");
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(p => {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new HostApplication(args);
        });
    }
}
public sealed partial class HostApplication : Application
{
    private readonly string[] args;
    public HostApplication(string[] args)
    {
        this.args = args;
        UnhandledException += (_, e) => UiDiagnostics.Record(e.Exception.ToString());
        InitializeComponent();
    }
    private Window? window;
    protected override void OnLaunched(LaunchActivatedEventArgs e)
    {
        UiDiagnostics.Record("Host: creating window");
        window = new HostWindow(); window.Activate();
        UiDiagnostics.Record("Host: window activated");
        if (args.Contains("--smoke-test"))
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
            timer.Tick += (_, _) => { timer.Stop(); window.Close(); }; timer.Start();
        }
    }
}
internal sealed class HostWindow : Window
{
    private readonly NativeBridge native = new(1);
    private readonly TextBlock status = new() { Text = "Checking sharing status…", TextWrapping = TextWrapping.Wrap };
    private readonly NumberBox port = new() { Header = "UDP port", Value = 7373, Minimum = 1, Maximum = 65535, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    private readonly NumberBox fps = new() { Header = "Frame rate", Value = 60, Minimum = 1, Maximum = 240 };
    private readonly NumberBox bitrate = new() { Header = "Video bitrate (Mb/s per display)", Value = 20, Minimum = 2, Maximum = 220 };
    private readonly ComboBox resolution = new() { Header = "Maximum stream resolution", SelectedIndex = 0 };
    private readonly ToggleSwitch input = new() { Header = "Keyboard and mouse", IsOn = true };
    private readonly ToggleSwitch synthetic = new() { Header = "Synthetic display (testing)", IsOn = false };
    private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(1) };
    private string? exportPath;
    private bool copyPairing;
    private bool settingsLoaded;
    public HostWindow()
    {
        Title = "Lightray Host";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(620, 790));
        resolution.Items.Add("1920 × 1080"); resolution.Items.Add("2560 × 1440"); resolution.Items.Add("3840 × 2160");
        var root = new StackPanel { Spacing = 16, Padding = new Thickness(28) };
        root.Children.Add(new TextBlock { Text = "Share this PC", FontSize = 28 });
        root.Children.Add(new TextBlock { Text = "Sharing continues after this window closes. Stop Sharing turns it off now and at future logins.", TextWrapping = TextWrapping.Wrap });
        root.Children.Add(status); root.Children.Add(port); root.Children.Add(fps); root.Children.Add(bitrate); root.Children.Add(resolution); root.Children.Add(input); root.Children.Add(synthetic);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        actions.Children.Add(Button("Start Sharing", (_, _) => native.Send(new { command = "start", settings = Settings() })));
        actions.Children.Add(Button("Apply Settings", (_, _) => native.Send(new { command = "configure", settings = Settings() })));
        actions.Children.Add(Button("Stop Sharing", (_, _) => native.Send(new { command = "stop" })));
        root.Children.Add(actions);
        var pairing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        pairing.Children.Add(Button("Copy Pairing Code", (_, _) => { copyPairing = true; native.Send(new { command = "pairing" }); }));
        pairing.Children.Add(Button("Export Pairing File…", async (_, _) => {
            var picker = new FileSavePicker { SuggestedFileName = "lightray-pairing" };
            picker.FileTypeChoices.Add("Pairing file", new List<string> { ".txt" });
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            var file = await picker.PickSaveFileAsync();
            if (file is not null) { exportPath = file.Path; native.Send(new { command = "pairing" }); }
        })); root.Children.Add(pairing);
        root.Children.Add(new TextBlock { Text = "A pairing code grants remote access. Give it only to devices you trust.", TextWrapping = TextWrapping.Wrap });
        root.Children.Add(Button("Open Diagnostics", (_, _) => {
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lightray", "Logs");
            Directory.CreateDirectory(path); System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
        }));
        Content = new ScrollViewer { Content = root };
        native.Event += HandleEvent;
        native.Send(new { command = "status" });
        poll.Tick += (_, _) => native.Send(new { command = "status" }); poll.Start();
        Closed += (_, _) => { poll.Stop(); native.Dispose(); };
    }
    private object Settings()
    {
        int width = resolution.SelectedIndex switch { 1 => 2560, 2 => 3840, _ => 1920 };
        int height = resolution.SelectedIndex switch { 1 => 1440, 2 => 2160, _ => 1080 };
        return new { version = 1, port = (int)port.Value, fps = (int)fps.Value, bitrate_mbps = (int)bitrate.Value, max_width = width, max_height = height, allow_input = input.IsOn, synthetic = synthetic.IsOn };
    }
    private void HandleEvent(JsonElement e)
    {
        switch (e.Text("kind"))
        {
            case "host_status":
                status.Text = e.Text("message", e.Flag("ready") ? "Sharing is ready." : "Sharing is stopped.");
                if (!settingsLoaded && e.TryGetProperty("settings", out var s))
                {
                    settingsLoaded = true; port.Value = s.Number("port", 7373); fps.Value = s.Number("fps", 60); bitrate.Value = s.Number("bitrate_mbps", 20);
                    input.IsOn = s.Flag("allow_input"); synthetic.IsOn = s.Flag("synthetic");
                    resolution.SelectedIndex = s.Number("max_width", 1920) switch { 2560 => 1, 3840 => 2, _ => 0 };
                }
                break;
            case "pairing":
                string token = e.Text("token");
                if (copyPairing) { var data = new DataPackage(); data.SetText(token); Clipboard.SetContent(data); copyPairing = false; status.Text = "Pairing code copied."; }
                if (exportPath is not null) { try { File.WriteAllText(exportPath, token + Environment.NewLine); status.Text = "Pairing file exported."; } catch (Exception error) { status.Text = error.Message; } exportPath = null; }
                break;
            case "error": status.Text = e.Text("message"); break;
        }
    }
    private static Button Button(string text, RoutedEventHandler handler) { var button = new Button { Content = text }; button.Click += handler; return button; }
}

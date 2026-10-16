using Microsoft.UI.Xaml;
using Microsoft.UI.Dispatching;
namespace Lightray.Client;
internal static class Program
{
    [STAThread] static void Main(string[] args)
    {
        UiDiagnostics.Record("Client: starting application");
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(p => {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new ClientApplication(args);
        });
    }
}
public sealed partial class ClientApplication : Application
{
    private readonly string[] args;
    public ClientApplication(string[] args)
    {
        this.args = args;
        UnhandledException += (_, e) => UiDiagnostics.Record(e.Exception.ToString());
        InitializeComponent();
    }
    private Window? window;
    protected override void OnLaunched(LaunchActivatedEventArgs e)
    {
        UiDiagnostics.Record("Client: creating window");
        window = new ComputersWindow(args); window.Activate();
        UiDiagnostics.Record("Client: window activated");
        if (args.Contains("--smoke-test"))
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
            timer.Tick += (_, _) => { timer.Stop(); window.Close(); }; timer.Start();
        }
    }
}

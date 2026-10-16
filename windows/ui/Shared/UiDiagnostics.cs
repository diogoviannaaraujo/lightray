namespace Lightray;

internal static class UiDiagnostics
{
    public static void Record(string message)
    {
        try
        {
            string root = Environment.GetEnvironmentVariable("LIGHTRAY_DATA_DIR") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lightray");
            string directory = Path.Combine(root, "Logs"); Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "ui.log");
            if (File.Exists(path) && new FileInfo(path).Length > 64 * 1024) File.Move(path, path + ".previous", true);
            File.AppendAllText(path, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch { }
    }
}

using Aurelia.Contracts;

namespace Aurelia.Server.Services.Speech;

/// <summary>
/// The speech model for whisper.cpp, downloaded once when the owner asks for it and kept in the
/// server's data folder ("SpeechModels"), with its size visible and removable at any time. Only
/// one model is kept; choosing another replaces it. Media and sound are never stored here.
/// </summary>
public sealed partial class SpeechModelStore
{
    public const string FolderName = "SpeechModels";

    /// <summary>The models offered, from whisper.cpp's own model repository.</summary>
    public static readonly IReadOnlyList<SpeechModelChoice> Choices =
    [
        new("base", "Base", 147_951_465, "Fast, fine for clear dialogue. About 150 MB."),
        new("small", "Small", 487_601_967, "More accurate, a few times slower. About 490 MB."),
        new("medium", "Medium", 1_533_763_059, "The most accurate here, slow on a small server. About 1.5 GB."),
    ];

    private static readonly Uri Source = new("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/");
    private readonly string folder;
    private readonly HttpClient http;
    private readonly ILogger<SpeechModelStore> logger;
    private readonly object gate = new();
    private CancellationTokenSource? downloading;

    public SpeechModelStore(ServerRuntimeOptions runtime, ILogger<SpeechModelStore> logger, HttpClient? http = null)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        folder = Path.Combine(runtime.DataDirectory, FolderName);
        this.logger = logger;
        this.http = http ?? new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        if (http is null) this.http.DefaultRequestHeaders.UserAgent.ParseAdd("Aurelia v" + ServerProductVersion.Current);
    }

    public SpeechModelDownload? Download { get; private set; }

    public string? DownloadError { get; private set; }

    /// <summary>The downloaded model, or null.</summary>
    public (string Name, string Path, long Bytes)? Current
    {
        get
        {
            foreach (var choice in Choices)
            {
                var path = PathOf(choice.Name);
                if (File.Exists(path)) return (choice.Name, path, new FileInfo(path).Length);
            }
            return null;
        }
    }

    private string PathOf(string name) => Path.Combine(folder, $"ggml-{name}.bin");

    /// <summary>Starts downloading <paramref name="name"/> in the background; a running download is replaced.</summary>
    public void StartDownload(string name)
    {
        var choice = Choices.FirstOrDefault(candidate => candidate.Name == name)
            ?? throw new ArgumentOutOfRangeException(nameof(name), "Unknown speech model.");
        CancellationTokenSource cancellation;
        lock (gate)
        {
            downloading?.Cancel();
            downloading = cancellation = new CancellationTokenSource();
            Download = new SpeechModelDownload(choice.Name, 0, choice.Bytes);
            DownloadError = null;
        }
        _ = Task.Run(() => DownloadAsync(choice, cancellation));
    }

    /// <summary>Removes the model and stops a download.</summary>
    public void Remove()
    {
        lock (gate)
        {
            downloading?.Cancel();
            downloading = null;
            Download = null;
        }
        if (!Directory.Exists(folder)) return;
        foreach (var file in Directory.EnumerateFiles(folder, "ggml-*")) File.Delete(file);
    }

    private async Task DownloadAsync(SpeechModelChoice choice, CancellationTokenSource cancellation)
    {
        var partial = PathOf(choice.Name) + ".partial";
        try
        {
            Directory.CreateDirectory(folder);
            using var response = await http.GetAsync(new Uri(Source, $"ggml-{choice.Name}.bin"), HttpCompletionOption.ResponseHeadersRead, cancellation.Token);
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength ?? choice.Bytes;
            if (total > choice.Bytes * 2) throw new InvalidDataException("The model is larger than expected.");
            await using (var input = await response.Content.ReadAsStreamAsync(cancellation.Token))
            await using (var output = File.Create(partial))
            {
                var buffer = new byte[1 << 20];
                long received = 0;
                int read;
                while ((read = await input.ReadAsync(buffer, cancellation.Token)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellation.Token);
                    received += read;
                    if (received > choice.Bytes * 2) throw new InvalidDataException("The model is larger than expected.");
                    lock (gate) if (downloading == cancellation) Download = new SpeechModelDownload(choice.Name, received, total);
                }
            }
            if (!IsModel(partial)) throw new InvalidDataException("The download is not a whisper.cpp model.");
            lock (gate)
            {
                if (downloading != cancellation) return;
                // One model at a time: the new one replaces any other.
                foreach (var other in Choices.Where(candidate => candidate.Name != choice.Name)) File.Delete(PathOf(other.Name));
                File.Move(partial, PathOf(choice.Name), overwrite: true);
                Download = null;
                downloading = null;
            }
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or InvalidDataException or OperationCanceledException or UnauthorizedAccessException)
        {
            lock (gate)
            {
                if (downloading == cancellation)
                {
                    Download = null;
                    downloading = null;
                    DownloadError = exception is OperationCanceledException ? null : "The model could not be downloaded. Check the server's internet connection and try again.";
                }
            }
            if (exception is not OperationCanceledException) LogFailed(logger, exception.GetType().Name);
        }
        finally
        {
            try { if (File.Exists(partial)) File.Delete(partial); }
            catch (IOException) { }
        }
    }

    /// <summary>whisper.cpp models start with the GGML magic number.</summary>
    public static bool IsModel(string path)
    {
        using var file = File.OpenRead(path);
        Span<byte> magic = stackalloc byte[4];
        return file.Read(magic) == 4 && BitConverter.ToUInt32(magic) == 0x67676d6c;
    }

    [LoggerMessage(Level = LogLevel.Warning, Message = "The speech model download failed: {Error}")]
    private static partial void LogFailed(ILogger logger, string error);
}

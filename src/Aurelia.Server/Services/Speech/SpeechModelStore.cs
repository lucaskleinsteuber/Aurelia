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

    /// <summary>
    /// A fixed revision of whisper.cpp's model repository, not "main", and each model's SHA-256 as
    /// published there: whisper.cpp reads the file as native code, so a model that was swapped on the
    /// way or at the source is never kept (audit S-M3). A new model or revision changes both here.
    /// </summary>
    private static readonly Uri Source = new("https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/");

    internal static readonly IReadOnlyDictionary<string, string> PublishedSha256 = new Dictionary<string, string>
    {
        ["base"] = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        ["small"] = "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        ["medium"] = "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
    };

    /// <summary>Whether a download is exactly the published model: its size and its SHA-256.</summary>
    internal static bool IsPublished(SpeechModelChoice choice, long bytes, ReadOnlySpan<byte> sha256) =>
        bytes == choice.Bytes && PublishedSha256.TryGetValue(choice.Name, out var expected)
        && Convert.ToHexStringLower(sha256) == expected;
    private readonly string folder;
    private readonly HttpClient http;
    private readonly ILogger<SpeechModelStore> logger;
    private readonly TimeSpan readInactivityTimeout;
    private readonly object gate = new();
    private CancellationTokenSource? downloading;

    public SpeechModelStore(ServerRuntimeOptions runtime, ILogger<SpeechModelStore> logger, HttpClient? http = null, TimeSpan? readInactivityTimeout = null)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        folder = Path.Combine(runtime.DataDirectory, FolderName);
        this.logger = logger;
        this.readInactivityTimeout = readInactivityTimeout ?? TimeSpan.FromSeconds(60);
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
        // Unique temp path per attempt so rapid restarts never unlink each other's partial file (audit SRV-BG-010).
        var partial = PathOf(choice.Name) + $".{Guid.NewGuid():N}.partial";
        try
        {
            Directory.CreateDirectory(folder);
            HttpResponseMessage response;
            using (var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token))
            {
                connectTimeout.CancelAfter(readInactivityTimeout);
                try
                {
                    response = await http.GetAsync(new Uri(Source, $"ggml-{choice.Name}.bin"), HttpCompletionOption.ResponseHeadersRead, connectTimeout.Token);
                }
                catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
                {
                    throw new TimeoutException("The speech model download timed out waiting for the server to respond.");
                }
            }
            using var ownedResponse = response;
            ownedResponse.EnsureSuccessStatusCode();
            var total = ownedResponse.Content.Headers.ContentLength ?? choice.Bytes;
            if (total > choice.Bytes * 2) throw new InvalidDataException("The model is larger than expected.");
            using var hash = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
            long written = 0;
            await using (var input = await ownedResponse.Content.ReadAsStreamAsync(cancellation.Token))
            await using (var output = File.Create(partial))
            {
                var buffer = new byte[1 << 20];
                long received = 0;
                while (true)
                {
                    int read;
                    using (var readTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token))
                    {
                        readTimeout.CancelAfter(readInactivityTimeout);
                        try
                        {
                            read = await input.ReadAsync(buffer, readTimeout.Token);
                        }
                        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
                        {
                            throw new TimeoutException("The speech model download stalled without receiving data.");
                        }
                    }
                    if (read <= 0) break;
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellation.Token);
                    hash.AppendData(buffer, 0, read);
                    received += read;
                    written = received;
                    if (received > choice.Bytes * 2) throw new InvalidDataException("The model is larger than expected.");
                    lock (gate) if (downloading == cancellation) Download = new SpeechModelDownload(choice.Name, received, total);
                }
            }
            if (!IsPublished(choice, written, hash.GetHashAndReset()) || !IsModel(partial))
                throw new InvalidDataException("The download is not the published whisper.cpp model.");
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
        catch (Exception exception) when (exception is HttpRequestException or IOException or InvalidDataException or OperationCanceledException or TimeoutException or UnauthorizedAccessException)
        {
            lock (gate)
            {
                if (downloading == cancellation)
                {
                    Download = null;
                    downloading = null;
                    DownloadError = exception is OperationCanceledException && cancellation.IsCancellationRequested
                        ? null
                        : exception is TimeoutException
                            ? "The model download timed out. Check the server's internet connection and try again."
                            : "The model could not be downloaded. Check the server's internet connection and try again.";
                }
            }
            if (exception is not OperationCanceledException || !cancellation.IsCancellationRequested) LogFailed(logger, exception.GetType().Name);
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

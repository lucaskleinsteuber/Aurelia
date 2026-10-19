using System.Reflection;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;

// Exercises the server's platform file code on synthetic media: scanning with file identities,
// handle-checked opening for playback, the editor's folder listing, and refusal of anything that
// leaves the library through a link or a relative path. Built for Windows and run under Wine by
// scripts/test-server-wine.sh; it also runs natively for comparison. Expects a prepared folder:
//   <root>/Movies/Synthetic Movie (2020)/Synthetic Movie (2020).mkv  (bytes i % 251)
//   <root>/Movies/Linked -> <root>/Outside (a link), <root>/Outside/Secret (2021).mkv
if (args.Length != 1 || !Directory.Exists(Path.Combine(args[0], "Movies")))
    throw new ArgumentException("Supply the prepared synthetic probe folder.");
var root = Path.GetFullPath(args[0]);
var library = Path.Combine(root, "Movies");
var movie = Path.Combine(library, "Synthetic Movie (2020)", "Synthetic Movie (2020).mkv");
var linked = Path.Combine(library, "Linked", "Secret (2021).mkv");
var failures = 0;
void Check(bool passed, string what)
{
    Console.WriteLine($"{(passed ? "pass" : "FAIL")}: {what}");
    if (!passed) failures++;
}

Console.WriteLine($"{Environment.OSVersion} ({System.Runtime.InteropServices.RuntimeInformation.OSArchitecture})");

var discovery = new MediaLibraryScanner().Scan(library, LibraryKind.Movies, [], null, CancellationToken.None);
var found = discovery.Items.Where(item => item.IsFile).ToArray();
foreach (var item in found) Console.WriteLine($"  scanned {item.DetectedTitle}: {item.FileSystemIdentity ?? "<no identity>"}");
var scanned = found.SingleOrDefault(item => item.DetectedTitle == "Synthetic Movie");
Check(scanned is not null, "the scan finds the synthetic movie");
var expectedPrefix = OperatingSystem.IsWindows() ? "windows:" : OperatingSystem.IsMacOS() ? "darwin:" : "unix:";
Check(scanned?.FileSystemIdentity?.StartsWith(expectedPrefix, StringComparison.Ordinal) == true, $"its file identity is a {expectedPrefix} identity");
Check(found.All(item => item.DetectedTitle != "Secret"), "the scan does not follow the link out of the library");

var root1 = new LibraryRoot { Id = Guid.NewGuid(), Name = "Probe", Path = library, NormalizedPath = MediaPath.Normalize(library) };
MediaItem Item(string path) => new()
{
    Id = Guid.NewGuid(),
    LibraryRoot = root1,
    LibraryRootId = root1.Id,
    Kind = MediaKind.Movie,
    SourcePath = path,
    NormalizedSourcePath = MediaPath.Normalize(path),
    Extension = Path.GetExtension(path),
};
var opened = MediaFileAccess.OpenRead(Item(movie));
using (opened.Stream)
{
    var buffer = new byte[100];
    opened.Stream.Position = 1000;
    opened.Stream.ReadExactly(buffer);
    Check(opened.Length == 2_000_000 && buffer.Select((value, index) => value == (1000 + index) % 251).All(same => same),
        $"playback opens the movie and reads bytes 1000-1099 exactly ({opened.ContentType}, {opened.Length} bytes)");
}

string Refusal(string path)
{
    try
    {
        MediaFileAccess.OpenRead(Item(path)).Stream.Dispose();
        return "opened";
    }
    catch (PlaybackException error)
    {
        return error.Code;
    }
}
Check(Refusal(linked) == "media_file_unavailable", $"a file behind the link is refused ({Refusal(linked)})");
Check(Refusal(Path.Combine(library, "..", "Outside", "Secret (2021).mkv")) is not "opened", "a path that climbs out of the library is refused");

var pinned = typeof(MediaPath).Assembly.GetType("Aurelia.Server.Services.PinnedMediaHandle")!;
var list = pinned.GetMethod("ListDirectory", BindingFlags.Public | BindingFlags.Static)!;
var entries = (IReadOnlyList<(string Name, bool Directory)>)list.Invoke(null, [library, library])!;
Console.WriteLine($"  listing: {string.Join(", ", entries.Select(entry => entry.Directory ? entry.Name + "/" : entry.Name))}");
Check(entries.Any(entry => entry is { Name: "Synthetic Movie (2020)", Directory: true }), "the folder listing shows the movie folder");
Check(entries.All(entry => entry.Name != "Linked"), "the folder listing leaves out the link");
var inner = (IReadOnlyList<(string Name, bool Directory)>)list.Invoke(null, [library, Path.GetDirectoryName(movie)!])!;
Check(inner.Any(entry => entry is { Name: "Synthetic Movie (2020).mkv", Directory: false }), "a subfolder listing shows the video file");
try
{
    list.Invoke(null, [library, Path.Combine(library, "Linked")]);
    Check(false, "listing through the link is refused");
}
catch (TargetInvocationException error) when (error.InnerException is IOException)
{
    Check(true, $"listing through the link is refused ({error.InnerException.GetType().Name})");
}

var editor = typeof(MediaPath).Assembly.GetType("Aurelia.Server.Services.MediaEditorService")!;
var sourcePath = editor.GetMethod("SourcePath", BindingFlags.NonPublic | BindingFlags.Static)!;
var climbing = Path.Combine("..", "Outside", "Secret (2021).mkv");
try
{
    sourcePath.Invoke(null, [library, climbing]);
    Check(false, "the editor refuses a relative path that leaves the library");
}
catch (TargetInvocationException error) when (error.InnerException is not null)
{
    Check(true, "the editor refuses a relative path that leaves the library");
}

Console.WriteLine(failures == 0 ? "All probe checks passed." : $"{failures} probe checks failed.");
return failures == 0 ? 0 : 1;

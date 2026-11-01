using System.Text;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Playback;
using Tmds.DBus.Protocol;

namespace Aurelia.Linux.Core.Platform;

/// <summary>
/// Playback on the Linux desktop: media keys and Now Playing through MPRIS
/// (<c>org.mpris.MediaPlayer2.aurelia</c>, shown by KDE, GNOME and others), and keeping the screen
/// awake through <c>org.freedesktop.ScreenSaver</c>. Without a session bus both are skipped
/// quietly. Commands from the desktop run on the interface thread through <paramref name="post"/>.
/// </summary>
public sealed class LinuxPlaybackSystem(Action<Action> post) : IPlaybackSystem, IPathMethodHandler
{
    private const string ObjectPath = "/org/mpris/MediaPlayer2";
    private const string RootInterface = "org.mpris.MediaPlayer2";
    private const string PlayerInterface = "org.mpris.MediaPlayer2.Player";
    private const string PropertiesInterface = "org.freedesktop.DBus.Properties";
    private static readonly string[] PlayerProperties =
        ["PlaybackStatus", "Rate", "Metadata", "Volume", "Position", "MinimumRate", "MaximumRate", "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanSeek", "CanControl"];

    private readonly Lock gate = new();
    private PlaybackController? active;
    private bool registered;
    private uint? inhibitCookie;
    private string lastStatus = "";
    private string lastTitle = "";

    public string Path => ObjectPath;

    public bool HandlesChildPaths => false;

    public void KeepAwake(bool awake) => _ = SetAwakeAsync(awake);

    public void Update(PlaybackController? controller)
    {
        lock (gate) active = controller;
        if (controller is not null && !registered) _ = RegisterAsync();
        var status = Status(controller);
        var title = controller?.Title ?? "";
        if (status == lastStatus && title == lastTitle) return;
        lastStatus = status;
        lastTitle = title;
        EmitChanged();
    }

    public ValueTask HandleMethodAsync(MethodContext context)
    {
        var request = context.Request;
        var member = request.MemberAsString;
        var @interface = request.InterfaceAsString;
        if (context.IsDBusIntrospectRequest)
        {
            context.ReplyIntrospectXml([Encoding.UTF8.GetBytes(Introspection)], []);
            return ValueTask.CompletedTask;
        }
        if (@interface == PropertiesInterface)
        {
            var reader = request.GetBodyReader();
            var target = reader.ReadString();
            if (member == "GetAll")
            {
                var writer = context.CreateReplyWriter("a{sv}");
                try
                {
                    WriteProperties(ref writer, target == RootInterface ? RootProperties() : PlayerValues());
                    context.Reply(writer.CreateMessage());
                }
                finally { writer.Dispose(); }
            }
            else if (member == "Get")
            {
                var name = reader.ReadString();
                var values = target == RootInterface ? RootProperties() : PlayerValues();
                var value = values.FirstOrDefault(entry => entry.Name == name);
                if (value.Name is null)
                {
                    context.ReplyError("org.freedesktop.DBus.Error.UnknownProperty", "Unknown property.");
                    return ValueTask.CompletedTask;
                }
                var writer = context.CreateReplyWriter("v");
                try
                {
                    value.Write(ref writer);
                    context.Reply(writer.CreateMessage());
                }
                finally { writer.Dispose(); }
            }
            else
            {
                // Volume and rate set from the desktop.
                var name = reader.ReadString();
                var variant = reader.ReadVariantValue();
                if (name == "Volume") Run(player => player.Volume = variant.GetDouble());
                if (name == "Rate") Run(player => player.Rate = variant.GetDouble());
                context.Reply(context.CreateReplyWriter(null).CreateMessage());
            }
            return ValueTask.CompletedTask;
        }
        switch (member)
        {
            case "PlayPause":
                Run(player => player.PlayPause());
                break;
            case "Play":
                Run(player => { if (player.State == PlayerState.Paused) player.PlayPause(); });
                break;
            case "Pause":
            case "Stop":
                Run(player => { if (player.State == PlayerState.Playing) player.PlayPause(); });
                break;
            case "Next":
                Run(player => _ = player.NextAsync());
                break;
            case "Previous":
                Run(player => _ = player.PreviousAsync());
                break;
            case "Seek":
                var offset = request.GetBodyReader().ReadInt64();
                Run(player => player.SeekTo(player.Position + offset / 1000));
                break;
            case "SetPosition":
                var body = request.GetBodyReader();
                body.ReadObjectPath();
                var position = body.ReadInt64();
                Run(player => player.SeekTo(position / 1000));
                break;
            case "Raise":
            case "Quit":
            case "OpenUri":
                break;
            default:
                context.ReplyUnknownMethodError();
                return ValueTask.CompletedTask;
        }
        if (!context.NoReplyExpected) context.Reply(context.CreateReplyWriter(null).CreateMessage());
        return ValueTask.CompletedTask;
    }

    private void Run(Action<PlaybackController> action)
    {
        PlaybackController? current;
        lock (gate) current = active;
        if (current is not null) post(() => action(current));
    }

    private async Task RegisterAsync()
    {
        if (DBusConnection.Session is not { } bus) return;
        try
        {
            registered = true;
            bus.AddMethodHandler(this);
            await bus.RequestNameAsync("org.mpris.MediaPlayer2.aurelia", RequestNameOptions.Default);
        }
        catch (Exception error) when (error is DBusExceptionBase or InvalidOperationException)
        {
            // Another Aurelia window owns the name, or the desktop has no session bus.
        }
    }

    private async Task SetAwakeAsync(bool awake)
    {
        if (DBusConnection.Session is not { } bus) return;
        try
        {
            if (awake && inhibitCookie is null)
            {
                inhibitCookie = await bus.CallMethodAsync(Call(bus, "Inhibit", "ss", (ref MessageWriter writer) =>
                {
                    writer.WriteString("Aurelia");
                    writer.WriteString("Playing a video");
                }), (message, _) => message.GetBodyReader().ReadUInt32(), null);
            }
            else if (!awake && inhibitCookie is { } cookie)
            {
                inhibitCookie = null;
                await bus.CallMethodAsync(Call(bus, "UnInhibit", "u", (ref MessageWriter writer) => writer.WriteUInt32(cookie)));
            }
        }
        catch (DBusExceptionBase)
        {
            // Desktops without the screensaver service keep their own rules.
        }
    }

    private static MessageBuffer Call(DBusConnection bus, string member, string signature, WriteMessageBody body)
    {
        var writer = bus.GetMessageWriter();
        try
        {
            writer.WriteMethodCallHeader(destination: "org.freedesktop.ScreenSaver", path: "/org/freedesktop/ScreenSaver",
                @interface: "org.freedesktop.ScreenSaver", signature: signature, member: member);
            body(ref writer);
            return writer.CreateMessage();
        }
        finally { writer.Dispose(); }
    }

    private void EmitChanged()
    {
        if (!registered || DBusConnection.Session is not { } bus) return;
        try
        {
            var writer = bus.GetMessageWriter();
            try
            {
                writer.WriteSignalHeader(destination: null, path: ObjectPath, @interface: PropertiesInterface, member: "PropertiesChanged", signature: "sa{sv}as");
                writer.WriteString(PlayerInterface);
                WriteProperties(ref writer, PlayerValues().Where(p => p.Name is "PlaybackStatus" or "Metadata" or "CanGoNext" or "CanGoPrevious").ToList());
                writer.WriteArray(Array.Empty<string>());
                bus.TrySendMessage(writer.CreateMessage());
            }
            finally { writer.Dispose(); }
        }
        catch (Exception error) when (error is DBusExceptionBase or InvalidOperationException)
        {
        }
    }

    private static string Status(PlaybackController? player) => player?.State switch
    {
        PlayerState.Playing => "Playing",
        PlayerState.Paused or PlayerState.Loading or PlayerState.Recovering => "Paused",
        _ => "Stopped",
    };

    private static List<Property> RootProperties() =>
    [
        new("CanQuit", (ref MessageWriter w) => w.WriteVariantBool(false)),
        new("CanRaise", (ref MessageWriter w) => w.WriteVariantBool(false)),
        new("HasTrackList", (ref MessageWriter w) => w.WriteVariantBool(false)),
        new("Identity", (ref MessageWriter w) => w.WriteVariantString("Aurelia")),
        new("DesktopEntry", (ref MessageWriter w) => w.WriteVariantString(AppInfo.ApplicationId)),
        new("SupportedUriSchemes", (ref MessageWriter w) => w.WriteVariant(VariantValue.Array(Array.Empty<string>()))),
        new("SupportedMimeTypes", (ref MessageWriter w) => w.WriteVariant(VariantValue.Array(Array.Empty<string>()))),
    ];

    private List<Property> PlayerValues()
    {
        PlaybackController? player;
        lock (gate) player = active;
        var item = player?.Item;
        return
        [
            new("PlaybackStatus", (ref MessageWriter w) => w.WriteVariantString(Status(player))),
            new("Rate", (ref MessageWriter w) => w.WriteVariantDouble(player?.Rate ?? 1)),
            new("Metadata", (ref MessageWriter w) =>
            {
                w.WriteSignature("a{sv}");
                var start = w.WriteDictionaryStart();
                w.WriteDictionaryEntryStart();
                w.WriteString("mpris:trackid");
                w.WriteVariantObjectPath(item is null ? "/org/mpris/MediaPlayer2/TrackList/NoTrack" : "/io/github/lucasfd3/Aurelia/track/" + item.Id.ToString("N"));
                if (item is not null)
                {
                    w.WriteDictionaryEntryStart();
                    w.WriteString("xesam:title");
                    w.WriteVariantString(item.Title);
                    if (item.Kind == MediaKind.Episode && item.ParentTitle is { } show)
                    {
                        w.WriteDictionaryEntryStart();
                        w.WriteString("xesam:album");
                        w.WriteVariantString(show);
                    }
                    w.WriteDictionaryEntryStart();
                    w.WriteString("mpris:length");
                    w.WriteVariantInt64((player?.Duration ?? 0) * 1000);
                }
                w.WriteDictionaryEnd(start);
            }),
            new("Volume", (ref MessageWriter w) => w.WriteVariantDouble(player?.Volume ?? 1)),
            new("Position", (ref MessageWriter w) => w.WriteVariantInt64((player?.Position ?? 0) * 1000)),
            new("MinimumRate", (ref MessageWriter w) => w.WriteVariantDouble(PlayerPolicy.Rates[0])),
            new("MaximumRate", (ref MessageWriter w) => w.WriteVariantDouble(PlayerPolicy.Rates[^1])),
            new("CanGoNext", (ref MessageWriter w) => w.WriteVariantBool(player?.NextItem is not null)),
            new("CanGoPrevious", (ref MessageWriter w) => w.WriteVariantBool(player?.HasPrevious == true)),
            new("CanPlay", (ref MessageWriter w) => w.WriteVariantBool(player is not null)),
            new("CanPause", (ref MessageWriter w) => w.WriteVariantBool(player is not null)),
            new("CanSeek", (ref MessageWriter w) => w.WriteVariantBool(player is not null)),
            new("CanControl", (ref MessageWriter w) => w.WriteVariantBool(true)),
        ];
    }

    private static void WriteProperties(ref MessageWriter writer, List<Property> properties)
    {
        var start = writer.WriteDictionaryStart();
        foreach (var property in properties)
        {
            writer.WriteDictionaryEntryStart();
            writer.WriteString(property.Name);
            property.Write(ref writer);
        }
        writer.WriteDictionaryEnd(start);
    }

    private readonly record struct Property(string Name, WriteMessageBody Write);

    private const string Introspection = """
        <interface name="org.mpris.MediaPlayer2">
          <method name="Raise"/><method name="Quit"/>
          <property name="CanQuit" type="b" access="read"/><property name="CanRaise" type="b" access="read"/>
          <property name="HasTrackList" type="b" access="read"/><property name="Identity" type="s" access="read"/>
          <property name="DesktopEntry" type="s" access="read"/><property name="SupportedUriSchemes" type="as" access="read"/>
          <property name="SupportedMimeTypes" type="as" access="read"/>
        </interface>
        <interface name="org.mpris.MediaPlayer2.Player">
          <method name="Next"/><method name="Previous"/><method name="Pause"/><method name="PlayPause"/><method name="Stop"/><method name="Play"/>
          <method name="Seek"><arg direction="in" type="x" name="Offset"/></method>
          <method name="SetPosition"><arg direction="in" type="o" name="TrackId"/><arg direction="in" type="x" name="Position"/></method>
          <method name="OpenUri"><arg direction="in" type="s" name="Uri"/></method>
          <signal name="Seeked"><arg type="x" name="Position"/></signal>
          <property name="PlaybackStatus" type="s" access="read"/><property name="Rate" type="d" access="readwrite"/>
          <property name="Metadata" type="a{sv}" access="read"/><property name="Volume" type="d" access="readwrite"/>
          <property name="Position" type="x" access="read"/><property name="MinimumRate" type="d" access="read"/>
          <property name="MaximumRate" type="d" access="read"/><property name="CanGoNext" type="b" access="read"/>
          <property name="CanGoPrevious" type="b" access="read"/><property name="CanPlay" type="b" access="read"/>
          <property name="CanPause" type="b" access="read"/><property name="CanSeek" type="b" access="read"/>
          <property name="CanControl" type="b" access="read"/>
        </interface>
        """;
}

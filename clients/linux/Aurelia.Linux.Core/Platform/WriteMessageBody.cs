using Tmds.DBus.Protocol;

namespace Aurelia.Linux.Core.Platform;

/// <summary>
/// MessageWriter owns a mutable cursor. Passing it by value loses the body length, even though
/// bytes were written into its shared buffer, and the desktop bus rejects the malformed message.
/// Every nested body, dictionary and property writer must advance this same writer by reference.
/// </summary>
internal delegate void WriteMessageBody(ref MessageWriter writer);

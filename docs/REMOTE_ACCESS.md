# Watching away from home

Aurelia is made for your home network. To watch while you are away, on a train, at work or on
holiday, connect your device to home through a **VPN** (a private, encrypted tunnel). Aurelia itself
needs no change for this: with the VPN on, the apps reach the server at the same address as at home
and still check its fingerprint.

**Tip:** a home upload is often slower than a film's bitrate. With a server that converts live,
set **Streaming Quality** to Automatic in the app's playback settings (or pick a quality in the
browser player's quality menu) while you are away; the server then sends the quality your
connection carries, and Original plays the file itself again at home.

## Why a VPN and not an open port

**Do not open Aurelia's port in your router.** The server answers only devices from home networks
and VPNs (private addresses such as `192.168.x.x`, `10.x.x.x`, `172.16–31.x.x` and Tailscale's
`100.64.0.0/10`); a request straight from the internet is refused. A port forward therefore would
not work and would only invite attacks. A VPN keeps the server invisible to the internet and lets in
only your own devices.

## Which way suits you

| | Tailscale | Your router's VPN (WireGuard) |
| --- | --- | --- |
| Best for | Most people; any router, also DS-Lite, cable and mobile internet without a public IPv4 address | A router with a built-in WireGuard server, such as a FRITZ!Box |
| Account | A free Tailscale account | None |
| On the server side | Tailscale on an always-on computer at home | Nothing; the router does it |
| On your phone or laptop | The Tailscale app | The WireGuard app |
| Turns on by itself | Yes, when you open an app (optional) | Yes, with *On Demand* in the WireGuard app (optional) |

Both are free and both encrypt everything end to end. If you are unsure, take Tailscale.

## Option 1: Tailscale

Tailscale connects your devices directly, even when your internet provider gives you no public
address. One computer at home that is always on (the Linux server itself is ideal) passes on your
home network, so every device reaches Aurelia at its usual address.

### On the Linux server (or another always-on Linux computer at home)

```sh
curl -fsSL https://tailscale.com/install.sh | sh
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
sudo tailscale up --advertise-routes=192.168.178.0/24
```

Use your own home network instead of `192.168.178.0/24`. You can read it from the server's address:
`192.168.1.50` belongs to `192.168.1.0/24`, `192.168.0.20` to `192.168.0.0/24`, and a FRITZ!Box
uses `192.168.178.0/24`. The last command prints a link; open it and sign in to connect this
computer to your Tailscale account.

Then, once:

1. Open the [Tailscale admin console](https://login.tailscale.com/admin/machines), find the server,
   choose **⋯ › Edit route settings** and approve the route.
2. Optional but recommended: choose **⋯ › Disable key expiry** for the server, so it stays connected.

### On a Docker NAS

Many NAS systems offer Tailscale as a package (Synology Package Center, QNAP App Center, Unraid
plugin). Install it there, sign in, and turn on **subnet routing** for your home network in its
settings; then approve the route as above.

### On your iPhone, iPad, Mac, Linux laptop or Windows PC

1. Install the Tailscale app ([App Store](https://apps.apple.com/app/tailscale/id1470499037), or
   [tailscale.com/download](https://tailscale.com/download) for Mac, Linux and Windows).
2. Sign in with the **same** account.
3. On Linux, run `sudo tailscale up --accept-routes`; on the other systems subnet routes are used
   automatically.
4. Away from home, turn Tailscale on and open Aurelia. It connects as if you were at home.

### When the Mac hosts the server

The Mac cannot easily pass on the home network with the Tailscale app. Either let another
always-on Linux computer do it as above, or use your router's VPN (option 2), which is usually
simpler.

## Option 2: Your router's VPN (WireGuard)

### FRITZ!Box

Needs FRITZ!OS 7.50 or newer and a public IPv4 address or MyFRITZ!.

1. In the FRITZ!Box, open **Internet › Permit Access › VPN (WireGuard)**
   (*Internet › Freigaben › VPN (WireGuard)*) and add a connection for **a single device**.
2. Scan the QR code with the WireGuard app on the iPhone or iPad, or save the configuration file
   and import it in WireGuard on the Mac, Linux PC or Windows PC.
3. Away from home, turn the VPN on and open Aurelia.

### Other routers and VPN boxes

Most current routers and many NAS systems include a WireGuard server (for example UniFi, OpenWrt,
GL.iNet, ASUS, TP-Link Omada, Synology VPN Server). The steps are always similar:

1. Turn on the WireGuard server in the router and add a **peer** (client) for each device.
2. Allow the peer to reach your **home network** (often called *LAN access* or *Allowed IPs*
   containing your home network, such as `192.168.1.0/24`).
3. Import the configuration or QR code into the WireGuard app on the device.

If your internet line has no public IPv4 address (DS-Lite, many cable and mobile connections), a
router VPN usually cannot be reached from outside; use Tailscale instead.

### Connecting automatically

The WireGuard app on iPhone, iPad and Mac can turn the tunnel on by itself: edit the tunnel,
turn on **On Demand** and choose *Wi-Fi* except your home network, plus *Cellular*. Tailscale can do
the same with its *VPN On Demand* setting on Apple devices.

## Good to know

- **Picture quality depends on your home upload.** The apps play the original files. A home line
  with 40 Mbit/s upload plays most movies smoothly; a large 4K remux may need more than that and
  then pauses to load. On mobile data, a two-hour 1080p movie can use several gigabytes.
- **Downloads are often better for travel.** On the Mac, Linux, iPhone and iPad apps, download
  a title at home and watch it offline on the way, without any VPN.
- **A sleeping server.** A VPN does not carry Wake-on-LAN from away. If the server sleeps to save
  power, wake it with your router (FRITZ!Box: MyFRITZ!App › *Home Network › device › Start
  computer*), keep it awake during set hours (`sudo aurelia sleep server --awake 17:00-23:30`),
  choose "Stop only Aurelia" or "Always on" (`sudo aurelia sleep`), or let Tailscale run on a
  device that is always on.
- **The Apple TV** usually stays at home and needs none of this.
- **Browsers** work the same way: with the VPN on, open the server's usual address.
- **Watch Together across homes** works too, as long as every device is connected to the same VPN.

# Watching away from home

Aurelia is made for your home network. To watch while you are away, connect your device to
your home network through a VPN. Aurelia itself needs no change for this: the apps reach the
server at the same address as at home and still check its fingerprint.

**Do not open Aurelia's port in your router.** The server answers only devices from home
networks and VPNs (private addresses such as `192.168.x.x`, `10.x.x.x` and Tailscale's
`100.64.0.0/10`); a request straight from the internet is refused, so a port forward would not
work and would only invite attacks.

Two good ways, both free:

| | FRITZ!Box VPN (WireGuard) | Tailscale |
| --- | --- | --- |
| Needs | A FRITZ!Box with FRITZ!OS 7.50 or newer and a public IPv4 address or MyFRITZ! | A free Tailscale account; works behind any router, also DS-Lite and mobile internet |
| On the server | Nothing | Install Tailscale once |
| On your Mac, iPhone, iPad or Linux PC | The WireGuard app | The Tailscale app |

## Option 1: VPN of the FRITZ!Box

1. In the FRITZ!Box, open **Internet › Permit Access › VPN (WireGuard)**
   (*Internet › Freigaben › VPN (WireGuard)*) and add a connection for **a single device**.
2. Scan the QR code with the WireGuard app on the iPhone or iPad, or import the configuration
   file in WireGuard on the Mac or Linux PC.
3. Away from home, turn the VPN on and open Aurelia. It connects as if you were at home.

## Option 2: Tailscale

Tailscale connects your devices directly, even when your internet provider gives you no
public address. Install it on the server and let it pass on your home network, so the server
keeps its usual address:

```sh
curl -fsSL https://tailscale.com/install.sh | sh
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
sudo tailscale up --advertise-routes=192.168.178.0/24
```

Use your own home network instead of `192.168.178.0/24` (a FRITZ!Box uses that one; many other
routers use `192.168.1.0/24` or `192.168.0.0/24`). Then approve the route in the Tailscale admin
console under **Machines › Edit route settings**, install the Tailscale app on your other devices,
sign in with the same account and turn on **Use Tailscale subnets** where the app offers it.

When a Mac hosts the server, the FRITZ!Box VPN is the simpler choice. With Tailscale, let a Linux
computer that is always on pass on the home network as above, and the Mac keeps its usual address.

## Good to know

- **Picture quality depends on your home upload.** The apps play the original files. A home line
  with 40 Mbit/s upload plays most movies smoothly; a large 4K remux may need more than that and
  then pauses to load.
- **A sleeping server.** A VPN does not carry Wake-on-LAN from away. If the server sleeps to save
  power, wake it with the MyFRITZ!App (*Home Network › device › Start computer*), choose
  "Stop only Aurelia" or "Always on" instead (`sudo aurelia sleep`), or let Tailscale run on a
  device that is always on.
- **Apple TV** usually stays at home and needs none of this.
- **Browsers** work the same way: with the VPN on, open the server's usual address.

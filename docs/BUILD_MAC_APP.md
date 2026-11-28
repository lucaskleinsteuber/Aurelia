# Build Tarven for Mac yourself

The Tarven for Mac download on GitHub starts **only on Macs registered to the developer's Apple
account**. Tarven is free and doesn't pay for Apple's developer program, so Apple doesn't let the
download run on other Macs. On your Mac you have two choices:

- **Use Tarven in your browser** (Safari, Chrome, Firefox). It does everything the Mac app does,
  from setting up the server to editing your library. Nothing to build. See
  [Getting started](GETTING_STARTED.md).
- **Build the Mac app yourself**, as described here. It takes about half an hour the first time,
  most of it waiting, and needs no programming knowledge. You type one command; this page explains
  everything around it.

The app you build is yours: signed with your own free Apple ID, it runs on your Mac for a year
(as long as your certificate is valid), and building it again updates it.

> [!NOTE]
> This way is tested on the developer's Mac. With another Apple ID it works the same way, but it
> could not be tried on a stranger's Mac. If a step fails, the script says what to do; the
> [last section](#when-something-goes-wrong) lists the usual problems.

## What you need

- A Mac with **macOS 26** or newer (Apple menu › About This Mac shows the version).
- About **40 GB of free space** (Xcode alone takes most of it).
- An **Apple ID** (the one you use for the App Store is fine). It costs nothing.
- An internet connection.

## Step 1: Install Xcode

Xcode is Apple's free app for building apps.

1. Open the **App Store**, search for **Xcode** and click **Get** (it is large; the download can
   take an hour).
2. Open Xcode once. If it asks to install additional components, click **Install** and wait.
   You can close Xcode afterwards.

## Step 2: Add your Apple ID to Xcode and create a certificate

The certificate is what lets your Mac run the app you build.

1. Open Xcode, then in the menu bar **Xcode › Settings…** (or press ⌘,).
2. Click **Accounts**, then the **+** at the bottom left, choose **Apple ID** and sign in.
3. Select your account (it shows *Personal Team*) and click **Manage Certificates…**.
4. Click the **+** at the bottom left and choose **Apple Development**. A line with your name
   appears. Click **Done** and close Xcode.

## Step 3: Install Homebrew (if you don't have it)

Homebrew installs two small tools that the build needs (cmake and ninja, used for subtitles from
speech).

1. Open **Terminal** (in Applications › Utilities, or press ⌘ Space and type *Terminal*).
2. Copy the line shown on [brew.sh](https://brew.sh) into Terminal and press Return. It asks for
   your Mac password (nothing appears while you type; that's normal). At the end it may show two
   or three "Next steps" lines; copy and run them too.
3. Close Terminal and open it again.

If you are unsure whether you already have it: type `brew --version` and press Return. A version
number means you have it.

## Step 4: Get Tarven's source code

In Terminal, type these two lines (press Return after each):

```sh
git clone https://github.com/lucaskleinsteuber/Tarven.git
cd Tarven
```

The first line downloads Tarven into a folder named *Tarven* in your home folder. If your Mac
asks to install the "command line developer tools", click **Install** and run the line again.

## Step 5: Build Tarven

Still in Terminal, in the *Tarven* folder:

```sh
zsh scripts/build-mac-app-yourself.sh
```

The script:

1. checks macOS and Xcode;
2. offers to install cmake and ninja with Homebrew (type `y` and press Return);
3. downloads the .NET SDK from Microsoft into the Tarven folder (it builds the server inside the
   app; nothing is installed elsewhere on your Mac);
4. finds your certificate. macOS may ask for your Mac password to let it sign; enter it and click
   **Always Allow**;
5. builds the app for your Mac's processor (Apple silicon or Intel). This takes **15 to 40
   minutes** the first time and prints a lot of text; let it run.

At the end it asks: *Copy Tarven to Applications now?* Type `y` and press Return. Or drag
*Tarven.app* from the window it opens into Applications yourself.

## Step 6: Open Tarven

Open **Tarven** from Applications. Because you built it yourself on this Mac, macOS opens it
without a warning. Choose **Set Up This Mac** to keep your library on this Mac, or **Connect to an
Existing Server** if Tarven already runs on another computer at home. [Getting
started](GETTING_STARTED.md) walks through both.

## Updating

The update button in Tarven offers the developer's downloads, which don't run on your Mac, so a
copy you built yourself doesn't look for updates. To update, open Terminal and run:

```sh
cd Tarven
git pull
zsh scripts/build-mac-app-yourself.sh
```

Your library, settings and sign-ins stay. Do this at least once a year: the app stops starting
when your certificate expires (Xcode › Settings › Accounts › Manage Certificates shows the date).

## When something goes wrong

| The script says | What helps |
| --- | --- |
| *Xcode is not installed or not selected* | Install Xcode (step 1), open it once, then run `sudo xcode-select -s /Applications/Xcode.app` |
| *Xcode has not finished its first start* | Open Xcode and let it install its components, or run `sudo xcodebuild -runFirstLaunch` |
| *Homebrew is not installed* | Do step 3, open a new Terminal window, run the script again |
| *No Apple Development certificate was found* | Do step 2 |
| *macOS did not let this certificate sign* | Run the script again; when macOS asks for your password, choose **Always Allow** |
| *The .NET SDK could not be installed* | Check the internet connection and run the script again |
| `git: command not found` | Install the command line tools when macOS offers them, or run `xcode-select --install` |
| The build stops with an error near the end | Run the script once more (a download may have broken off). If it stops again, copy the last lines into a new [issue](https://github.com/lucaskleinsteuber/Tarven/issues) |
| Tarven doesn't open after a year | Your certificate expired: create a new one (step 2) and build again |

For developers: the script runs `scripts/build-macos-release.sh` with `TARVEN_TEAM_ID` (your
team), `TARVEN_SIGNING_IDENTITY`, `TARVEN_DISTRIBUTION=profileless-development` and
`TARVEN_MAC_ARCH`. The App Group carries your team ID; the sandbox and all other protections stay
as in the published app. [Distribution and updates](FREE_DISTRIBUTION.md) explains the signing.

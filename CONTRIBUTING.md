# Contributing to Aurelia

Thank you for helping. Aurelia is maintained by one person in their free time, so clear reports
and focused changes help the most.

## Questions and problems

- Look in the [guides](docs/README.md) and [Troubleshooting](docs/TROUBLESHOOTING.md) first.
- Search the [issues](https://github.com/lucaskleinsteuber/Aurelia/issues) before opening a new one.
- Use the **Bug report** or **Feature request** form. Name the app, its version
  (*Settings › About*) and your system.
- Never post passwords, pairing codes, tokens, real media paths or other private information.
- Report security problems privately, as described in the [security policy](SECURITY.md).

## Changing the code

For changes that touch several apps, the server API or stored data, open an issue first to agree
on the approach. Keep pull requests focused on one problem.

The repository holds:

| Folder | What | Language |
| --- | --- | --- |
| `src/Aurelia.Server` | The server and the browser app (`WebApp`, plain HTML, CSS and JavaScript) | C# / .NET 10 |
| `src/Aurelia.Contracts` | Requests and responses shared by the server and the Linux app | C# |
| `clients/macos` | Aurelia for Mac | Swift / SwiftUI |
| `clients/linux` | Aurelia for Linux | C# / Avalonia |
| `clients/tvos` | Aurelia for Apple TV | Swift / SwiftUI |
| `clients/ios` | Aurelia for iPhone and iPad | Swift / SwiftUI |
| `packaging` | Linux server packages and Docker | Shell |
| `scripts` | Building, testing and releasing | Shell |
| `tests` | Server and browser app tests | C# / JavaScript |

[`AGENTS.md`](AGENTS.md) holds the full project rules (for people and for AI coding assistants).
The most important ones:

- Media files are only ever read. Never write next to them, and never store converted video.
- Use invented test data only; never real libraries, credentials or personal logs.
- Builds must be free of warnings; warnings count as errors.
- Each app has its own version; only the build number of the app you changed rises.
- User-visible changes go into [`CHANGELOG.md`](CHANGELOG.md) under *Unreleased*, in English.

## Running the checks

Use the pinned SDKs; the scripts find them. Run the checks for what you changed:

```sh
dotnet format Aurelia.slnx --verify-no-changes   # server formatting
dotnet build Aurelia.slnx -c Release             # server, warning-free
dotnet test Aurelia.slnx -c Release              # server tests
node --test "tests/WebApp/*.test.mjs"            # browser app
zsh scripts/test-linux-app.sh                    # Linux app (headless, no screen needed)
AURELIA_LOGIC_ONLY=1 zsh scripts/test-macos.sh   # Mac app without UI tests
zsh scripts/test-tvos-logic.sh                   # Apple TV logic
zsh scripts/test-ios-logic.sh && zsh scripts/build-ios.sh   # iPhone and iPad
```

UI tests (`scripts/test-macos.sh`, `scripts/test-tvos-ui.sh`) take over the screen or a simulator.
[Building and verification](docs/TRANSPORT_TESTING.md) describes every check in detail.

In the pull request, say what you ran, on which systems, and what you could not test.

## Code of conduct

Everyone taking part is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).

# Security policy

Aurelia keeps people's libraries, profiles and viewing history, so security reports are taken
seriously. Thank you for reporting responsibly.

## Supported versions

| Product | Supported |
| --- | --- |
| Every app and the server, version 2.0.0 and newer | Yes |
| Versions before 2.0.0 | No; please update first |

## Reporting a vulnerability

**Please do not open a public issue.** Report it privately through
[GitHub's private vulnerability reporting](https://github.com/lucaskleinsteuber/Aurelia/security/advisories/new)
(the *Report a vulnerability* button on the Security tab).

Include:

- the affected app or server, its version and platform,
- what an attacker could do and what they need for it (for example: a device in the same network,
  a paired device, a viewer profile),
- steps to reproduce with invented data.

Remove tokens, passwords, pairing codes, media paths and personal information from attachments.
Keep the details private while the problem is investigated and fixed; you will get an answer as
soon as possible, and credit in the release notes if you like.

## What is in scope

- The server's HTTPS API, sign-in, pairing, profiles, PINs and permissions.
- Any way to read another profile's history or private collections, to reach the server from the
  internet, or to make the server write next to media or outside its data folder.
- The update paths of the Mac app, the Linux app and the Linux server.

How Aurelia is meant to protect these is described in the [security model](docs/SECURITY_MODEL.md).

## Out of scope

- Problems that need full control of the server computer or an administrator account already.
- Exposing the server to the internet with a port forward, which the documentation advises
  against and the server refuses.
- Vulnerabilities in third-party services such as TMDB or OpenSubtitles; report those to them.

# Real-socket transport and soak verification

Run `sh scripts/test-server-transport.sh` with the pinned .NET SDK available.
The default is a two-hour, four-client run. A quick diagnostic run is
`sh scripts/test-server-transport.sh 30 2`.

The probe owns an isolated synthetic server, database, accounts, byte-pattern
media and dynamically selected loopback ports. It never opens existing server
data or personal media, never disables certificate validation globally, and
stops only its own process. Its temporary private data is removed after the
report is written. Ctrl+C requests cancellation and owned-host cleanup; the
server also observes the probe's private parent pipe lifetime. Compiled host
payloads are copied into the owned test directory, so subsequent builds cannot
change a server that is already running. CPU is sampled before shutdown and is
a lower bound rather than a measurement of final shutdown work.

Verification uses real Kestrel sockets, not an in-memory test transport:

- HTTP/1.1 over loopback and exact HTTP/1.1 / HTTP/2 over HTTPS with the owned
  certificate's SPKI pin, validity dates and hostname checks.
- A wrong SPKI pin is rejected. A local redirect test confirms credentials are
  not forwarded through automatic redirects.
- Login, pairing and self-session revocation; two users with separate library
  grants; unauthorized catalog/playback attempts.
- Byte ranges and HEAD, progress, interrupted streams and cancelled long polls.
- Restart with the same identity, session and playback progress, followed by
  simultaneous clients and connection churn. Playback tickets are renewed
  every fifteen minutes and before reported expiry, not reused indefinitely.

Reports contain bounded event counts, response timings, sampled server memory
and process CPU, actual soak duration, server version, a compiled-payload hash,
and bounded time-window memory/CPU samples so growth can be inspected.
Warnings and errors retain only validated logger categories and event IDs.
Credentials, pairing codes, playback URLs and raw server logs
are never exported. A functional pass is separate from native TLS-close log
diagnostics: `tlsCloseDiagnosticsRequireInvestigation` must be reviewed before
claiming that a previously observed transport error is fixed. Unexpected host
exit or a required forced shutdown fails the functional run. This probe does
not prove codec decoding, GUI playback, hardware equivalence or Internet access
safety. Non-notarized package first launch and native UI tests remain separate.

## Mandatory native playback gate

Before building the signed staged candidate, capture its client code and
compiler-configuration fingerprint from the repository root:

```sh
export AURELIA_CANDIDATE_CLIENT_SOURCE_FINGERPRINT="$(ruby tools/macos/playback-client-source-fingerprint.rb "$(pwd -P)")"
```

Build that candidate without changing the captured client source/configuration,
then run the playback gate with the same exported fingerprint:

```sh
zsh scripts/test-playback-full-chain.sh /path/to/staged/Aurelia.app 1800
```

The mandatory all-format run requires this fingerprint and checks it before the
test-host build, immediately before test launch, and after the run. A mismatch
fails the gate rather than certifying different client code. This is source and
compiler-configuration provenance, not an assertion that the XCTest host binary
is identical to the untouched staged executable.

This separate release gate exercises the production API, the exact packaged
server, pinned HTTPS, the loopback relay, and VLC with real video and audio
output. The ordinary `test-macos.sh` unit/UI gate excludes this class explicitly;
it is not a substitute for this gate. Running the full-chain class without its
isolated server configuration fails rather than reporting a skipped pass.

The gate generates AVI, MKV and MP4 sources (including MP4 metadata at the end),
checks HTTP ranges, seeking, pause/resume, saved progress, ticket renewal, and
controlled server/source outages. AVI and MKV play for at least two minutes each;
the duration argument controls the MP4 soak, with 1800 seconds required for the
30-minute release check. A successful shorter all-format run can exit zero with
`allFormatSuiteSucceeded` and `diagnosticSubsetSucceeded`, but `passed` and
`requiredFullGateComplete` remain false. Those release-acceptance fields require
at least 1800 seconds, Release compilation, all formats, the completed mandatory
test, and verified client source provenance. The actual test host's version and
build must also match the staged candidate before launch. Debug runs remain
diagnostic even when they reach the full duration. The 64-second synthetic sources are replayed by seeking
inside the same decoder during the soak; this tests a continuous playback chain,
not a 30-minute movie or every possible codec. Real VLC counters must show both
displayed pictures and played audio buffers. Human hearing and picture quality
remain a separate check.

The all-format gate also provisions a separate synthetic series through the
production library APIs, using two numbered copies of its own generated MP4.
It saves unfinished progress, resumes from that server value, and lets the real
decoder reach the first episode's EOF. The production controller must start the
second episode with actual video/audio output and save the first as completed;
no decoder-ended callback or manual next-episode command is injected. A
single-format diagnostic run omits this extra series case and cannot certify
the full gate. Phase messages and minute-by-minute numeric output counters are
printed without source paths, credentials or media IDs.

To investigate only real episode completion and handoff, select
`AURELIA_FULL_CHAIN_TEST_FILTER=AureliaTests/PlaybackFullChainTests/testAutomaticEpisodeHandoffDiagnostic`
with a short run. This retains the production callback timing and real decoding,
but deliberately does not certify the all-format or 30-minute gate.

The signed test host keeps its sandbox and signing identity. A test-only grant
is restricted to that run's exact generated-fixture directory to simulate a
user-selected folder. Its build-for-testing configuration also enables and
verifies `get-task-allow` so XCTest can inject its bundle, while retaining the
Release hardened-runtime setting. The staged candidate, project settings and
production entitlement files are never changed. This test therefore checks
Release-compiled playback code, not the untouched candidate's distribution
entitlement runtime; signature and candidate launch remain separate gates.
The test host is compiled for the local architecture; the release build separately
verifies the universal client and both server payloads.
Test accounts, database, certificates and progress are isolated. Short tickets are enabled only
in the server's `Testing` environment; ordinary tickets retain their lifetime.
The private runtime is removed after copying redacted evidence and the XCTest
result bundle into the configured external artifact directory.

The server-outage case deliberately makes a fresh playback request because a
small source can already be buffered. It proves bounded authorization recovery,
not a physical cable pull during an active transfer. The source-outage case
renames only a generated test folder. Hardware media-key and AirPods behavior,
installed-host startup, and any explicitly approved personal-source check are
recorded separately; none is implied by a full-chain pass.

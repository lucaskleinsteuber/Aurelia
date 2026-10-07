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

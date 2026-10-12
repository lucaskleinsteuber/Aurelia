#!/usr/bin/env ruby
# External ten-minute source-read ceiling, independent of XCTest cooperation.
# This is NOT a network control endpoint. Only the wrapper's already-validated
# owned server child (exact PID + executable + --data-dir) may be signalled.
require 'open3'

begin
  owned_run_valid = false
  raise ArgumentError unless ARGV.length == 5
  server_pid, executable, data_root, run, marker = ARGV
  owned_parent = File.join(Dir.home, 'Library/Caches/Aurelia/TestRuns')
  raise ArgumentError unless server_pid.match?(/\A[1-9][0-9]+\z/) &&
                            run == ENV.fetch('EVIDENCE_RUN_ROOT') &&
                            File.dirname(run) == owned_parent &&
                            File.basename(run).start_with?('playback-evidence-') && File.realpath(run) == run &&
                            data_root == File.join(run, 'ServerData') &&
                            marker == File.join(run, 'source-read-deadline.private') &&
                            File.directory?(data_root) && File.realpath(data_root) == data_root &&
                            File.executable?(executable) && File.realpath(executable) == executable
  owned_run_valid = true
  inspect = lambda do
    command, status = Open3.capture2('/bin/ps', '-p', server_pid, '-o', 'command=')
    next nil unless status.success?
    owner, status = Open3.capture2('/bin/ps', '-p', server_pid, '-o', 'uid=')
    next nil unless status.success?
    started, status = Open3.capture2('/bin/ps', '-p', server_pid, '-o', 'lstart=')
    next nil unless status.success?
    expected = executable + ' --data-dir ' + data_root + ' '
    raise ArgumentError unless owner.strip == Process.uid.to_s && command.strip.start_with?(expected)
    [command.strip, started.strip]
  end
  original = inspect.call
  raise ArgumentError unless original
  File.write(File.join(run, 'source-read-watchdog-ready.private'), 'owned_source_server_validated')
  # The timer starts immediately before XCTest. Killing this exact source server
  # at585s leaves a15s safety margin under the human-approved ten-minute ceiling.
  sleep 585
  current = inspect.call
  exit 0 unless current
  raise ArgumentError unless current == original
  File.write(marker, 'authorized_source_read_deadline_reached')
  Process.kill('KILL', Integer(server_pid))
rescue Errno::ESRCH
  exit 0
rescue StandardError
  File.write(File.join(run, 'source-read-watchdog-failed.private'), 'owned_source_watchdog_failed') if
    owned_run_valid
  warn 'Playback evidence failed: authorized_source_watchdog_guard'
  exit 1
end

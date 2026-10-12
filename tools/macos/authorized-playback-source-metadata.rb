#!/usr/bin/env ruby
# Metadata only: never open/read/hash/copy media content or enumerate its folder.
# The exact authorized source is deliberately absent from exported evidence.
require 'json'

begin
  raise ArgumentError unless ARGV.length == 2 && %w[before after].include?(ARGV[0])
  mode, output = ARGV
  run = ENV.fetch('EVIDENCE_RUN_ROOT')
  source = ENV.fetch('AURELIA_AUTHORIZED_MEDIA_FILE')
  raise ArgumentError unless ENV['AURELIA_AUTHORIZED_PLAYBACK'] == 'BREAKING_BAD_S01E01_10_MINUTES'
  owned_parent = File.join(Dir.home, 'Library/Caches/Aurelia/TestRuns')
  raise ArgumentError unless File.dirname(run) == owned_parent &&
                            File.basename(run).start_with?('playback-evidence-') && File.realpath(run) == run &&
                            output.start_with?(run + '/') && !File.symlink?(output) &&
                            source.start_with?('/') && File.expand_path(source) == source &&
                            File.realpath(source) == source
  metadata = File.lstat(source)
  raise ArgumentError unless metadata.file? && !metadata.symlink? && metadata.size.positive?
  snapshot = { size: metadata.size, modifiedSeconds: metadata.mtime.to_i,
               modifiedNanoseconds: metadata.mtime.nsec, device: metadata.dev, inode: metadata.ino }
  File.write(output, JSON.generate(snapshot))
  if mode == 'before'
    manifest = [{ format: 'AUTHORIZED', mediaId: '94efcf84-939f-47a8-9d7c-6e0f494c2710', path: source }]
    File.write(File.join(run, 'authorized-source.private.json'), JSON.generate(manifest))
  end
rescue StandardError
  warn 'Playback evidence preparation failed: authorized_source_metadata_guard'
  exit 1
end

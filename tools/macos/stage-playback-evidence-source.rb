#!/usr/bin/env ruby
# A source-only snapshot for an isolated signed test host. This does not copy
# an app bundle, personal runtime state, Git metadata, or arbitrary untracked files.
require 'fileutils'
require 'open3'

begin
  raise ArgumentError unless ARGV.length == 3
  repository, destination, overlay = ARGV.map { |value| File.expand_path(value) }
  run = ENV.fetch('EVIDENCE_RUN_ROOT')
  owned_parent = File.join(Dir.home, 'Library/Caches/Aurelia/TestRuns')
  raise ArgumentError unless File.dirname(run) == owned_parent &&
                            File.basename(run).start_with?('playback-evidence-') &&
                            File.realpath(run) == run && destination == File.join(run, 'Source') &&
                            File.directory?(destination) && File.realpath(destination) == destination
  raise ArgumentError unless File.realpath(repository) == repository &&
                            overlay == File.join(repository, 'tools/macos/PlaybackAuthorizedSourceTests.swift')
  tracked, status = Open3.capture2('git', '-C', repository, 'ls-files', '-z', '--',
                                  'clients/macos', 'Directory.Build.props',
                                  'Directory.Packages.props', 'global.json')
  raise ArgumentError unless status.success?
  new_code, status = Open3.capture2('git', '-C', repository, 'ls-files', '--others',
                                   '--exclude-standard', '-z', '--',
                                   'clients/macos/Aurelia', 'clients/macos/AureliaServerHost')
  raise ArgumentError unless status.success?
  paths = tracked.split("\0") + new_code.split("\0").select { |path| path.end_with?('.swift') }
  paths.uniq.each do |relative|
    raise ArgumentError if relative.start_with?('/') || relative.split('/').include?('..')
    source = File.join(repository, relative)
    next unless File.exist?(source) # Preserve an intentional tracked deletion.
    raise ArgumentError unless File.file?(source) && !File.symlink?(source) &&
                              File.realpath(source).start_with?(repository + '/')
    target = File.join(destination, relative)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.copy_file(source, target)
  end
  raise ArgumentError unless File.file?(overlay) && !File.symlink?(overlay)
  FileUtils.copy_file(overlay, File.join(destination, 'clients/macos/AureliaTests/PlaybackAuthorizedSourceTests.swift'))
  puts 'Owned source-only playback snapshot prepared; production working tree and installed apps unchanged.'
rescue StandardError
  warn 'Playback evidence preparation failed: isolated_source_snapshot'
  exit 1
end

#!/usr/bin/env ruby
# Build provenance for code/compiler configuration only. Never hash media,
# artwork, personal runtime state or app bundles. Run immediately BEFORE the
# final candidate build, then supply this fingerprint to the evidence wrapper.
require 'digest'
require 'open3'

begin
  raise ArgumentError unless ARGV.length == 1 || (ARGV.length == 2 && ARGV[1] == '--owned-snapshot')
  repository = File.expand_path(ARGV[0])
  raise ArgumentError unless File.realpath(repository) == repository
  roots = %w[clients/macos/Aurelia clients/macos/AureliaServerHost
             clients/macos/Configuration clients/macos/Aurelia.xcodeproj]
  if ARGV[1] == '--owned-snapshot'
    run = ENV.fetch('EVIDENCE_RUN_ROOT')
    owned_parent = File.join(Dir.home, 'Library/Caches/Aurelia/TestRuns')
    raise ArgumentError unless File.dirname(run) == owned_parent &&
                              File.basename(run).start_with?('playback-evidence-') &&
                              File.realpath(run) == run && repository == File.join(run, 'Source')
    paths = roots.flat_map do |root|
      Dir.glob(File.join(repository, root, '**', '*')).map { |path| path.delete_prefix(repository + '/') }
    end
  else
    tracked, status = Open3.capture2('git', '-C', repository, 'ls-files', '-z', '--', *roots)
    raise ArgumentError unless status.success?
    new_code, status = Open3.capture2('git', '-C', repository, 'ls-files', '--others',
                                     '--exclude-standard', '-z', '--',
                                     'clients/macos/Aurelia', 'clients/macos/AureliaServerHost')
    raise ArgumentError unless status.success?
    paths = tracked.split("\0") + new_code.split("\0").select { |path| path.end_with?('.swift') }
  end
  paths = paths.uniq.sort.select do |path|
    path.end_with?('.swift', '.plist', '.entitlements', '.xcconfig', '.pbxproj', '.xcscheme')
  end
  raise ArgumentError if paths.empty?
  digest = Digest::SHA256.new
  paths.each do |relative|
    raise ArgumentError if relative.start_with?('/') || relative.split('/').include?('..')
    source = File.join(repository, relative)
    next unless File.exist?(source) # Account for an intentional tracked deletion.
    raise ArgumentError unless File.file?(source) && !File.symlink?(source) &&
                              File.realpath(source).start_with?(repository + '/')
    digest.update(relative + "\0")
    digest.update(File.binread(source))
    digest.update("\0")
  end
  puts digest.hexdigest.upcase
rescue StandardError
  warn 'Playback evidence preparation failed: client_code_provenance'
  exit 1
end

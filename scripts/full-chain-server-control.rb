#!/usr/bin/env ruby
# Test-only process supervisor. It can stop/restart only the exact packaged
# server child it creates, with one owned data directory and the same certificate.
require 'json'
require 'securerandom'
require 'socket'
require 'timeout'

server, data_root, http_port, https_port, manifest, output, parent = ARGV
abort 'Invalid isolated server configuration.' unless ARGV.length == 7 &&
  File.executable?(server) && server.match?(%r{/Contents/Resources/Server/osx-(arm64|x64)/Aurelia\.Server\z}) &&
  data_root.match?(%r{/Library/Caches/Aurelia/TestRuns/full-chain-[^/]+/ServerData\z}) &&
  File.directory?(data_root) && [manifest, output].all? { |path| path.start_with?(File.dirname(data_root) + '/') } &&
  [http_port, https_port].all? { |port| port.match?(/\A\d+\z/) && (1024..65535).cover?(port.to_i) } &&
  parent.match?(/\A\d+\z/)

control = TCPServer.new('127.0.0.1', 0)
secret = SecureRandom.hex(32)
child = nil
forced_shutdown = false
restarts = 0
closing = false
%w[TERM INT].each { |signal| Signal.trap(signal) { closing = true } }

alive = lambda do |pid|
  begin
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end

stop = lambda do
  if child
    begin
      Process.kill('TERM', child)
    rescue Errno::ESRCH
      nil
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
    loop do
      begin
        break if Process.waitpid(child, Process::WNOHANG)
      rescue Errno::ECHILD
        break
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        forced_shutdown = true
        begin
          Process.kill('KILL', child)
          Process.waitpid(child)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
        break
      end
      sleep 0.05
    end
    child = nil
  end
end

start = lambda do
  raise 'Server child already running.' if child
  child = Process.spawn(
    {'ASPNETCORE_ENVIRONMENT' => 'Testing', 'AURELIA_TEST_TICKET_LIFETIME_SECONDS' => '360',
     'AURELIA_HOST_PARENT_PID' => Process.pid.to_s, 'Logging__LogLevel__Default' => 'Warning'},
    server, '--data-dir', data_root, '--urls', "http://127.0.0.1:#{http_port}",
    '--lan', '--lan-port', https_port, out: [output, 'a', 0o600], err: [:child, :out])
end

begin
  start.call
  File.open(manifest, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(controlURL: "http://127.0.0.1:#{control.addr[1]}/#{secret}"))
  end
  until closing
    break unless alive.call(parent.to_i)
    if child
      begin
        child = nil if Process.waitpid(child, Process::WNOHANG)
      rescue Errno::ECHILD
        child = nil
      end
    end
    next unless IO.select([control], nil, nil, 0.2)
    socket = control.accept
    begin
      response = Timeout.timeout(15) do
        line = socket.gets(1025)
        raise 'Invalid control request.' unless line && line.bytesize <= 1024
        method, path, protocol = line.split(' ', 3)
        raise 'Invalid control request.' unless method == 'POST' && protocol&.start_with?('HTTP/1.')
        received = 0
        loop do
          header = socket.gets(1025)
          raise 'Invalid control headers.' unless header && header.bytesize <= 1024
          received += header.bytesize
          raise 'Control headers too large.' if received > 8192
          break if header == "\r\n"
        end
        action = path.delete_prefix("/#{secret}/")
        raise 'Invalid control action.' unless path == "/#{secret}/#{action}"
        case action
        when 'stop'
          stop.call
        when 'restart'
          stop.call
          start.call
          restarts += 1
        when 'status'
          nil
        else
          raise 'Invalid control action.'
        end
        JSON.generate(running: !child.nil?, restarts: restarts, forcedShutdown: forced_shutdown)
      end
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{response.bytesize}\r\nConnection: close\r\n\r\n#{response}")
    rescue StandardError
      socket.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") rescue nil
    ensure
      socket.close
    end
  end
ensure
  stop.call
  control.close
end
exit(forced_shutdown ? 1 : 0)

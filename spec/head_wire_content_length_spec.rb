# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# HEAD Content-Length ON THE WIRE (RFC 9110 s9.3.2 / RFC 7230 s3.3.2).
#
# The sibling head_no_body_conformance_spec drives the dispatcher in-process and
# reads a response object - which can neither hold a duplicate header nor show
# what the SOCKET SERVER finally writes. The real-world failure lives in the
# transport (it bit tina4-php: the server recomputed Content-Length from the
# already-stripped empty HEAD body and shipped `Content-Length: 0`), and a
# strict proxy also 502s a DUPLICATE Content-Length. Both are only visible on
# the raw wire, so this boots the real built-in server and reads bytes off a
# socket. Ruby already behaves correctly; this LOCKS IT IN at parity with the
# Python / PHP / Node wire checks.
#
# NO MOCKS: a real `tina4ruby serve` child, a real socket, reaped in an ensure.
require "spec_helper"
require "socket"
require "timeout"
require "rbconfig"
require "tmpdir"
require "fileutils"

RSpec.describe "HEAD Content-Length on the wire (RFC 9110 s9.3.2)" do
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Raw HTTP request over a socket -> [content_length_count, content_length_value, body_bytes].
  def raw(port, method, path)
    socket = Socket.tcp("127.0.0.1", port, connect_timeout: 5)
    socket.write("#{method} #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n")
    data = +""
    begin
      Timeout.timeout(5) { loop { data << socket.readpartial(8192) } }
    rescue EOFError, Timeout::Error, Errno::ECONNRESET
      # whatever arrived is the answer
    ensure
      socket.close
    end
    head, body = data.split("\r\n\r\n", 2)
    body ||= ""
    count = head.scan(/^content-length:/i).length
    value = head[/^content-length:\s*(\d+)/i, 1]&.to_i || -1
    [count, value, body.bytesize]
  end

  it "answers a routed HEAD with exactly one Content-Length equal to the GET length and no body" do
    dir = Dir.mktmpdir("tina4_head_wire")
    FileUtils.mkdir_p(File.join(dir, "src", "routes"))
    File.write(File.join(dir, "src", "routes", "version.rb"), <<~RB)
      Tina4.get "/api/version" do |request, response|
        response.json({ version: "3.13.143", padding: "x" * 80 })
      end
    RB
    lib = File.expand_path("../lib", __dir__)
    exe = File.expand_path("../exe/tina4ruby", __dir__)
    port = free_port
    log = File.join(dir, "serve.log")
    env = ENV.to_h.reject { |k, _| k.start_with?("TINA4_") }.merge(
      "TINA4_NO_BROWSER" => "true", "TINA4_SECRET" => "head-wire-conformance-secret-0123456789abcdef",
      "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_TAKEOVER" => "true",
      "TINA4_DEFAULT_WEBSERVER" => "true", "TINA4_NO_AI_PORT" => "true"
    )
    pid = Process.spawn(env, RbConfig.ruby, "-I", lib, exe, "serve", "-p", port.to_s, "-h", "127.0.0.1",
                        "--no-browser", chdir: dir, out: log, err: log, pgroup: true, unsetenv_others: true)
    begin
      ready = false
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      until ready || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        begin
          count, = raw(port, "GET", "/api/version")
          ready = count == 1
        rescue StandardError
          ready = false # connection refused while the child is still coming up
        end
        raise "server exited during boot: #{File.read(log)}" unless ready || _alive?(pid)

        sleep 0.2 unless ready
      end
      raise "server never served /api/version: #{File.read(log)}" unless ready

      get_count, get_len, = raw(port, "GET", "/api/version")
      expect(get_count).to eq(1)
      expect(get_len).to be > 0

      head_count, head_len, head_body = raw(port, "HEAD", "/api/version")
      expect(head_count).to(eq(1), "HEAD emitted #{head_count} Content-Length headers (a strict proxy 502s a duplicate)")
      expect(head_len).to(eq(get_len), "HEAD Content-Length (#{head_len}) must equal the GET length (#{get_len}), not 0")
      expect(head_body).to eq(0)
    ensure
      begin
        Process.kill("TERM", -Process.getpgid(pid))
      rescue StandardError
        nil
      end
      begin
        Timeout.timeout(5) { Process.wait(pid) }
      rescue StandardError
        begin
          Process.kill("KILL", -Process.getpgid(pid))
        rescue StandardError
          nil
        end
      end
      FileUtils.remove_entry(dir)
    end
  end

  def _alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end

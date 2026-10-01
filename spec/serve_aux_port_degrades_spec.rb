# frozen_string_literal: true

# The auxiliary AI/test port (main port + 1000, debug-only) is a convenience,
# never load-bearing. A bind failure there must DEGRADE to no-aux-port and the
# MAIN server the operator asked for must still come up - it must never crash
# the whole boot.
#
# The old rescue in lib/tina4/webserver.rb caught only Errno::EADDRINUSE, so any
# OTHER bind failure on the aux port (a transient getaddrinfo /
# Socket::ResolutionError under process churn, EADDRNOTAVAIL, EACCES) propagated
# out of WebServer#start and killed the main server during boot.
#
# This drives a REAL non-EADDRINUSE failure without mocks: choose a main port in
# 64536..65535 so the aux port (main + 1000) lands above 65535, which makes
# TCPServer.new raise Socket::ResolutionError ("getaddrinfo: ... not known").
# A real child, a real socket, a real .env - debug ON and the aux port ENABLED
# (TINA4_NO_AI_PORT unset), so the aux bind is genuinely attempted and fails.
#
# Mutation check: revert the broadened rescue in webserver.rb (back to
# `rescue Errno::EADDRINUSE`) and this example goes red - the child dies on the
# unresolvable aux port and never serves /health.
require "spec_helper"
require_relative "support/shutdown_probe"
require "net/http"
require "socket"
require "rbconfig"

RSpec.describe "tina4ruby serve: auxiliary AI/test port bind degrades (never crashes main)" do
  # A free main port in [64536, 65535] so main + 1000 > 65535 (an invalid port
  # the OS resolver rejects). Fail loud if the whole window is occupied rather
  # than silently picking a port that would not exercise the aux failure.
  def free_high_port
    (65535).downto(64536) do |port|
      begin
        server = TCPServer.new("127.0.0.1", port)
        server.close
        return port
      rescue Errno::EADDRINUSE, Errno::EACCES
        next
      end
    end
    raise "no free port in 64536..65535 to exercise an out-of-range aux port"
  end

  it "serves /health on the main port when the aux-port bind raises a non-EADDRINUSE error" do
    exe = File.expand_path("../exe/tina4ruby", __dir__)
    lib = File.expand_path("../lib", __dir__)
    # debug ON (so the aux port is attempted) and TINA4_NO_AI_PORT deliberately
    # UNSET, unlike the sibling harness - the whole point is to let the aux bind
    # run and fail.
    env = ENV.to_h.reject { |k, _| k.start_with?("TINA4_") }.merge(
      "TINA4_DEBUG" => "true",
      "TINA4_NO_BROWSER" => "true",
      "TINA4_SECRET" => "cli-serve-aux-port-secret-0123456789abcdef",
      "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_TAKEOVER" => "true",
      "TINA4_DEFAULT_WEBSERVER" => "true",
      "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil
    )

    dir = Dir.mktmpdir("tina4_aux_port")
    FileUtils.mkdir_p(File.join(dir, "src", "routes"))
    File.write(File.join(dir, ".env"), "TINA4_DEBUG=true\n")
    port = free_high_port
    log = File.join(dir, "serve.log")
    pid = Process.spawn(env, RbConfig.ruby, "-I", lib, exe, "serve", "-p", port.to_s,
                        "-h", "127.0.0.1", "--no-browser", chdir: dir, out: log, err: log, pgroup: true)
    server = ShutdownProbe::Server.new(pid, port, dir, log)
    begin
      # The main server must come up despite the aux-port bind failing. If the
      # rescue is too narrow this raises BootError (the child died during boot).
      server.wait_until_serving!("/health", timeout: 30)
      status, body = server.get("/health")
      expect(status).to eq(200)
      expect(body.to_s).to include("tina4-ruby")

      # And it degraded LOUD, not silently: the aux bind failure is reported.
      expect(server.log).to match(/Test Port: SKIPPED/)
    ensure
      server.destroy!
    end
  end
end

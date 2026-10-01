# frozen_string_literal: true

# `tina4ruby serve` decides debug from the operator, never from a default
# (ADR-0079 s3). Debug decides whether /__dev is mounted, so each case boots the
# real CLI server in a child process on its own port and asks it for /__dev:
# 404 means debug is off.
#
#   - --production turns debug off (the explicit flag beats .env, ADR-0041); it
#     used to only choose Puma and leave TINA4_DEBUG=true from .env on.
#   - a missing .env no longer writes TINA4_DEBUG="true" (and an API key) as a
#     side effect of booting.
#
# Case names match the auth_token_contract.json "debug-is-explicit" invariant.
# No mocks: a real process, a real socket, real .env files.
require "spec_helper"
require_relative "support/shutdown_probe"
require "net/http"
require "socket"
require "rbconfig"
require "timeout"

RSpec.describe "tina4ruby serve debug is explicit (ADR-0079)" do
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def dev_status(env_file, *flags)
    exe = File.expand_path("../exe/tina4ruby", __dir__)
    lib = File.expand_path("../lib", __dir__)
    env = ENV.to_h.reject { |k, _| k.start_with?("TINA4_") }.merge(
      "TINA4_NO_BROWSER" => "true", "TINA4_SECRET" => "cli-serve-debug-secret-0123456789abcdef",
      "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_TAKEOVER" => "true", "TINA4_DEFAULT_WEBSERVER" => "true",
      # /__dev is gated by debug on the MAIN port; the auxiliary AI/test port
      # (port + 1000, debug-only) is not under test here. Binding it just doubles
      # this example's exposure to a transient getaddrinfo hiccup, so suppress it
      # exactly as the sibling harness (ShutdownProbe.base_env) already does. The
      # four debug assertions are unchanged - none of them touch the AI port.
      "TINA4_NO_AI_PORT" => "true"
    )
    # A boot can die before /health for a reason that has nothing to do with the
    # debug gate: on macOS getaddrinfo("127.0.0.1") transiently raises
    # Socket::ResolutionError under process churn (the very same host bound the
    # main port one line earlier), which kills the child on its auxiliary port.
    # That is an environment hiccup, not the behaviour under test, so a boot that
    # dies before serving /health is retried on a FRESH port and temp project.
    # The debug assertion itself is never retried - poll_status runs only once
    # the child is serving, and its result is returned as-is. A server that
    # genuinely never boots still raises after the attempts are spent.
    boot_attempts = 3
    boot_attempts.times do |attempt|
      dir = Dir.mktmpdir("tina4_serve")
      FileUtils.mkdir_p(File.join(dir, "src", "routes"))
      File.write(File.join(dir, ".env"), env_file) if env_file
      port = free_port
      log = File.join(dir, "serve.log")
      pid = Process.spawn(env, RbConfig.ruby, "-I", lib, exe, "serve", "-p", port.to_s, "-h", "127.0.0.1",
                          "--no-browser", *flags, chdir: dir, out: log, err: log, pgroup: true)
      # /health is mounted regardless of debug, so a 200 there proves the child
      # is serving. /__dev is NOT a late-mounted route: it is a per-request
      # dispatch stage gated on ENV["TINA4_DEBUG"] (dispatch_pipeline.rb
      # dev_routes -> DevAdmin.handle_request / DevAdmin.enabled?), and the env
      # is loaded in initialize! BEFORE the socket ever accepts. So a dispatching
      # server answers /__dev correctly on the first successful connection -
      # non-404 when debug is on, 404 when it is off - and socket-up already
      # implies /__dev is live (debug on). #84's single probe could still be
      # fooled by a transient CONNECTION failure under load (not a mount race).
      # poll_status waits for /health (child up) then asks /__dev, retrying only
      # transient connection failures within the SAME generous deadline as the
      # /health wait (so CI starvation cannot expire it): it returns the first
      # non-404 the instant it appears (debug on) and a settled 404 after a short
      # stable window (debug off). Neither assertion is weakened.
      server = ShutdownProbe::Server.new(pid, port, dir, log)
      begin
        server.wait_until_serving!("/health", timeout: 30)
        status = server.poll_status("/__dev")
        # Capture a full diagnostic BEFORE destroy! removes the temp project, so
        # an unexpected result (the historical flake) fails with the child's own
        # boot log instead of a bare status code. The banner records Debug ON/OFF,
        # which decides env-not-applied vs a dispatch bug at a glance.
        @last_diag = {
          status: status, port: port,
          health: server.get("/health"),
          reprobe: Array.new(4) { server.get("/__dev")&.first },
          log: server.log
        }
        raise "serve never answered /__dev: #{server.log}" if status.nil?

        return status
      rescue ShutdownProbe::BootError
        raise if attempt == boot_attempts - 1

        # A transient getaddrinfo failure arrives in a short burst, so back off
        # before the next spawn to let the resolver recover rather than retrying
        # straight back into the same bad window.
        sleep(0.5 * (attempt + 1))
      ensure
        server.destroy!
      end
    end
  end

  # On an unexpected result, surface the child's own boot log (the banner records
  # Debug ON/OFF) so a CI failure localizes env-not-applied vs a dispatch bug.
  def diag
    "\n--- child diagnostic ---\n#{@last_diag.inspect}\n--- child serve.log ---\n#{@last_diag && @last_diag[:log]}"
  end

  it "serve honours debug false from env file" do
    expect(dev_status("TINA4_DEBUG=false\n")).to(eq(404), diag)
  end

  it "serve honours debug true from env file" do
    # Control: proves the /__dev probe can tell debug-on from debug-off.
    expect(dev_status("TINA4_DEBUG=true\n")).not_to(eq(404), diag)
  end

  it "production flag turns debug off" do
    expect(dev_status("TINA4_DEBUG=true\n", "--production")).to(eq(404), diag)
  end

  it "a missing env file does not enable debug" do
    expect(dev_status(nil)).to(eq(404), diag)
  end
end

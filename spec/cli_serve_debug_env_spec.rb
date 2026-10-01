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
    boot_attempts = 5
    boot_attempts.times do |attempt|
      dir = Dir.mktmpdir("tina4_serve")
      FileUtils.mkdir_p(File.join(dir, "src", "routes"))
      File.write(File.join(dir, ".env"), env_file) if env_file
      port = free_port
      log = File.join(dir, "serve.log")
      # unsetenv_others: true is THE fix for the recurring flake. Without it,
      # Process.spawn MERGES `env` onto the PARENT process environment, and the
      # `reject { TINA4_* }` above only OMITS those keys from the hash - omission
      # means INHERIT, not delete. So the child inherited the rspec parent's
      # TINA4_ vars: spec_helper pins TINA4_LOG_LEVEL=NONE, and whenever a prior
      # example (RSpec random order) left TINA4_DEBUG=false in the parent, the
      # debug-ON child inherited TINA4_DEBUG=false. The temp .env's
      # TINA4_DEBUG=true then could NOT win because env load is first-wins
      # (ENV[k] ||= v). The child booted Debug OFF, so /__dev answered a settled
      # 404 - the exact failure, confirmed by the child banner in a CI failure:
      # "Debug: OFF (Log level: NONE)" - neither value this spec passes.
      # unsetenv_others gives the child EXACTLY this hash (the real non-TINA4
      # environment it needs, plus the six intended TINA4_ keys) and nothing
      # inherited, so TINA4_DEBUG is genuinely unset and the .env value applies.
      pid = Process.spawn(env, RbConfig.ruby, "-I", lib, exe, "serve", "-p", port.to_s, "-h", "127.0.0.1",
                          "--no-browser", *flags, chdir: dir, out: log, err: log, pgroup: true,
                          unsetenv_others: true)
      # ROOT CAUSE of the recurring flake (confirmed from a CI failure's child
      # serve.log): NOT a /__dev readiness race. /__dev is gated on
      # ENV["TINA4_DEBUG"], loaded before the socket accepts, so a dispatching
      # server answers /__dev correctly at once. The flake was a PORT-IDENTITY
      # bug: free_port hands out an ephemeral port, and under load a DIFFERENT,
      # debug-off server held it by the time our debug-on child tried to bind.
      # The child could not own the port (logged "is in use and takeover is
      # disabled"), yet wait_until_serving! accepted /health=200 from that
      # foreign server and the /__dev probe then hit the wrong, debug-off server
      # and saw a settled 404. The failing child's own banner proved it:
      # "Debug: OFF (Log level: NONE)" - not the config THIS spec passes.
      #
      # Fix: require the child's OWN "Server: http://...:<thisport>" banner (it
      # prints only after the child actually bound THIS port) before trusting a
      # /health 200, and check child-exit first. A contended port therefore
      # fails the boot and retries on a FRESH port instead of silently probing a
      # foreign server. Then poll /__dev: debug-on returns non-404 at once,
      # debug-off a settled 404 - neither assertion weakened.
      own_server = %r{Server:\s+http://[^\s]*:#{port}\b}
      server = ShutdownProbe::Server.new(pid, port, dir, log)
      begin
        server.wait_until_serving!("/health", timeout: 30, require_log: own_server)
        status = server.poll_status("/__dev")
        # Capture a full diagnostic BEFORE destroy! removes the temp project, so
        # an unexpected result (the historical flake) fails with the child's own
        # boot log instead of a bare status code. The banner records Debug ON/OFF,
        # which decides env-not-applied vs a dispatch bug at a glance.
        @last_diag = {
          status: status, port: port, attempt: attempt,
          child_alive: !server.exited?,
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

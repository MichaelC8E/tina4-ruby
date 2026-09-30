# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# EFFICIENCY (Carbonah E004): the NATS backplane keeps one background thread per
# subscription. That thread has no work — the NATS client dispatches messages on
# its own reader thread — so it only has to stay alive until unsubscribe or close
# kills it. It used to `loop { sleep 0.01 }`, waking a hundred times a second to
# re-check a flag; now it blocks on an empty queue and waits at zero CPU.
#
# This spec is the safety net for that change: it proves the keeper thread still
# lives across a real publish/subscribe round-trip and still dies on teardown, so
# the busy-poll could be removed without touching the backplane's behaviour.
#
# REAL ENGINE, NO DOUBLE: a real Tina4::NATSBackplane over a real NATS server
# (TINA4_TEST_NATS_URL). No stub, no fake client.

require_relative "spec_helper"

RSpec.describe "WebSocket NATS backplane keeper thread (real NATS)" do
  nats_url = ENV["TINA4_TEST_NATS_URL"].to_s

  before do
    skip "[needs:nats] TINA4_TEST_NATS_URL not set: no reachable NATS server" if nats_url.empty?
    begin
      require "nats/client"
    rescue LoadError
      skip "[needs:nats] nats-pure gem not in the bundle (group :nats)"
    end
  end

  let(:channel) { "tina4-nats-keeper-#{Process.pid}-#{rand(100_000)}" }

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
  end

  it "delivers a published message to a subscriber (round-trip)" do
    backplane = Tina4::NATSBackplane.new(url: nats_url)
    received = Queue.new
    begin
      backplane.subscribe(channel) { |message| received << message }
      wait_until { backplane.instance_variable_get(:@threads).key?(channel) }
      backplane.publish(channel, "hello-nats")
      wait_until { !received.empty? }

      expect(received.empty?).to be(false)
      expect(received.pop).to eq("hello-nats")
    ensure
      backplane.close
    end
  end

  it "keeps the keeper thread alive and idle (not a busy-spin) after subscribe" do
    backplane = Tina4::NATSBackplane.new(url: nats_url)
    begin
      backplane.subscribe(channel) { |_m| }
      wait_until { backplane.instance_variable_get(:@threads).key?(channel) }
      keeper = backplane.instance_variable_get(:@threads)[channel]

      expect(keeper).to be_a(Thread)
      expect(keeper.alive?).to be(true)
      # A thread blocked on an empty queue reports "sleep" and stays that way; it
      # never returns to "run" on its own, because nothing wakes it.
      sleep 0.1
      expect(keeper.status).to eq("sleep")
    ensure
      backplane.close
    end
  end

  it "tears the keeper thread down on unsubscribe" do
    backplane = Tina4::NATSBackplane.new(url: nats_url)
    begin
      backplane.subscribe(channel) { |_m| }
      wait_until { backplane.instance_variable_get(:@threads).key?(channel) }
      keeper = backplane.instance_variable_get(:@threads)[channel]

      backplane.unsubscribe(channel)
      wait_until { !keeper.alive? }

      expect(keeper.alive?).to be(false)
      expect(backplane.instance_variable_get(:@threads).key?(channel)).to be(false)
    ensure
      backplane.close
    end
  end

  it "tears the keeper thread down on close" do
    backplane = Tina4::NATSBackplane.new(url: nats_url)
    backplane.subscribe(channel) { |_m| }
    wait_until { backplane.instance_variable_get(:@threads).key?(channel) }
    keeper = backplane.instance_variable_get(:@threads)[channel]

    backplane.close
    wait_until { !keeper.alive? }

    expect(keeper.alive?).to be(false)
  end
end

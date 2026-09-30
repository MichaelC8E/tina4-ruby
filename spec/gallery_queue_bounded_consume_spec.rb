# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# EFFICIENCY (Carbonah E003): the gallery queue "consume next" / "fail next"
# endpoints read exactly ONE message - the highest-priority pending one whose
# delay has passed. The SELECT they share (GALLERY_QUEUE_NEXT_PENDING_SQL) must
# carry LIMIT 1, so the database returns one row instead of sorting and handing
# back every pending row for Ruby to throw away.
#
# REAL ENGINE, NO DOUBLE: a real Tina4::Database over a real SQLite file runs
# the real query string the routes issue. The constant is loaded straight from
# the gallery route file, so the test tracks the route, not a copy of it.

require_relative "spec_helper"

RSpec.describe "Gallery queue bounded consume query (real SQLite)" do
  # Load the gallery route file for its constants only. The route DSL calls
  # (Tina4::Router.post ...) register handlers; loading them has no side effect
  # on this database test, which drives its own Tina4::Database directly.
  before(:all) do
    route_file = File.expand_path(
      "../lib/tina4/gallery/queue/src/routes/api/gallery_queue.rb", __dir__
    )
    load route_file unless defined?(GALLERY_QUEUE_NEXT_PENDING_SQL)
  end

  let(:database) do
    directory = SpecTmpdir.create
    db = Tina4::Database.new("sqlite://#{File.join(directory, 'queue.db')}")
    db.execute(<<~SQL)
      CREATE TABLE tina4_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        topic TEXT NOT NULL,
        data TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        priority INTEGER NOT NULL DEFAULT 0,
        available_at TEXT NOT NULL
      )
    SQL
    db
  end

  let(:now) { "2026-09-30T00:00:00Z" }

  def enqueue(data:, priority:, status: "pending", available_at: "2026-01-01T00:00:00Z")
    database.execute(
      "INSERT INTO tina4_queue (topic, data, status, priority, available_at) VALUES (?, ?, ?, ?, ?)",
      ["gallery-tasks", data, status, priority, available_at]
    )
  end

  it "returns exactly one row even when many messages are pending" do
    enqueue(data: "low", priority: 1)
    enqueue(data: "high", priority: 9)
    enqueue(data: "mid", priority: 5)

    rows = database.fetch(GALLERY_QUEUE_NEXT_PENDING_SQL, ["gallery-tasks", now])

    # The gate: without LIMIT 1 the driver returns all three pending rows here.
    expect(rows.length).to eq(1)
  end

  it "returns the highest-priority pending message" do
    enqueue(data: "low", priority: 1)
    enqueue(data: "high", priority: 9)
    enqueue(data: "mid", priority: 5)

    row = database.fetch_one(GALLERY_QUEUE_NEXT_PENDING_SQL, ["gallery-tasks", now])

    expect(row[:data]).to eq("high")
  end

  it "skips messages whose available_at is still in the future" do
    enqueue(data: "later", priority: 9, available_at: "2099-01-01T00:00:00Z")
    enqueue(data: "ready", priority: 2, available_at: "2026-01-01T00:00:00Z")

    row = database.fetch_one(GALLERY_QUEUE_NEXT_PENDING_SQL, ["gallery-tasks", now])

    expect(row[:data]).to eq("ready")
  end

  it "returns nothing when no message is pending" do
    enqueue(data: "done", priority: 5, status: "completed")

    row = database.fetch_one(GALLERY_QUEUE_NEXT_PENDING_SQL, ["gallery-tasks", now])

    expect(row).to be_nil
  end
end

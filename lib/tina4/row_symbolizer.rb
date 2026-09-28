# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

module Tina4
  # Shared row/key symbolisation for the two SQLite classes.
  #
  # `symbolize_rows`/`symbolize_keys` used to be byte-identical copy-paste in
  # Tina4::Drivers::SqliteDriver and Tina4::Adapters::Sqlite3Adapter (the
  # adapter's own comment pointed at the driver's copy). This module is the
  # single home for the logic; both classes `include` it as private instance
  # methods, so both share ONE implementation and can never drift again.
  #
  # The mapping is computed ONCE per query rather than per cell: the per-row
  # form ran `k.to_s.to_sym` and an `is_a?` guard PER CELL, so a 5,000-row x
  # 6-column fetch did 30,000 conversions for 6 distinct keys and made Tina4 the
  # slowest of the four frameworks at bulk reads (Select ALL 5,000 rows:
  # 10.16ms vs raw sqlite3 2.56ms). Hoisting the mapping out of the loop roughly
  # halves the hydration cost with byte-identical output.
  #
  # The is_a?(String|Symbol) guard is preserved: older sqlite3 gems put
  # positional Integer keys in the hash alongside the string names, and those
  # must still be dropped.
  module RowSymbolizer
    private

    # Symbolize a whole result set's keys, computing the mapping once per query.
    def symbolize_rows(rows)
      return rows if rows.empty?

      str_keys = rows.first.keys.select { |k| k.is_a?(String) || k.is_a?(Symbol) }
      sym_keys = str_keys.map(&:to_sym)
      count = str_keys.length
      rows.map do |row|
        out = {}
        i = 0
        while i < count
          out[sym_keys[i]] = row[str_keys[i]]
          i += 1
        end
        out
      end
    end

    # Single-hash convenience; delegates to the batch path so there is one
    # implementation of the mapping rule.
    def symbolize_keys(hash)
      symbolize_rows([hash]).first
    end
  end
end

# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

module Tina4
  module QueueBackends
    # The at-least-once fail policy (ADR-0022) shared by the broker backends
    # whose protocol carries no delivery counter (kafka, rabbitmq). A Kafka
    # record and an AMQP body are both immutable, so recording a failed attempt
    # means RE-PUBLISHING a body that carries the incremented count rather than
    # mutating the message in place.
    #
    # Increment attempts, record the error, dead-letter at the retry limit else
    # re-enqueue, then ack LAST -- so a crash between the re-publish and the ack
    # redelivers the job rather than losing it, which is the contract.
    #
    # The host backend must define +enqueue+, +dead_letter+, +complete+ (its
    # terminal ack) and an +@max_retries+.
    module RepublishRetryPolicy
      def fail(job, error = "")
        job.attempts += 1
        job.error = error
        if job.attempts >= @max_retries
          dead_letter(job)
        else
          enqueue(job)
        end
        complete(job)
      end
    end
  end
end

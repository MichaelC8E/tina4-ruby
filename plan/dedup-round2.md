# Task: Reduce cross-file duplication in tina4-ruby (round 2)

Outcome: fewer cross-file duplicate blocks in `lib/tina4`, genuine dedup only,
one PR to `v3`, no behaviour change, real-engine specs green, carbonah unchanged.

Baseline (tina4 metrics --path lib/tina4): 23 duplicate blocks / 224 duplicate lines.
Cross-file blocks: 6, across 3 clusters.

## Scope
- [x] Cluster 1 GENUINE: redis_handler.rb + valkey_handler.rb -> shared RESP session mixin
- [x] Cluster 2 GENUINE: kafka + rabbitmq Job rehydration -> Tina4::Job.from_payload
- [x] Cluster 3 GENUINE: kafka + rabbitmq fail() -> shared retry-policy mixin
- [x] Cluster 4 GENUINE: crud.rb `h` + error_overlay.rb `esc` -> reuse Frond.escape_html
- [x] Look-alikes LEFT with reasons (kafka/rabbitmq deliberately diverge elsewhere; html_element uses &#x27;)

## Parity
Ruby-internal refactor only (no shared contract/response-shape change) -> no cross-framework port needed.
Job.from_payload mirrors the same rehydration Python/PHP/Node do inline; note only.

## Tests (real, no mocks, on the lab: redis 6379, valkey 6380, kafka 9092, rabbitmq 5672)
- [x] baseline target specs green BEFORE change
- [x] session_handlers_spec, valkey_handler_spec, session_zero_dependency_fallback_spec green after
- [x] queue_backends_spec, kafka_integration_spec, queue_failure_lifecycle_spec green after
- [x] crud_spec, error_overlay_spec green after
- [x] mutation-prove each extracted helper gates (break -> red -> restore)
- [x] full suite green at HEAD on lab (0 failed, 0 skipped modulo irreducible)

## Bugs
- (none expected; log here if found)

## Commits
- (hash description)

## Commits
- (pending) refactor(dedup): remove all 6 cross-file duplicate blocks in lib/tina4

## Result
- Duplicate blocks 23 -> 17; duplicate lines 224 -> 174; CROSS-FILE blocks 6 -> 0.
- maintainability 29.8 -> 30.3; carbonah 17 warnings/0 errors, IDENTICAL before/after.
- Full suite on lab: 6642 examples, 0 failures (104 pending = unrelated firebird/postgis/graph service gaps).
- Mutation-proved all 4 extractions gate (red on break, restored green).

## Status: Complete

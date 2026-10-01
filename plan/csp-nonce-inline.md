# Task: CSP nonce for framework inline content (fix unstyled fresh-init render) — Ruby mirror

Outcome: fresh `tina4 init ruby` renders STYLED under the strict default CSP. Keep
`default-src 'self'`; make the framework's own inline `<style>`/`<script>` CSP-clean via a
per-response nonce, and de-inline every `style="..."`/`on*=` the framework emits. No
'unsafe-inline'. Mirrors tina4-python #190 / ADR-0088.

## Scope
- [x] Read Python reference (#190) + ADR-0088
- [x] Per-response nonce module (`lib/tina4/csp.rb`): thread-local + generate + Frond global `csp_nonce`
- [x] `response.csp_nonce` attribute (Response#initialize reads current nonce)
- [x] Wire nonce per request in `rack_app.rb#call` (set/clear in begin/ensure, mirror request_id)
- [x] Frond global `csp_nonce()` registered in `register_builtin_globals` (+ Template.render_error context)
- [x] CSP header: inject `'nonce-X'` into style-src AND script-src (default + user TINA4_CSP) in SecurityHeadersMiddleware.canonical_headers
- [x] Update TINA4_CSP one-time warning text (inline now works via nonce)
- [x] Nonce every framework inline `<style>`/`<script>`: welcome page, swagger, error_overlay, error twigs, crud, gallery, template fallback
- [x] De-inline every framework `style="..."` into classes + `onclick=` → addEventListener
- [x] Scaffold auth forms (login/register) + gallery routes de-inlined + nonce'd
- [x] Document csp_nonce() for app developers (CLAUDE.md)
- [x] crud.rb FULLY de-inlined (resolves Python's row-level onclick follow-up for Ruby):
      every onclick/onsubmit → data-* + delegated addEventListener; `<style>`/`<script>` nonce'd;
      covered by spec/crud_csp_onclick_spec.rb
- [x] graphql GraphiQL playground: inline <script> nonce'd + style= de-inlined (unpkg CDN still needs TINA4_CSP, like swagger)

## Parity
| Feature | Python | PHP | Ruby | Node |
|---------|--------|-----|------|------|
| csp-nonce | ✅ (#190) | ❌ (mirror) | ✅ BUILD | ❌ (mirror) |

## Tests (real, no mocks, positive + negative)
- [x] CSP header on `/` carries 'nonce-' in style-src AND script-src (real boot)
- [x] welcome page inline <style>/<script> carry that exact nonce
- [x] no style= / onclick= emitted by framework welcome page, error page, /__dev
- [x] negative: two requests get DIFFERENT nonces (per-response)
- [x] spec/csp_nonce_inline_spec.rb green (welcome / 404 / __dev, header+body agree, nonce differs)
- [x] spec/crud_csp_onclick_spec.rb green (crud emits zero inline on*=)
- [x] existing CSP/header contracts updated to assert nonce STRUCTURE (never byte-equal)

## Bugs
- [x] fresh-init `/` welcome page rendered unstyled under default CSP — fixed via per-response nonce

## Commits
- (on branch fix/csp-nonce-inline — see PR)

## Status: Complete (Ruby mirror). Deterministic single-response verify + rspec + metrics gate green on macOS, Ruby 4.0.7, UTF-8 locale.

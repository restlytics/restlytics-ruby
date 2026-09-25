# restlytics — Rails SDK

Zero-config performance + error tracing for Rails, shipped to [restlytics](https://restlytics.com) in OTLP/JSON.

- **5-minute install** — a Railtie auto-wires the Rack middleware and the DB subscriber, no code changes.
- **Pure Ruby stdlib core** — no gems required. Just `json` + `zlib` + `net/http` (all bundled with Ruby). `rails`/`activesupport` are integration-time, not runtime, dependencies.
- **Zero added latency** — spans are flushed *after* the HTTP response is sent (Rack body `#close`), fire-and-forget on a background thread with a hard ~2s timeout.
- **Safe by default** — head-based sampling, SQL normalized to literal-free templates, bindings counted (never sent), query strings scrubbed, no request/response bodies.

> **This is the canonical, open-source repository for the restlytics Rails SDK** — published to RubyGems as the `restlytics` gem. Open issues and pull requests here. It conforms to the cross-language restlytics wire contract, so the ingestion service accepts it identically to every other restlytics SDK.

---

## Install

> [!IMPORTANT]
> **Not yet published to RubyGems.** `restlytics` returns 404 today — publication is tracked in
> [restlytics/app#232](https://github.com/restlytics/app/issues/232). Until it lands, install
> directly from this repository:
>
> ```ruby
> gem "restlytics", git: "https://github.com/restlytics/restlytics-ruby", tag: "v0.1.5"
> ```

Add to your `Gemfile`:

```ruby
gem "restlytics"
```

Then `bundle install`. The Railtie auto-discovers and wires everything up. Add your keys to the environment (or an initializer — see below):

```dotenv
RESTLYTICS_KEY=your-project-ingest-key
RESTLYTICS_INGEST_URL=https://ingest.restlytics.com
RESTLYTICS_ENV=production
```

Until `RESTLYTICS_KEY` is set the SDK stays completely inert (no spans built, no requests made), so it's safe to deploy before you've provisioned a key.

### Optional initializer

Create `config/initializers/restlytics.rb` to override defaults in code (env vars still win for anything you don't set here):

```ruby
Restlytics.configure do |c|
  c.key          = ENV["RESTLYTICS_KEY"]
  c.ingest_url   = ENV.fetch("RESTLYTICS_INGEST_URL", "https://ingest.restlytics.com")
  c.service_name = "my-rails-app"
  c.env          = Rails.env
  c.sample_rate  = 1.0          # head-based, 0.0–1.0
  c.capture_sql  = false        # send raw SQL text (capped 2048) — off by default
  c.logger       = Rails.logger # optional: where the `log` transport / errors go

  # Per-instrument toggles
  c.instrument_db    = true
  c.instrument_http  = true     # Net::HTTP CLIENT spans + W3C traceparent injection
  c.instrument_cache = true

  # Paths skipped entirely (exact match or trailing `*`)
  c.ignore_paths = %w[/up /health /assets/* /cable]
end
```

The initializer runs before the Railtie builds the tracer, so your overrides are picked up.

### `.env` reference

| Variable | Default | Purpose |
| --- | --- | --- |
| `RESTLYTICS_KEY` | `""` | Project ingest key (sent as `X-Restlytics-Key`). Empty = disabled. |
| `RESTLYTICS_INGEST_URL` | `https://ingest.restlytics.com` | Ingest base URL; SDK POSTs to `{url}/v1/traces`. |
| `RESTLYTICS_ENV` | `RAILS_ENV` | `deployment.environment` resource attribute. |
| `RESTLYTICS_SERVICE_NAME` | `rails` | `service.name` resource attribute. |
| `RESTLYTICS_SAMPLE_RATE` | `1.0` | Head-based trace sampling, `0.0`–`1.0`. |
| `RESTLYTICS_TRANSPORT` | `http` | `http` (prod), `log` (dev), `null` (off/tests). |
| `RESTLYTICS_TIMEOUT_MS` | `2000` | Hard cap on the send (Net::HTTP open/read timeout). |
| `RESTLYTICS_CAPTURE_SQL` | `false` | Send raw SQL text (capped 2048). Off = template only. |
| `RESTLYTICS_INSTRUMENT_DB` / `_HTTP` / `_CACHE` | `true` | Per-instrument toggles. |
| `RESTLYTICS_MAX_SPANS` | `2000` | Per-request span buffer cap. |

---

## How it works

1. **Root request span** — a Rack middleware opens a `SERVER` span at the start of the request and finalizes it when the response **body is closed** (after it's flushed to the client). So closing the span, computing self-time, gzipping, and the POST all happen off the request's critical path (the POST itself runs on a background thread).
2. **DB spans** — `ActiveSupport::Notifications.subscribe("sql.active_record")` turns each query into a `CLIENT` span. `SCHEMA` and `CACHE` events are skipped. The statement is normalized to a literal-free template (`SELECT * FROM users WHERE id = ?`) used both as the N+1 grouping key and to keep PII off the wire. We record the binding **count** (from the payload `binds`), never values.
3. **Outbound HTTP spans** — optional, best-effort `Net::HTTP#request` patch captures method, host, redacted `url.full`, status, and timing for each call.
4. **Self-time** — child spans are interval-unioned per category (db / http / cache) so overlapping work isn't double-counted; `app` self-time is the root's exclusive time. Emitted as `restlytics.self_ns.*` on the root span.
5. **Errors** — 5xx responses set the span status to `ERROR (2)`.

Timing uses the monotonic clock (`Process.clock_gettime(:MONOTONIC)`) for durations, anchored to one wall-clock reading for absolute epoch-nanosecond timestamps — durations stay correct across NTP adjustments.

### Route templates

`http.route` is always the **template** (`/users/{id}`), never the raw URL, so high-cardinality ids don't explode the grouping. It comes from Rails' matched route (`ActionDispatch::Request#route_uri_pattern`), with `:id` rewritten to `{id}` and the trailing `(.:format)` stripped.

### Concurrency

One `Tracer` instance is shared by the process; **all per-request state lives in a fiber/thread-local**, so concurrent requests under Puma never share spans. State is reset at the end of each request.

---

## Trust & redaction

restlytics is built to be safe to run in production against real traffic:

- **Fire-and-forget, never fatal.** Every transport/instrument path is wrapped; telemetry can never raise into — or slow — your app. One worker drains a fixed 64-batch queue with a hard timeout; saturation drops the new batch and delivery is never retried.
- **No binding values.** SQL is normalized to a template; only a binding *count* is sent.
- **No raw SQL** unless you explicitly set `RESTLYTICS_CAPTURE_SQL=true` (then capped at 2048 chars).
- **Scrubbed URLs.** Every `url.full` query value is redacted and credentials/fragments are removed. `http.route` is always the template.
- **No content-bearing fields.** Request/response bodies and headers plus exception content are never exported.
- **Sampling.** Lower `RESTLYTICS_SAMPLE_RATE` to capture a fraction of traffic.

Payload-free delivery counters and bounded shutdown are available on the
process-wide SDK handle:

```ruby
health = Restlytics.diagnostics
Rails.logger.info("restlytics drops=#{health[:dropped_batches]}") if health
Restlytics.shutdown(timeout_ms: 2000)
```

---

## Local development

Set `RESTLYTICS_TRANSPORT=log` to dump the OTLP payload to your logger instead of the network, or `RESTLYTICS_TRANSPORT=null` to disable delivery while keeping instrumentation (useful in tests).

## Tests

The shipped unit tests run on the stdlib `minitest` (no extra gems):

```bash
ruby -Ilib -Itest test/test_sql.rb
ruby -Ilib -Itest test/test_intervals.rb
```

## Cross-language conformance

CI pins [`restlytics/sdk-conformance@v1.1.0`](https://github.com/restlytics/sdk-conformance)
and compares the vendored fixture before testing. The suite proves exact semantic OTLP output,
W3C propagation, root sampling, source redaction, and error-status behavior shared by all seven SDKs.
This is the wire-level gate; real Rails/ActiveRecord application validation is tracked separately.

## License

MIT © restlytics. See [LICENSE](LICENSE).

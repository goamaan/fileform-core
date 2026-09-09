# Bounded direct HTTP transport

`DirectHTTPClient` is the shared transport layer for explicit source requests.
Calling `inspect` or `download` performs network access. Constructing the client
or policy does not. It is not yet the complete acquisition planner, downloader
pack adapter, command-line workflow or native link editor.

```swift
let client = DirectHTTPClient()
let policy = try HTTPAcquisitionPolicy(maximumBytes: 50 * 1024 * 1024)
let metadata = try await client.inspect(sourceURL, policy: policy)
let downloaded = try await client.download(sourceURL, policy: policy)
defer { downloaded.discard() }
// Inspect downloaded.url with the relevant content backend before publishing.
```

## Contract

- HTTPS by default. HTTP requires explicit policy opt-in; HTTPS redirects never
  downgrade to HTTP, even with that opt-in. Initial URLs and every redirect
  require an allowed HTTP(S) host without embedded username/password. Callers can
  provide an exact host allowlist. Redirect count and total transfer time are
  bounded. This local client is not a hosted proxy or DNS/SSRF boundary.
- Metadata inspection uses HEAD, retaining HEAD through redirects. Metadata is
  advisory: a later download is a new request, not an immutable remote snapshot.
  The acquisition planner still needs entity/variant binding and change review.
- An ephemeral URLSession has no cookie storage, credential storage or response
  cache. It requests direct connections, no content encoding, and no cookies.
  Authentication challenges other than ordinary server trust are cancelled.
  TLS uses the platform's default certificate validation.
- Only complete HTTP 200 responses are accepted. Known oversized lengths are
  rejected before the body is accepted. Every delivered body chunk is checked
  **before writing** against the byte ceiling, including unknown-length bodies.
  The ceiling bounds retained payload, not packets already buffered by the OS.
  Nonidentity content encoding, empty downloads, truncated declared bodies,
  authentication failures and failed requests never return a successful lease.
- Each GET owns a private 0700 staging directory and 0600 payload file. Success
  returns a lease with actual byte count, SHA-256 and response metadata. Explicit
  `discard()` or lease deinitialization removes only that owned directory.
  Failure/cancellation removes staging after transport completion. No user output
  path is overwritten or published by this layer.
- Standard Swift Task cancellation also handles cancellation before startup and
  cancellation during receiving. Progress reports actual retained bytes and an
  optional declared total on the transport callback queue.

The raw payload is **not verified media**. MIME type and remote metadata cannot
prove file contents. Callers must preserve the lease while reading, inspect and
verify content, apply the declared transformation if required, and publish through
the ordinary file transaction boundary. Avoid storing full source query strings
or metadata in diagnostics; URLs can contain user-supplied access tokens.

## Verification

`DirectHTTPClientTests` starts owned loopback HTTP servers. HTTP is explicitly
allowed only by those test policies. Six tests cover URL/credential/host policy,
HEAD metadata, redirected byte identity and SHA-256, cookie rejection across a
redirect, known and unknown oversized bodies, loops and disallowed redirect hosts,
authentication, content encoding, truncation, resource timeout and cancellation
before/during receiving. Every failure checks that staging is empty. A full local
run with MediaPack enabled passed 95 tests on September 9, 2026.

The downloader spike separately demonstrated that yt-dlp's maximum-file-size flag
can succeed with an oversized unknown-length response. These transport tests
exercise an independent streaming ceiling instead of trusting that flag.

Foundation behavior is implemented through Apple's
[URLSessionDataDelegate](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate)
and task redirect/authentication callbacks. No certificate-validation override or
browser credential import is present.

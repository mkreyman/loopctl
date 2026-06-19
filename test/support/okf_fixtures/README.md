# OKF sample bundles (vendored fixtures)

These three bundles are vendored verbatim (markdown files only) from Google
Cloud's `knowledge-catalog` repository for use as round-trip / conformance test
fixtures for loopctl's OKF (Open Knowledge Format) exporter and importer.

- Source: https://github.com/GoogleCloudPlatform/knowledge-catalog (`okf/bundles/`)
- License: Apache License 2.0 (see the upstream repository's `LICENSE`)
- Retrieved: 2026-06-18, branch `main`
- Spec: OKF v0.1 — https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf

Bundles:
- `crypto_bitcoin/` — BigQuery Bitcoin public dataset (8 docs)
- `ga4/` — Google Analytics 4 obfuscated sample ecommerce (17 docs)
- `stackoverflow/` — Stack Overflow public dataset (53 docs)

Only `.md` files were vendored; non-OKF assets (e.g. `viz.html`) were dropped.
Do not edit these files — they are an external conformance reference. They are
test-only and are not shipped in the loopctl release.

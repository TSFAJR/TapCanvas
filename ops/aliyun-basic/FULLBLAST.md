# FullBlast personal deployment

Models: qwen3.7-plus for chat/vision/tools (thinking disabled); wan2.7-image for one 1024×1024 image; wan3.0-video for text or one reference image, 720P, default five seconds. No automatic model fallback. Image editing, embeddings, voice, workflow rendering and media composition are not enabled. Catalog options intentionally expose only the configured subset.

Secrets live in `/etc/tap-canvas/runtime.env`. Set `FULLBLAST_API_KEY`, `TAPCANVAS_BASIC_NO_MODELS=0`, `TAPCANVAS_GENERATION_ENABLED=1`, `UPSTREAM_CATALOG_SYNC_ENABLED=false`, `AGENTS_MODEL=qwen3.7-plus`, `AGENTS_CAPABILITY_ANALYSIS_MODEL=qwen3.7-plus`, `AGENTS_GOVERNANCE_MODEL_KEY=qwen3.7-plus`, `IMAGE_UNDERSTANDING_MODEL_KEY=qwen3.7-plus`, `AGENTS_REASONING_EFFORT=off`, `DSH_CONTEXT_WINDOW=200000`, and `LOCAL_ASSET_PUBLIC_BASE_URL=http://47.112.1.188/assets/local`. Keep the existing internal gateway token. Channel credentials are also stored by New API in its private database and protected backups.

Back up before changes. Deploy digest-pinned images with `deploy.sh`, then run `python3 ops/aliyun-basic/configure-fullblast.py` from the deployed checkout. The script uses the loopback admin API, configures only the three named FullBlast channels, and submits no tests. It can be rerun after a credential rotation. Seed provider synchronization remains disabled; do not run gateway-wide automatic channel tests.

The `fullblast` Compose profile contains only the image worker and in-process finalizer. Common operational scripts select it from `TAPCANVAS_GENERATION_ENABLED`. Each worker has 512 MiB and concurrency one. All writers share `/data/tap-canvas/public-assets`; backups stop workers as well as API before copying assets. Remote-builder/workflow-runtime/media-worker remain off.

Pricing snapshot: 2026-09-22, https://www.fullblast.cn/api/pricing . Chat input/output CNY 1.32/5.28 per million tokens up to 256K input (the configured assistant context is 200K). Longer direct API calls fall outside this price quotation. Image CNY 0.11 each; video 720P CNY 0.396/second. Internal credits are accounting, not a supplier spending cap. Supplier invoices remain authoritative.

Acceptance budget is CNY 5 total: one short assistant tool conversation, one image, one two-second 720P video using that image. Record task IDs before polling; never resubmit an ambiguous request. Refresh the canvas and confirm the locally hosted results remain playable. Stop once basic functionality passes.

Rollback before FullBlast support: stop both generation workers, restore the previous runtime configuration from the pre-change backup, and use the matching old release. Do not run the old image against an enabled `task.fullblast-video` channel; preserve the current database and restore the matching gateway backup if reverting the gateway version. Canvas data must remain preserved. Upstream sync remains a reviewed merge into develop, never an automatic production overwrite.

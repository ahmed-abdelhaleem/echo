"""Executable reconcile/enqueue entrypoint for asset generation (T-ML-052).

The worker (`worker_main`) only *consumes* jobs; something has to *enqueue* the
Season's desired assets. This is that something for local/ops use: it loads the
asset manifests, diffs desired-vs-ready via :class:`AssetReconciler`, and
publishes the missing/stale jobs to JetStream — through the same
:class:`AssetSubmissionService` spend-cap chokepoint the gRPC path uses, so a
configured ``ECHO_ASSET_GEN_PERIOD_CAP`` is enforced here too.

Modes:

- ``--list-only`` — load + validate manifests and print the desired specs.
  Touches no database, queue, or network. Safe for local inspection.
- ``--dry-run`` — classify desired-vs-ready and report what *would* be enqueued
  (reads the repository; publishes nothing).
- (default) — enqueue missing/failed assets to the queue.

Pair with the worker, e.g. for real generation behind the gate:

    make dev-asset-reconcile          # enqueue the season
    make dev-asset-worker-meshy       # generate (requires key + spend cap)
"""

from __future__ import annotations

import argparse
import logging
import os
from pathlib import Path

from app.services.asset_gen.queue import (
    DEFAULT_NATS_URL,
    DEFAULT_STREAM,
    DEFAULT_SUBJECT,
    AssetSubmissionService,
    NatsAssetJobPublisher,
)
from app.services.asset_gen.reconciler import AssetReconciler, load_manifest_dir
from app.services.asset_gen.repository import PostgresAssetRepository
from app.services.asset_gen.spend_cap import build_spend_cap_from_env

logger = logging.getLogger(__name__)

# services/ml-py/app/services/asset_gen/reconcile_main.py → repo root.
_REPO_ROOT = Path(__file__).resolve().parents[5]
_DEFAULT_MANIFEST_DIR = _REPO_ROOT / "content" / "assets-3d"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest-dir",
        default=os.environ.get("ECHO_ASSET_MANIFEST_DIR", str(_DEFAULT_MANIFEST_DIR)),
        help="directory tree of *.manifest.json (desired state)",
    )
    parser.add_argument("--season", default=None, help="only reconcile this season_id")
    parser.add_argument(
        "--budget-cap",
        type=int,
        default=0,
        help="max jobs to enqueue this run (0 = unlimited; the spend cap still applies)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="classify and report without enqueuing (reads the repository)",
    )
    parser.add_argument(
        "--list-only",
        action="store_true",
        help="load + validate manifests and print specs; no DB/queue/network",
    )
    return parser.parse_args()


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    args = _parse_args()

    manifest_dir = Path(args.manifest_dir).expanduser().resolve()
    specs = load_manifest_dir(manifest_dir)
    if args.season:
        specs = tuple(spec for spec in specs if spec.season_id == args.season)
    if not specs:
        raise SystemExit(f"no asset specs found under {manifest_dir} (season={args.season})")

    if args.list_only:
        print(f"{len(specs)} desired asset(s) under {manifest_dir}:")
        for spec in specs:
            print(
                f"  {spec.season_id or '(no-season)':<12} {spec.asset_id:<28} "
                f"{spec.inputs.kind:<12} {spec.inputs.mode:<12} {spec.content_address}"
            )
        return

    env = dict(os.environ)
    submission = AssetSubmissionService(
        repository=PostgresAssetRepository(env.get("DATABASE_URL", "")),
        publisher=NatsAssetJobPublisher(
            nats_url=env.get("NATS_URL", DEFAULT_NATS_URL),
            stream=env.get("ECHO_ASSET_GEN_STREAM", DEFAULT_STREAM),
            subject=env.get("ECHO_ASSET_GEN_SUBJECT", DEFAULT_SUBJECT),
        ),
        spend_cap=build_spend_cap_from_env(env),
    )
    outcome = AssetReconciler(submission=submission).reconcile(
        specs,
        budget_cap=args.budget_cap,
        dry_run=args.dry_run,
        season_id=args.season or "",
    )

    verb = "would enqueue" if args.dry_run else "enqueued"
    print(
        f"reconcile: desired={outcome.desired} {verb}={len(outcome.enqueued)} "
        f"already_ready={len(outcome.already_ready)} "
        f"already_pending={len(outcome.already_pending)} "
        f"deferred={len(outcome.deferred)} spend_capped={outcome.spend_capped}"
    )


if __name__ == "__main__":
    main()


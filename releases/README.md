# Release manifests

One file per released version, written by `.github/workflows/release.yaml`.
Each file records the image tag **and digest** for every service in that
release. Promotion and rollback read from here, so a version can only ever mean
one set of artifacts.

    releases/
      2.0.1.yaml      # v2.0.1
      latest.yaml     # copy of the newest release

Never edit these by hand.

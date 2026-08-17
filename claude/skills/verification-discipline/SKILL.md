---
name: verification-discipline
description: Use before reporting any check, test, build, or task as passing or done — for implementation work, provisioning, sign-off reviews, or status reports back to an orchestrator. Load whenever you're about to write "verified", "passing", "done", or "confirmed" and haven't yet nailed down what evidence backs it, or before trusting a comment/brief's claim about runtime behaviour.
---

# Verification discipline

A green check is only worth what it actually measures. Building an image is not running it. A passing unit suite is not a working service. `docker build` on a devcontainer `Dockerfile` does not run the features layer that `devcontainer up` does. The gap between "the pipeline said pass" and "the thing actually works" is where entire classes of defect hide — runtime images with no application code, service URLs that resolve inside a container network but not from a browser, healthchecks that can never pass, config that only breaks when a real client connects.

## What to do instead

- **Run the thing.** Start the service, the stack, the CLI — whatever the artifact actually is.
- **Build the image** if the change touches packaging, dependencies, or file layout. A missed `COPY` fails at build time and nowhere else.
- **Exercise the real path end to end** with a real request, and assert on the actual response — status code, headers, body. Where data round-trips, compare it (checksums, not vibes).
- **Check the durable state** — query the database, inspect the object store, read the queue — rather than trusting that a `200` means the write landed correctly.
- **Never trust a comment or a brief that asserts runtime behaviour.** "This makes no network call", "this is always UTF-8" — verify it. Assertions inherited from a plan or a code comment are exactly where wrong assumptions hide, including assertions written by whoever dispatched you.

## Match the real environment, not whatever's on hand

A suite that passes on the wrong interpreter or the wrong package manager version tells you very little; the mismatch usually surfaces in CI or on someone else's machine instead. Read the declared versions first (`.python-version`, `pyproject.toml`'s `requires-python`, `packageManager` in `package.json`, `engines`, the CI workflow's setup steps) and match them — provision a throwaway environment rather than testing on whatever the host happens to have and calling it verified. Prefer the project's own container (`.devcontainer/`, `compose.yaml`) where one exists: it gets you the right toolchain by construction and matches what CI does. If you had to hand-provision something to run a standard gate, that's itself a finding worth reporting, not just a step you quietly did.

## A skipped check is not a passed check

Hook chains and CI jobs routinely self-skip when a path filter doesn't match, and in the output that looks almost identical to success. Before reporting a gate as green, confirm it actually executed against your change. If it skipped, say so, and run the underlying command by hand if the thing it guards is load-bearing for the task.

## Report evidence, not a summary

Report the actual observed output for load-bearing checks — the response body, the query result, the log line — not a restated claim that they passed. Never restate someone else's claim as verified fact without either their evidence or your own read-only confirmation. If a checklist item was not genuinely exercised, say so plainly instead of passing along a proxy for it.

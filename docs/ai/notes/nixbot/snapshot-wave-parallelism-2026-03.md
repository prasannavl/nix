# Snapshot Wave Parallelism

## Context

`nixbot` already used `--deploy-jobs` to run deploy work in parallel within a
dependency wave, but snapshot work was still executed serially.

That created an avoidable mismatch:

- build phase could parallelize
- deploy phase could parallelize
- snapshot phase still walked hosts one-by-one even when they were in the same
  wave and `--deploy-jobs` was greater than `1`

## Decision

Use the existing deploy parallelism budget for snapshot work too.

Snapshot execution now uses per-host snapshot jobs for:

- the initial snapshot wave
- the pre-deploy snapshot retry step inside each deploy wave

The same dependency waves still apply; only the execution within a wave is now
parallelized.

## Operational Effect

- hosts in the same snapshot wave can run concurrently when `--deploy-jobs` is
  greater than `1`
- snapshot retries for parented hosts still use the existing bounded retry loop
- snapshot and deploy now follow the same wave-parallelism model

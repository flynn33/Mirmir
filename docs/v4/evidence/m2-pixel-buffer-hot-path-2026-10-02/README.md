# M2 production pixel-buffer hot-path evidence

Captured October 2, 2026 on an Apple M4 Pro MacBook Pro (`Mac16,7`, arm64,
48 GiB), macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), and Apple Swift 6.4.
Every capture began and ended on AC power with nominal thermal state and low
power mode disabled. The harness checked that envelope before and after every
warmup and measured iteration.

## Result

Four independent baseline/candidate pairs pass the 0.80 limit for CPU median,
CPU p95, Metal median, and Metal p95, both in aggregate and for each route.
The worst ratios across the four pairs were:

| Scope | CPU median | CPU p95 | Metal median | Metal p95 |
| --- | ---: | ---: | ---: | ---: |
| Aggregate | 66.33% | 72.22% | 46.97% | 41.84% |
| Individual route | 68.02% | 72.22% | 59.16% | 59.67% |

The representative first pair measured:

| Executor | Baseline median / p95 | Candidate median / p95 | Candidate / baseline |
| --- | ---: | ---: | ---: |
| CPU | 5.013292 / 6.819887 ms | 3.072563 / 4.338190 ms | 61.29% / 63.61% |
| Metal | 4.228770 / 5.174760 ms | 1.808542 / 2.048500 ms | 42.77% / 39.59% |

CPU and Metal produced the same ordered SHA-256 digest of every visible stored
pixel byte on every warmup and measured frame:

- NV12 full range, 512x288 to 853x481:
  `2343ba64fa01b4dc50aaf72ab0718ea47d7e3ac399b8efaf375970c4bba7ba93`
- P010 video range, 512x288 to 768x432:
  `3a04af52933190bd5ce47af8e5ffe69c36d52a7dfc67fe1485ac351eb917e61a`

## Contract and identities

The baseline is revision `54d97e3`. Both routes use the production
`FixedPointPixelBufferScalerV4.process` path, five warmups, and 15 measured
frames per executor. `/usr/sbin/taskpolicy -a` starts the benchmark executable,
each route runs in a high-priority detached task, and CPU and Metal samples are
measured in separate batches. The timed boundary includes the production
scaler call and ordered visible-byte digest. It excludes construction,
coefficient preparation, reusable workspace allocation, pixel-buffer
allocation, and deterministic source fill.

The v4 evidence schema binds a ten-file engine manifest. It adds
`ASHCanonicalJSONV4.swift`, which is a compile-time dependency of the current
HDR adapter. The retained August v3 evidence remains historical and is not
relabeled. Its nine-file manifest and recorded tool identities are unchanged.

Representative identities:

- benchmark harness: `dc7b7812e0d9a447345765a92826f27caf419db4bdbc4c05c7af0543f279b74a`
- benchmark runner: `15b505a6e84f61a501b612d244de1ec8d53bcbb9054b86b1c7e6eb443e5f79a3`
- evaluator: `8b1e2e5cafd524aa566506acf84a1099aca56f5f251987b593df65f65a1abae5`
- four-pair verifier: `d67f151dfc1d8368f5e878c0398ecc6ecce482db1451efa066e9e45865cc0fa5`
- baseline engine manifest: `18a1ee1ccfbf78bc1b56f85b4cbdaf384b4aafafa01950ef454e06fc83db0af7`
- candidate engine manifest: `c2b7b72cf433a09eef3798362517c312a770180bdac93c313bf9acb08a0e0715`
- baseline executable: `81c47f4010f8ba5a079e814f93c50a369be67be63d219939e1f84b36fe150f2d`
- candidate executable: `3e45cbaf3ecb81288bd6ee4c2ec68a50b19ef6ab8f54fc593cd813698f87f7ed`
- shared Metal library: `ca1db9b7abe6c107010eb240d24b9244f69c6897c062d28fdbd4f42749ba36d9`

The evaluator validates machine, OS, compiler, Metal device, power state,
workload, output digest, raw timing samples, and source/binary identities. It
recomputes percentiles from raw samples and applies the 0.80 limit to every
case and aggregate metric. The verifier replays all four evaluations and
checks the stored artifact hashes. Its adversarial contract suite completed
13 tests with zero failures.

## Reproduction

From the repository root:

```sh
baseline_root="$(mktemp -d /tmp/mirmir-m2-baseline.XXXXXX)"
git archive --format=tar 54d97e3 | tar -xf - -C "$baseline_root"
script/v4/run_pixel_buffer_scaler_hot_path_benchmark.sh "$baseline_root" \
  > /tmp/baseline.json
script/v4/run_pixel_buffer_scaler_hot_path_benchmark.sh \
  > /tmp/candidate.json
script/v4/evaluate_pixel_buffer_scaler_hot_path.py \
  /tmp/baseline.json /tmp/candidate.json
script/v4/verify_pixel_buffer_scaler_hot_path_repeatability.py
script/v4/test_pixel_buffer_scaler_hot_path.py
```

Pair 1 uses `baseline-54d97e3.json`, `prepared-direct-after.json`, and
`evaluation.json`. Pairs 2 through 4 use the matching `-pair-02` through
`-pair-04` names. `repeatability.json` binds every file and records the worst
ratios.

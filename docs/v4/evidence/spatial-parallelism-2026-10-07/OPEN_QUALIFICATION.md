# Open qualification — spatial parallelism, 2026-10-07

Source publication as **1.7.0 (17)** retains these open gates. The evidence summarized here was captured before version alignment, with 1.6.0 (16) metadata. It does not establish shipping qualification or a fresh 1.7.0 test-suite result. Exact numerical fields and SHA-256 receipts are in [open-qualification.json](open-qualification.json).

## Retained decoded parity failure

The original full Debug suite passed **635 tests, with six skipped**. Full Release had **630 passed, one failed, five skipped**. The retained failure is `WorkflowApplicationQueueV4Tests/testParallelDeterministicCPUAndMetalFinalize156FrameNTSCJob`, at the strict decoded-BGRA SHA equality assertion in `MirmirTests/WorkflowApplicationQueueV4Tests.swift:3597`.

All 156 complete traced pre-encoder records compare equal, including source/output active-byte hashes, PTS, duration and temporal metadata. Both decoded outputs have 156 frames and equal PTS. Their decoded hashes differ at **ordinals 125–148 and 154: 25 frames**. An independent ffmpeg software decode reproduces those exact differences. Encoded H.264 image slices differ at the same ordinals; picture type at ordinal 126 is CPU B versus Metal P. These are observed differences, not a passing equivalence result.

For the 25 differing frames, converted RGB has maximum absolute sample delta 27, mean absolute delta 1.513035, and combined PSNR 41.022704 dB. Native Y/U/V metrics remain in the JSON. These compare the two outputs, not output against a quality reference; their magnitude does not establish harmlessness or acceptance.

This fixture produces 192×128 = 24,576 spatial samples. The automatic threshold is 262,144, so it uses the preserved serial spatial path. The new parallel stripe branch is inactive. That narrows the investigation without establishing a cause. The trace omits actual writer-handoff DTS and attachments, buffer identity/padding/retained-buffer mutation, and segment-to-final payload evidence. Writer input, encoder behavior and assembly effects remain unresolved.

The subsequent CPU/Metal/same-backend repeat passed one test, with all four runs matching 156 pre-encoder and decoded records. An original-source control also passed four runs: all 399 production sources and 438 tracked Mirmir files matched base commit `817f1f2f56f5b59a5d36818505c368e12069bf48`, and retained products were neither rebuilt nor overlaid. Its unsigned M7 host and fixed-home startup preference warnings differ from the original signed sandbox host. Neither passing control explains the retained failure or proves that it was pre-existing. The original failed result and strict assertion remain intact.

The [earlier 157-frame investigation](../motion-parallelism-2026-10-06/ntsc-parity-investigation.json) separately records 34 decoded mismatches, with no pre-encoder capture. Its later traced repeats passed. Its cause also remains unknown.

## Runtime producer and source identity

The actual canonical `script/v4/build_p06_release_runtime.sh` attempt exited **1**:

```text
error: invalidBuildInput("locked input size/type mismatch: Mirmir/App/MirmirApp.swift")
```

`ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInputs` in `Mirmir/Modules/UpscalerEngine/ASH/ASHP06RuntimeBundleV4.swift` matched 16 of 17 locked inputs. The frozen natural-quality `captureImplementation` lock expects 342,264 bytes, SHA-256 `9fcf2009a18385524f65644cf13e744a0cdd58550808bc43089dff4f12f98a84`; the captured current file was 342,388 bytes, SHA-256 `361c0ce4df777de3ba00162a2efa7a254a7af831f1bf337d3a151527af74a582`. Git commit `5719ce2e08ce324a22e319875179f688c64473d3` contains the exact old capture bytes; that observation does not qualify the current tree.

The attempt's production source closure was `b7a414855429ad9f6147427488672a9df64d4b06e27132f73d7b9586d8106e54`, unchanged throughout the attempt. No fresh artifact directory, runtime bundle or provenance was published. Fresh-candidate artifact comparisons and runtime load/tamper checks therefore did not run. Historical locks, existing runtime assets and expected trust constants were retained.

The actual repository check with `--skip-evidence` exited **2**:

```text
v4 repository identity failed closed: runtime source revision does not match production source closure
```

Ordinary app compilation and source publication do not close this provenance gate. A verified producer design must preserve the frozen evidence identity while binding the current production source; substituting a historical root or changing trust constants alone would not supply that evidence.

## Remaining acceptance and evidence access

At this spatial capture, full-movie DV4-002 stability, matched whole-engine/whole-movie elapsed-time qualification, Intel execution, and new installed-app identity/acceptance were open. The later [finish-stage repair](../end-finalization-repair-2026-10-07/README.md) verified complete saved-job finalization and the installed signed 1.7.0 (17) app. Fresh full GPU processing, matched elapsed time, Intel execution, and these separate parity/source-identity gates remain open. The 8.91× measurement applies to the synthetic 3840×1632 spatial stage on the measured M4 Pro; it is not a feature-length movie speedup.

Original logs, `.xcresult` data, movies and reports are retained locally under `output/spatial-parallelism-2026-10-07/`; they are excluded from source publication. Repository-relative paths, byte counts and SHA-256 values in the JSON identify those local-only originals without machine-private paths. The portable receipt summarizes the failure and limits; it does not embed or replace the originals.

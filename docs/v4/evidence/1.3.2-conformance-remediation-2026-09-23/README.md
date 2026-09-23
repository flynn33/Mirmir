# Version 1.3.2 conformance-remediation evidence

- Result: **PASS**
- Product identity: **Mirmir 1.3.2 (5)**
- Qualified implementation commits:
  `1b0fe3f04d0205d37e44fbfe1786b0a2f0b0e59e` and
  `a2dd5634486804ce11e9dfa5b0adaa39d6f71d52`
- Platform: macOS 27.0 (26A428), arm64
- Toolchain: Xcode 27.0 (27A266a)

This receipt covers post-M7 conformance corrections discovered through
real-file testing. It does not rerun, replace, or reinterpret the sealed M7
candidate-selection result. Shipping, notarization, distribution, and physical
hardware qualification remain outside the declared scope.

## Clean repository qualification

The qualified implementation commits were checked out in a detached worktree.
The full Debug test scheme completed with 493 tests: 490 passed, zero failed,
and three expected opt-in capture tests skipped.

```sh
xcodebuild test \
  -project Mirmir.xcodeproj \
  -scheme Mirmir \
  -destination 'platform=macOS' \
  -derivedDataPath <temporary-derived-data> \
  CODE_SIGNING_ALLOWED=NO
```

Result bundle: `Test-Mirmir-2026.09.23_12-08-22--0500.xcresult`.

The unsigned Release configuration also built successfully as a universal
`x86_64 arm64` executable:

```sh
xcodebuild build \
  -project Mirmir.xcodeproj \
  -scheme Mirmir \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath <temporary-derived-data> \
  CODE_SIGNING_ALLOWED=NO
```

An earlier detached run exposed one failure in
`testRecreatedControllerResumesAtAuthenticatedTrueGapBoundary`: an idle drain
could briefly hold the sole dispatcher slot after returning a paused outcome.
Commit `a2dd5634486804ce11e9dfa5b0adaa39d6f71d52` moved the no-work check before
slot acquisition. The focused resume and dispatcher suite then passed 10 tests,
and the clean full-suite run above passed with zero failures.

After regenerating the P06 contracts, the first full-tree run correctly found
the semantic fixture's superseded expected plan identity. The fixture was
advanced to the newly derived canonical plan hash; its focused proof passed,
and the final clean full-suite run above completed with zero failures.

## Runtime identity reconciliation

The canonical P06 builder reproduced the 12-artifact bundle byte-for-byte in
two independent builds. Compared with the preceding bundle, ten artifacts are
unchanged; `metric_contract.json` and `verification_contract.json` now bind the
stabilized quality evaluator already present in the repository. The runtime
manifest was then resealed to the corrected production source closure:

| Identity | Verified value |
| --- | --- |
| Manifest | `e4cc2394ff7454447d11a37fccf99f8e6c66ca6e68f5302a734e999cd815b5b4` |
| Artifact set | `fd043fd110affc30405f0391c915f8642aa4d8a92ed127883690508281991bf8` |
| Production source | `070556595835048d0112e8de2399be7067ec931079802c906aa8400f51e62f00` |
| Builder source | `944014c7c35eb780722658c63f79e6ea59a14c3b0da25a33b8c78773e9451a68` |

Repository identity replay passed. The production runtime loader accepted all
three identities and rejected a same-length runtime-artifact mutation.

## Release-control identity reconciliation

The optional release-evidence controls were replayed after the conformance
test source and quality evaluator changed. The media-preservation contract now
binds the current fixture source, the aggregate release contract binds both
that lane contract and the current quality evaluator, and the checked-in
external trust root reproduces byte-for-byte from those canonical inputs.

| Control | Verified value |
| --- | --- |
| Media-preservation contract | `0401aa1aa26ea781736faabf035157e5478e12675a70af70f4712e49b65674f3` |
| Release-qualification contract | `4e6ffdec84e7e502a333eb991c6e520faf675e7237ec25e7a3079be4132f3532` |
| Release-qualification trust root | `59c25389f582d5113bb2b880c42536822fb3a20a250fc2b03cf3ad23fc929f3e` |
| Release-control tests | 331 passed; 0 failed |

These locks keep optional future release evidence fail-closed. They do not
claim that a release archive was built, signed, notarized, shipped, or
distributed, and they do not alter the sealed M7 candidate-selection result.

## Reported-file validation

The originally reported fixture was retained outside the repository and was not
committed. The repaired migration path completed with its video, audio, and
auxiliary image streams accounted for by the semantic verifier.

| Artifact | SHA-256 |
| --- | --- |
| `raven-forge-app-splash-2.mp4` | `c888b71b97a536d0e38558c77ec332e483e8493d3bf28a853fca418639d2b017` |
| validated MOV output | `709ee41491ff3354c0dc6618215cc982a3cec2d716d872b72cbe3d7f5d7f9ce8` |

| Stream | Source | Output |
| --- | --- | --- |
| H.264 video | 241 packets; 10.041667 s; `1/12288` | 241 packets; 10.041667 s; `1/12288` |
| AAC audio | 470 packets; 10.000000 s; `1/48000` | 470 packets; 10.000000 s; `1/48000` |
| MJPEG auxiliary video | 1 packet; 10.041667 s; `1/90000` | 1 packet; 10.041667 s; `1/90000` |

## Regression mapping

| Corrected boundary | Representative automated proof |
| --- | --- |
| Exact movie/edit timebase | `testEditMapMovieTimescaleExactlyRepresentsPlannedMapping` |
| Processed media origin | `testProcessedVideoReplacementRestoresNonzeroMediaOriginWithoutDroppingFrames` |
| AAC MP4-to-MOV identity | `testAACMP4PassThroughToMOVPreservesSemanticIdentityAndSamples` |
| Decoded cadence | `testSegmentedCanonicalDynamicAbsentH264UsesDecodedPresentationDomain` |
| Video-range excursions | `testVideoRangeExcursionsReachSpatialKernelAndOutputsRemainNominal` |
| P010 packing | `testP010VideoRangeEnforcesSignalBoundsAndSixZeroLowBits` |
| Atomic destination identity | `testMigrationUsesBoundDeterministicTemporaryAndRejectsUnsafePaths` |
| Durable basename migration | `testVerifiedLegacySourceSnapshotRequiresReenqueueBeforeDispatch` |
| Immediate paused-job resume | `testRecreatedControllerResumesAtAuthenticatedTrueGapBoundary` |

## Preserved M7 decision

The sealed simulator-only M7 result remains `candidate_v4` at source commit
`ce780af87107d90142d860f328dca4a72fea3047`: quality index 122.792052,
paired-bootstrap 95% lower bound 122.312761, total processing-time ratio
0.025213, median ratio 0.026859, and p95 ratio 0.030117 across 168 cases.

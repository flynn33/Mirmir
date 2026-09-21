# Deterministic engine v4 current qualification status

Verified September 21, 2026.

## Product and source identity

| Field | Verified value |
| --- | --- |
| Product | Mirmir 1.3.0 (3) |
| Version authorities | `VERSION` = `1.3.0`; `BUILD_NUMBER` = `3` |
| Bundle identifier | `com.mirmir.app` |
| Minimum macOS | 15.4 |
| Source commit | `36b749d20b173eb324385cdae552a9698d5d74b9` |
| Git tree | `63b5905eaaf4d99ffc9b81b83a21441afca9c371` |
| Source-tree identity | `e7253bdfd758f9315cdaf333295b6c4341dd292ee5735f9be85a09812eabfb60` |
| Source-manifest identity | `daa220a9b5d86e876b7bd46ca5636770bd24a050eab71bbe1149cb017e70132f` |
| Archive receipt SHA-256 | `7afddfbee8d2639dc8a23410c68fad309b267c6d062658a9ee606251451ba8e6` |

The canonical archive contains `arm64` and `x86_64` slices and is signed by
`Developer ID Application: James Daley (9AQ2C2838M)` with Team ID
`9AQ2C2838M`. Strict signature verification passes, both slices carry hardened
runtime flags, and the entitlements contain App Sandbox, app-scoped security
bookmarks, and user-selected read/write access without `get-task-allow`.

## Reproducible artifact identities

| Artifact | SHA-256 or stable identity |
| --- | --- |
| Signed executable | `90bd01cd1b61d1dc31b3033a7cceb6cdb4b5140e47ed631e171ff1b9cd352e4e` |
| Signer-independent executable | `58a22ebc23b72406f0ecb4b9b1beb93e820b5cb5fafac0f404149d50811fc211` |
| Reproducible bundle | `ae21d817eabb74421bb55f997a4e5c732a4dbb41e4671a69e7e62c472e56f21d` |
| Processed `Info.plist` | `e8249eb19a1f464c2a93ce886ca979230130cf93de3cc967f84df98f5ec12f49` |
| Default Metal library | `11134d720d785998bded5f85cc388e1001a536a78fdb17d3624c606b466af4dc` |
| Pre-notarization ZIP | `b984c9f0fae25f7c7ba6724acd3c4c77d16b4e41b94b371526531110fb0ee437` |
| External trust root | `083b9fd50c2c3b0541b1ee3a0539a468fdf10b8a644dbe26d9f92f98f2235943` |
| Natural-corpus manifest | `f999e0607dfac799ee0531804d14c4e6333db3bee20328898498e6a5e9a96896` |
| Natural-corpus artifact set | `750cab4072c635f30a925dd7715c1729213f14601855a841fb6d3f32cf1db66e` |

The archive audit also found no staging residue, quarantine attribute,
in-archive `.DS_Store`, candidate-entitlements file, or signing-identity drift.
Its expected current Gatekeeper state is an unnotarized Developer ID build.

## Completed verification

The qualification implementation and control surface passed 205 focused tests:

| Test area | Passed |
| --- | ---: |
| Candidate provenance | 39 |
| Media preservation | 44 |
| Recovery | 11 |
| Release runner | 2 |
| Packaged-candidate controls | 3 |
| Evidence-index assembly | 17 |
| Central release qualification | 58 |
| Performance contracts and evaluator | 31 |
| **Total** | **205** |

Repository identity replay, semantic qualification self-tests, deterministic
trust-root regeneration, attribution scans, Xcode project parsing, and version
alignment also pass. A clean Debug scheme run on the current project completed
472 tests successfully with zero failures and three expected opt-in capture
tests skipped. A clean unsigned universal Release build also passed and read
back version 1.3.0, build 3, category `public.app-category.video`, and both
`arm64` and `x86_64` executable slices. These checks prove the implementation
and evidence machinery; they are not substitutes for executing every final
evidence lane on the sealed candidate.

## Open release gates

The archive has not been uploaded to Apple, notarized, stapled, published, or
distributed. Those actions are owner-deferred.

After the owner completes notarization and stapling, the exact sealed candidate
must run the following lanes:

1. same-scope performance, first and without concurrent qualification work;
2. quality against the locked natural corpus;
3. P06 clean-build reproduction;
4. CPU/Metal visible-plane parity;
5. whole-asset media preservation;
6. packaged-process recovery;
7. signed support-matrix capture;
8. notarized smoke, last, inside its freshness window.

The evidence index must then be assembled, evaluated, and independently
verified. Until that succeeds, Mirmir does **not** claim that this frozen
candidate has proved the at-least-5% quality increase or at-least-20%
processing-time reduction, and it is not represented as fully release
qualified.

## Historical evidence boundary

Earlier milestone and calibration evidence remains useful for implementation
decisions. In particular, the synthetic quality calibration exceeded the
aggregate quality threshold but failed the high-motion non-regression and
production-lock conditions, while timing diagnostics used an ineligible small
corpus. Those results must not be promoted into the final M7 decision.

# Mirmir licensing proposal and release review

Prepared September 26, 2026. **Draft for maintainer and legal review; not an
adopted license or a determination of enforceability.** The proposed terms
are in [LICENSE](LICENSE). Its draft-status paragraph grants no permissions
until the copyright holder adopts it; its public-release condition also
protects material that has not intentionally been released to the public.

## Intended policy

Make Mirmir available for scrutiny as an implementation using the ASH Model,
while reserving commercialization of Mirmir's original protected code. This
policy supports independent testing, replication, and criticism; it is not
a claim that the software has already proved any scientific or security
hypothesis.

The proposal is deliberately narrower than a blanket noncommercial license.
Research and education are allowed; unpaid entertainment, ordinary media
processing, and general consumer redistribution are not automatically allowed.
It is also broader than a bare ban on resale in the activities it restricts:
commercial services and commercial reuse of covered code require permission.

| Activity using covered Mirmir material | Proposed treatment |
| --- | --- |
| Read, build, inspect, and modify for study or teaching | Permitted after adoption and public source release |
| Replicate or challenge performance, correctness, and security claims | Permitted, including negative findings |
| Publish a paper, benchmark, or reasonably necessary explanatory excerpt | Permitted with the applicable attribution |
| Share a research fork or reproducibility build | Permitted under the license's research-distribution conditions |
| Ordinary tuition, research salary, grant, or journal fee | Does not alone disqualify an otherwise permitted activity |
| Sell a renamed fork or bundle covered code into a commercial app | Requires separate written permission |
| Operate a paid processing service or deploy a source build in business operations | Requires separate written permission |
| Provide a general consumer build, even free | Not permitted under this research license |
| Use an official purchased Mirmir application | Governed by its separate application terms, not this source license |
| Reuse independently MIT-licensed ASH material | Governed by its applicable MIT terms, not narrowed by this proposal |

The permission for genuine public research artifacts is intentional. Allowing
research builds necessarily allows recipients to possess runnable software;
license terms are not technical copy protection and cannot guarantee that
no recipient will misuse a copy.

## Why a custom research license is proposed

OSI's Open Source Definition requires rights incompatible with a research-only
or no-commercial-use policy. Describe this as **source-available for research
and education**, not as OSI-approved open source.

PolyForm Noncommercial 1.0.0 is an established alternative worth considering
when broader noncommercial availability is acceptable. Its terms include
personal entertainment and hobby uses and broad permissions for listed
noncommercial organizations. Those permissions are broader than this
research-and-education proposal. A custom license has the disadvantage of
needing individual legal review and potentially more review by universities
and institutional users; this proposal is not presented as a standard form.

## Existing notices that must be reconciled

The following are observations from the repositories inspected on
September 26, 2026, not a complete rights or dependency audit:

1. Mirmir's root directory had no top-level license file. Its README pointed
   to a separately governed bundled ASH notice.
2. The current upstream [ASH-Model LICENSE](https://github.com/flynn33/ASH-Model/blob/main/LICENSE)
   states the MIT License, with copyright attributed to James Daley (2026).
3. Mirmir's [bundled ASH notice](Mirmir/Resources/Legal/ASH-Model-LICENSE.txt)
   instead identifies James Daley (2025-2026) and permits educational use
   and individual noncommercial experimentation, while restricting other uses.
4. Mirmir's [Info.plist](Mirmir/Info.plist) displays a Raven Forge Software
   copyright notice for 2026. The proposed LICENSE follows that display name;
   it is not evidence establishing who legally owns all rights.

The ASH notices may concern different revisions or licensing histories.
Do not automatically overwrite the bundled notice with upstream MIT text,
or assume the bundled notice restricts every current upstream ASH file.
Identify the exact imported source/artifact revisions, applicable licenses,
and any separately granted rights. Preserve permissions already granted
under MIT for applicable copies. The proposed Mirmir license deliberately
does not resolve or override this discrepancy.

Confirm whether Mirmir's licensor should be James Daley personally, a named
legal entity, or a properly stated trade-name relationship. Confirm ownership
or adequate commercial licensing rights for all included contributions;
being a repository owner is not by itself proof of copyright ownership.

## App Store and TestFlight separation

The proposed LICENSE is for public source access and research derivatives,
not the customer EULA. Do not paste it into App Store Connect as Mirmir's
customer license. Apple provides a standard EULA unless an applicable custom
EULA is supplied. Review the customer terms separately so purchasers receive
the intended ordinary personal and professional application-use rights.

The planned $24.99 price is intentionally absent from the license. A price
change should not require changing source permissions. Nor does the license
make an App Store release or public-source release happen automatically.

## Contributions

The research license does not automatically authorize the maintainer to sell
an external contributor's original additions. Before accepting outside code
for commercial inclusion, establish an explicit inbound policy or contributor
agreement that permits the intended commercial distribution and, where
needed, relicensing. Do not assume a research-only inbound grant supplies
those rights. Obtain any employer or other rightsholder permissions needed.

## Adoption and public-release checklist

- Have software/IP counsel review the final scope, copyright-owner identity,
  limited patent grant, termination terms, and jurisdiction-specific issues.
- Resolve ASH provenance and notice differences; inventory dependencies,
  sample media, fonts, datasets, and contributor rights. Check compatibility
  with both public source distribution and the commercial application.
- Approve the policy on ordinary personal source builds, public research
  binaries, funded research, and commercial product development.
- On adoption, remove the explicit draft-status paragraph from LICENSE.
  Keep Section 1's intentional-public-release condition. Merge the reviewed
  files into the intended release branch before making the repository public.
- Replace README's existing license section with the reviewed summary below,
  adjusted as necessary to accurately describe the resolved ASH notices.
- Keep official application terms and required bundled notices consistent
  with the chosen distribution channels. Do not replace the customer EULA
  with the research-only source license.
- Before public release, review repository history, CI artifacts, logs,
  screenshots, and fixtures for secrets, signing material, private data,
  and material you cannot redistribute. This licensing review did not
  perform that security or content audit.
- Make the repository public only after the intended Mac App Store release
  and these checks. Publication exposes source and accessible history; later
  making a repository private does not remove existing local copies or forks.

## Suggested README section after adoption

Replace the existing license section only after the policy and separate
notices have been reviewed:

```markdown
## Source availability and licensing

Mirmir's original source code is made available under the
[Mirmir Research and Education License](LICENSE) to support academic study,
independent research, teaching, security review, and reproducible evaluation
of its use of the ASH Model.

Subject to that license, you may inspect, build, test, modify, and share
research copies and publish findings, including critical or negative results.
Resale, commercial reuse of covered code, commercial hosted services, and
general-purpose consumer redistribution require separate written permission.
Ordinary nonresearch use of a source-built application is not included.

Mirmir is source-available for research and education, not OSI-approved open
source. Official application builds are governed by their separate end-user
terms; this source license is not the Mac App Store customer EULA.

ASH Model material and other separately licensed components retain their
applicable licenses and notices, including any applicable MIT permissions.
See [licensing information](LICENSING.md) and the bundled notices.

Commercial permission requests: contact@ravenforgesoftware.com.
```

## Reference material

These sources informed the recommendation; they do not endorse this custom
license. Repository observations above should be rechecked at adoption.

- [Open Source Initiative: Open Source Definition](https://opensource.org/osd)
- [PolyForm Project: Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)
- [GitHub: Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)
- [GitHub Open Source Guides: The legal side of open source](https://opensource.guide/legal/)
- [U.S. Copyright Office: What does copyright protect?](https://www.copyright.gov/help/faq/faq-protect.html)
- [Apple: Provide a custom license agreement](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/)

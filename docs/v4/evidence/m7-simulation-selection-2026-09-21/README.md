# M7 simulator selection evidence

- Result: **PASS**
- Source commit: `ce780af87107d90142d860f328dca4a72fea3047`
- Selected policy candidate: `candidate_v4`
- Corpus: `ash-v4-seven-cohort-synthetic-diagnostic-v1` (168 cases)

| Rank | Candidate | Eligible | Quality index | 95% lower bound | Total ratio | Median ratio | p95 ratio |
| ---: | --- | :---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `candidate_v4` | yes | 122.792052 | 122.312761 | 0.025213 | 0.026859 | 0.030117 |
| 2 | `temporal_hysteresis_off` | yes | 122.787508 | 122.296964 | 0.025655 | 0.026916 | 0.030094 |
| 3 | `randomized_state_message` | yes | 122.802557 | 122.293538 | 0.027947 | 0.029551 | 0.032711 |
| 4 | `uniform_priors` | yes | 122.773418 | 122.271120 | 0.028668 | 0.030370 | 0.033743 |
| 5 | `motion_history_off` | yes | 121.171289 | 120.700954 | 0.016389 | 0.015952 | 0.019587 |

This is simulator model-selection evidence only. It does not assert device qualification, notarization, shipping, or distribution.

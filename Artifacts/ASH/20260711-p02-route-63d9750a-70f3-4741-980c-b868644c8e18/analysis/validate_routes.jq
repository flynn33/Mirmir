def observations($snapshot; $kind):
  [$snapshot.media[] | select(.kind == $kind)];

def transitions($snapshot):
  [
    "created",
    ($snapshot.media[]
      | select(.kind == "output_transaction_transition")
      | .details.to)
  ];

def common_checks($snapshot; $dimensions):
  (observations($snapshot; "frame_read")) as $read
  | (observations($snapshot; "frame_appended")) as $appended
  | (observations($snapshot; "output_reopen_verified")) as $verified
  | {
      status_success: ($snapshot.result.status == "success"),
      intervals_balanced: ($snapshot.result.balanced_intervals == true),
      no_recorded_failures: (($snapshot.result.failures | length) == 0),
      no_command_buffer_errors: ($snapshot.counters.command_buffer_errors == 0),
      no_partial_cleanup_failures: ($snapshot.counters.partial_cleanup_failures == 0),
      exact_frame_count: (($read | length) == 1 and ($appended | length) == 1),
      exact_pts: (
        $read[0].pts_value == 0
        and $read[0].pts_timescale == 600
        and $appended[0].pts_value == 0
        and $appended[0].pts_timescale == 600
      ),
      exact_duration: (
        $read[0].details.duration_value == "10"
        and $read[0].details.duration_timescale == "600"
        and $appended[0].details.duration_value == "10"
        and $appended[0].details.duration_timescale == "600"
      ),
      two_input_planes: ($read[0].details.plane_count == "2"),
      verified_hevc_dimensions: (
        ($verified | length) == 1
        and $verified[0].details.codec == "hvc1"
        and $verified[0].details.dimensions == $dimensions
      ),
      verified_exact_frame_count_and_duration: (
        $verified[0].details.frame_count == "1"
        and $verified[0].details.duration_value == "10"
        and $verified[0].details.duration_timescale == "600"
      ),
      verified_nonempty_two_plane_payloads: (
        ($verified[0].details.luma_payload_bytes | tonumber) > 0
        and ($verified[0].details.chroma_payload_bytes | tonumber) > 0
      ),
      transaction_order: (
        transitions($snapshot)
        == ["created", "writing", "finishing", "verifying", "published"]
      ),
      published_once: ((observations($snapshot; "output_published") | length) == 1)
    };

def all_true($checks):
  all($checks[]; . == true);

($direct[0]) as $d
| ($lanczos[0]) as $l
| (common_checks($d; "3840x2160")) as $direct_checks
| (common_checks($l; "1920x1080")) as $lanczos_common
| ({
    exactly_one_buffer: (($l.command_buffers | length) == 3),
    lifecycle_order: ([$l.command_buffers[].status] == ["created", "committed", "completed"]),
    frame_and_pts_bound: all($l.command_buffers[];
      .frame_index == 0 and .pts_value == 0 and .pts_timescale == 600),
    terminal_status_completed: ($l.command_buffers[-1].status == "completed"),
    gpu_timestamps_ordered: (
      $l.command_buffers[-1].gpu_start_seconds != null
      and $l.command_buffers[-1].gpu_end_seconds != null
      and $l.command_buffers[-1].gpu_end_seconds >= $l.command_buffers[-1].gpu_start_seconds
    )
  }) as $lanczos_command_buffer_checks
| {
    schema_version: "1.0.0",
    routes: [
      {
        id: "direct-1080p-to-2160p",
        checks: $direct_checks,
        status: (if all_true($direct_checks) then "pass" else "fail" end)
      },
      {
        id: "ash-2x-lanczos-720p-to-1080p",
        checks: ($lanczos_common + {command_buffer: $lanczos_command_buffer_checks}),
        status: (
          if all_true($lanczos_common) and all_true($lanczos_command_buffer_checks)
          then "pass"
          else "fail"
          end
        )
      }
    ]
  }
| . + {
    overall_status: (if all(.routes[]; .status == "pass") then "pass" else "fail" end)
  }
| if .overall_status == "pass" then . else error("route validation failed") end

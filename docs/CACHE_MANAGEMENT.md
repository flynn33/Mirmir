# Cache management

Mirmir 1.7.1 build 19 carries the durable workflow-cache controls introduced in
1.4.0 build 9 and the 1.4.2 confirmation and post-action readback repair. The cache
contains queue state, private source snapshots, checkpoints, recovery records,
and recognized in-progress working artifacts. Completed output movies remain at
the destinations selected by the user and are not cache contents.

## Location selection

Settings shows the current cache path and provides **Choose Location…** and
**Use Internal Storage**. A custom location may be a local folder, mounted
removable drive, or mounted network share. Mirmir stores a security-scoped
bookmark and uses `Mirmir/WorkflowV4` beneath that selected directory. Internal
storage uses the application-support workflow root.

Mirmir has exactly one active cache root. A location change is rejected while
the current root contains any job. Settings displays **Delete the jobs in this
cache before changing its location.** Jobs are not migrated implicitly.
The app's sandbox cache persists when its application bundle is reinstalled.

If a saved custom location cannot be reopened, Settings reports the
unavailable path and retains both recovery choices. Selecting internal storage
creates or reopens the internal root without deleting or migrating data on the
unavailable custom root.

## Deletion controls

Each queue row exposes Delete only for an inactive lifecycle. Settings also
provides confirmed **Delete Finished Jobs…**, **Delete Unfinished Jobs…**, and
**Clear Cache…** actions with live finished and unfinished counts.
One workspace confirmation presenter handles these actions and queue-row
deletion. After confirmation, Mirmir awaits the requested operation and reads
back the journal-backed queue; once the last job is removed, **Choose Location…**
becomes available.

Deletion is permitted for queued, paused, contained, completed, failed,
safe-halt, and cancelled jobs. It is rejected for probing, planned, running,
pausing, verifying, committing, and recovering jobs. Pause or cancel active
work before deleting it.

The durable `jobDeleted` event is appended before the queue-owned job directory
is removed, so deletion survives relaunch. Bulk deletion rejects the operation
before removing anything if its selected set includes an active lifecycle.

## Ownership boundary

Job cleanup accepts only the exact validated directory
`<workflow-root>/jobs/<job-id>` and refuses symlinks or a mismatched parent.
Working-cache cleanup accepts only names beginning `.mirmir-job-` and ending
`.partial.segment.mov` or `.assembled-video.mov` inside
`cache-v4/application-working-media-v4`. Unknown files are retained.

Destination movies are outside both owned namespaces. Individual deletion,
bulk deletion, and Clear Cache therefore cannot target a completed output
movie. Automated tests write destination data, delete the corresponding cache
state, and verify the destination bytes remain unchanged.

## Automated verification

The cache-management regression cases cover location selection, bookmark
persistence across store recreation, unavailable-root recovery to internal
storage, individual deletion, finished and unfinished bulk deletion, owned
working-artifact cleanup, destination preservation, durable replay, and active
job rejection. The historical build-9 serial macOS Debug scheme completed 532
tests: 529 passed, zero failed, and three expected opt-in capture tests skipped.
The 1.4.1 build-10 serial scheme completed 540 tests: 537 passed, zero failed,
and the same three expected opt-in capture tests skipped. Three additional
1.4.2 isolated-store tests passed for completed, failed, cancelled, paused,
and contained jobs,
including the zero-job location gate and completed-output preservation. The
full 1.4.2 macOS Debug result bundle reports 543 total tests: 540 passed,
zero failed, and three expected opt-in capture tests skipped. After the fixture
proof, owner-authorized live cleanup removed 18 finished and four unfinished
jobs through the same view-model methods, then cleared residual cache data. At
that October 1 check, the installed 1.4.1 app reopened the same root with zero
jobs and **Choose Location…** enabled; it was not replaced during that
verification.

The named cache-control cases are
`testCacheControlsDeleteCompletedFailedCancelledThenPausedContainedAndUnlockLocation`,
`testCacheControlsDeleteContainedRowAndUnlockLocation`, and
`testCacheControlsClearCompletedFailedCancelledPausedContainedAndOrphans`.
Each passed in the isolated fixture run. The preceding full scheme ran their
earlier three-state versions.

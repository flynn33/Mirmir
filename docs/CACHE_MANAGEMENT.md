# Cache management

Mirmir 1.4.0 build 9 exposes the durable workflow cache in Settings. The cache
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

If a saved custom location cannot be reopened, Settings reports the
unavailable path and retains both recovery choices. Selecting internal storage
creates or reopens the internal root without deleting or migrating data on the
unavailable custom root.

## Deletion controls

Each queue row exposes Delete only for an inactive lifecycle. Settings also
provides confirmed **Delete Finished Jobs…**, **Delete Unfinished Jobs…**, and
**Clear Cache…** actions with live finished and unfinished counts.

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
job rejection. The build-9 serial macOS Debug scheme completed 532 tests: 529
passed, zero failed, and three expected opt-in capture tests skipped.

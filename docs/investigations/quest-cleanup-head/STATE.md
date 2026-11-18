# Quest release cleanup and concurrent Git writers

[Issue #112](https://github.com/abominableenterprise/yetikit/issues/112) covers
same-tree commits: two different commit IDs can have identical trees, so a
clean status or an unchanged patch does not prove HEAD is still the release
commit.

Cleanup opens a verify-only `git update-ref --stdin` transaction on the
linked worktree's HEAD. It waits for Git to prepare the transaction, then
checks that HEAD is detached and still at the expected commit. For noise
reversal it compares the inspected patch again under that lock before applying
it. For removal it acquires a fresh transaction and runs non-forced
`git worktree remove`. A move that wins before either transaction prevents
that action; an ordinary HEAD update that contends with the held ref lock
cannot win while that lock exists. Closing the transaction's input aborts it
without changing HEAD or writing a reflog entry.

This does **not** make `git worktree remove` atomic with HEAD updates. Git has
no `worktree remove` option that takes an expected commit or holds a ref lock
outside the worktree's admin directory. Removal checks dirtiness, deletes the
worktree files, and recursively deletes the admin directory. That deletion
can unlink the ref lock itself before removing the remaining metadata; a
waiting or newly started writer is not guaranteed to be excluded during that
teardown. See [Git's removal implementation](https://github.com/git/git/blob/v2.39.5/builtin/worktree.c#L1091-L1145).
`git worktree lock` prevents removal but does not prevent HEAD updates, so
unlocking it to remove the worktree does not solve the problem.

The ref lock also does not serialize index or filesystem writes. A command
such as checkout or reset may touch files or the index before attempting its
ref update, and direct file edits or tools that ignore Git's locks are not
covered. Keep release worktrees idle during cleanup: stop editors and any
other processes that might edit them or run mutating Git commands against
them (including commands from other worktrees targeting their refs).

The synthetic fixture runs real `git update-ref` writers exactly at the two
command boundaries, with no sleeps. Both writers succeeded before the change;
both now fail to acquire the ref lock at those boundaries. The fixture does
not assert that Git holds the ref lock throughout admin-directory deletion.
A general guarantee requires an owner policy excluding external writers for
the whole cleanup, or a Git removal primitive that provides that guarantee.

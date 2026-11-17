# vm2lxc status

Updated 2026-11-17 (Larry:gus), after the independent review. Local repo `main`; remotes `forgejo` (private), `nas`, and
`origin` = GitHub (private). See "Publishing".

## TL;DR

- `preflight`, `scan [vmid...]`, `inspect <vmid>` and `cleanup` work and have been **run for real** on a Proxmox VE 9.2.28 host
  (LVM-thin) against the four disposable test VMs 600-603. `convert` and `undo` are still stubs.
- **283 tests pass, 0 skipped**, shellcheck clean. The safety rails were mutation-tested (36 single-fix reversals, all killed but one
  equivalent mutant, listed below).
- On the real host: the host returned to its baseline after every run, the sha256 of the source disks of a stopped VM was identical
  before and after, and 61 crash injections (SIGKILL / SIGTERM / SIGHUP) were recovered.
- **ZFS has never run on real hardware** (the test host has no ZFS storage in use). It is tested against a stateful fake only.
- Grok 4.7 produced **no review in four attempts** (details below). An independent fresh-context box review replaced it: **12 findings,
  all fixed with a test each** (one was HIGH: a failed journal write was ignored, so an action could run unrecorded).
- After the fixes the real-host checks were **repeated** on test VMs 600-603 (see "Re-verified after the review").

## What exists

| Command | State | Notes |
|---|---|---|
| `preflight <vmid>` | real-host verified | verdict (exit 0/10/20), disk and NIC plan, RAM/CPU sizing from RRD, 12 guest checks pending |
| `scan [vmid...]` | real-host verified | ranks by verdict then RAM saved; ids restrict it (never reads other VMs) |
| `inspect <vmid>` | real-host verified for LVM-thin | plan by default; `--yes` snapshots, mounts read-only, looks inside, tears down. Refuses a locked VM |
| `cleanup` | real-host verified | lists, and with `--yes` removes, what crashed runs left, from vm2lxc's own journals only |
| `convert`, `undo` | stubs | exit 70 |

Design, rails R1-R15, journal format, failure matrix, real-host evidence: `docs/snapshot-layer.html`. Front page: `README.md`.

## Real-host evidence (2026-11-17, hex, PVE 9.2.28, test VMs 600-603 only)

- 4 VMs inspected repeatedly: Debian 12 (root + EFI), Ubuntu 24.04 (two ext4 + EFI), Alpine, a two-disk Debian whose second disk is a
  whole-disk ext4. After each run: identical LV list, thin-pool usage, no loops, no mounts, journal CLOSED, nobody holding the lock.
- Bit-identical source: VM 603 was shut down, both disks hashed (sha256), `inspect --yes`, hashed again: equal. VM restarted.
- Crash sweeps (61 runs): SIGKILL leaves at most a stray snapshot LV and `cleanup --yes` restored the exact baseline each time.
  The sweeps found two real gaps (a signal during teardown aborted it; no SIGHUP handler): fixed, then 26 of 26 TERM/HUP runs clean.
- The first real run also showed what fakes cannot: LVM warned about a leaked lock fd (fixed), PVE 9 prints a `Total (KiB)` storage
  header, `template: null` in the VM list and a 30-minute month RRD step. A real PBS backup job later locked VMs 600/601 mid-session,
  which exposed that `inspect --yes` did not check `lock:` (fixed, rail R15).
- Real data captured read-only as `tests/fixtures/pve9-real` (no secrets: checked, gitleaks clean).

## Re-verified after the review fixes (2026-11-17, hex, VMs 600-603 only)

- Deployed source = `HEAD` (14 files, per-file sha256 identical). `inspect --yes` on all four VMs: exit 0, guest root found, host
  fingerprint (LV list hash, loops, mounts, snapshot LVs, thin-pool use) identical to the pre-run baseline after every run.
- **Mount options seen live in `/proc/mounts`:** `ro,nosuid,nodev,noexec,relatime,norecovery` (the kernel prints our `noload` as
  `norecovery`). This was the one behaviour a fake cannot prove, because the option set is now an exact whitelist.
- Crash sweep with the new teardown: SIGTERM (143), SIGHUP (129) and the reviewer's SIGPIPE case (141) each tore down clean to
  the baseline; SIGKILL left one snapshot LV and one open journal and `cleanup --yes` restored the baseline exactly.
  (An `INT` row returned 0 because bash starts background jobs with SIGINT ignored, so it never reached the tool; Ctrl-C is
  covered by the fake-host test.)
- `scan` and `preflight` (read-only) rerun after the sanitiser change: unchanged verdicts. The test VMs were never restarted.
- Not re-done: the sha256 source-disk proof (it needs a VM stop). The mount options it protects are unchanged in meaning and were
  just observed live.

## Independent review (box job on hex, fresh context): 12 findings, all fixed

F1 HIGH journal write failures ignored. F2 undo probes treated errors as "absent". F3 real `lsblk` prints `/dev/zdN` for zvols
(every ZFS mount would have been refused) and lists guest LVM/md children. F4 SIGPIPE/QUIT and a gap before the ignore list could
kill the teardown. F5 guest symlinks pointing at the host accepted as a guest root. F6 crafted journal executed a command via an
arithmetic subscript. F7 empty/tab/newline journal args. F8 mount options not an exact whitelist, `..` in device names, stamp not
read with `-s local`, PATH and run root trusted. F9 UTF-8 C1 CSI and bidi overrides not stripped. F10 15-bit run id. F11 no
re-validation after the lock. F12 journal directory not fsynced. New rails R16-R21 in `docs/snapshot-layer.html`.

The mutation pass exposed four weak spots in my *tests*, all closed: a journal that cannot be opened, a lost UNDONE mark with a
working close, a traversal run id that resolves to a readable journal, and a partial mutant. One equivalent mutant remains by
design: the explicit `trap 'exit 141' PIPE` is belt and braces, because bash runs the EXIT trap on SIGPIPE death itself.
Eight `! cmd` assertions that could never fail were found and converted to `must_fail`.

## Bugs found in this stretch (all fixed, each with a test; most mutation-checked)

First real run: lock fd inherited by children; stale `/run/vm2lxc`; truncated NAME column. Crash sweep: signal during teardown aborts
it; no SIGHUP handler. Test-found: signal-triggered teardown output lost to the interrupted command's `>/dev/null 2>&1`; teardown kept
going after a failed unmount. Own adversarial review: no timeout on host commands; leading `-`/`.` in names reaching option
positions; `cleanup` could present a live run as abandoned; control characters (terminal-escape injection) in config text and VM names;
locked VMs not refused. Safety design: pre-existing same-named objects must never be adopted or later destroyed (journal state FOREIGN).

## Grok 4.7: four attempts, zero findings

1. Plan mode, 22 min: died on a compound shell command not covered by my `--allow` rules (headless cannot ask).
2. 45 min in a bwrap + strict sandbox: killed by my cap, 30 tool calls, nothing written.
3. 40 min, focused brief, `--effort medium`: killed by the cap, 17 tool calls, nothing written.
4. 8 min, 13 KB inline, `--effort low`: timed out, 0 bytes.

Measured from Grok's own event log: **99-100% of every session was `streaming_reasoning`**, tool execution about 0 seconds, and `--effort`
made no measurable difference (same ~270 reasoning bursts per minute). So it is the model deliberating without converging, not the
sandbox, network or tools. Safety setup used (worth reusing): a `bwrap` container (only /usr, /etc, the repo copy, a throwaway HOME, an
empty tmpfs /tmp) plus Grok's own `--sandbox strict`, a scrubbed environment (only `XAI_API_KEY`), and a sanitised copy of the code. The
stock `--sandbox strict` alone let it read all of `/tmp` (a canary proved it), and `--tools ""` restricts nothing.

## Open questions

1. **GitHub visibility.** I create the GitHub repo as **private**. Making it public needs a scrub first: `docs/BRIEF.md`,
   `docs/KICKOFF.md` and `STATUS.md` are internal planning notes that name real VM IDs and host details, and the git history contains
   them. Recommended: a fresh public history from the current tree minus those three files.
2. **jq on PVE 8.** PVE 9.2 ships jq 1.7 (fine). PVE 8 ships 1.6; the code sticks to 1.6 features but only 1.7/1.8 have run.
3. **A real ZFS run** needs a PVE host with a ZFS-backed VM (Proxmox Expert). The `/dev/zdN` kernel-name handling added for F3 has
   only run against the fake.
4. **LICENSE** has the credit block appended below the MIT text, which may stop GitHub's license detector recognising plain MIT.
5. Should a v1 storage limit be RED or a separate label in `scan`? Should templates appear in `scan` at all?

## Housekeeping and things left on the test host

- On hex: `/root/vm2lxc-src` (the deployed source, kept for re-runs), `/var/lib/vm2lxc/runs/*` (70 small CLOSED journals, the audit
  trail of the real runs) and two scratch logs from the last sweep, `/root/mountwatch.log` and `/root/sweep.out`. All are mine and
  safe to remove; I left them rather than delete on the hypervisor without asking. VM 603 was stopped and started once earlier for
  the checksum proof; all four test VMs are running.
- Scratch under `~/.cache/vm2lxc-grok-review*` (Grok sandboxes): to be moved into the session scratchpad.
- `bats` and `parallel` were installed on gus with pacman earlier.

## Publishing

`forgejo` = `ssh://for-nixfred/nixfred/vm2lxc.proxmox.git` (verified private on the server), `nas` = `ssh://pi@10.0.0.9/srv/git/vm2lxc.proxmox.git`
(both Fred's standing default for new projects), `origin` = `https://github.com/nixfred/vm2lxc.git` (**private**).

## Next

Guest-internal checks (the first brings a chroot-safe path resolver), a real ZFS run, XFS/btrfs guests, then `convert`.

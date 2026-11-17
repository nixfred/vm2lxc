# vm2lxc status: slice 1 (scaffold, read-only preflight and scan, fixture tests)

Written 2026-11-16 by Larry:gus. Slice 1 of `docs/KICKOFF.md` is done. Stopped, waiting for Fred / VM2LXC Bot.

**No Proxmox host, hex, or any PVE server was contacted. Nothing was pushed. No GitHub repo was created.**
Local git repo on branch `main`, no remote configured. Commits: `365da92` scaffold, `e4c9a93` host seam / parser /
checks / sizing, `8d141e9` preflight + scan + fixtures + read-only guard tests (plus the commit adding this file).

## TL;DR

- `vm2lxc preflight <vmid>` and `vm2lxc scan` work, **against fixtures only**. They have never read a real host.
- 148 bats tests pass, 0 skipped, shellcheck clean. The read-only promise is proved three independent ways (below).
- The biggest risk is not in the code, it is in my assumptions about real Proxmox output formats. See
  "Not verified against a real host". Best next step is a read-only run on the test VMs through Proxmox Expert.

## What is implemented

| Piece | Where | Notes |
|---|---|---|
| Entry script, subcommands, flags | `vm2lxc` | `preflight`, `scan`, `convert`, `undo`, `cleanup`; `--yes --answers FILE --dry-run --no-tui --node NAME --help --version`, accepted before or after the subcommand |
| Exit codes | `lib/common.sh` | preflight: 0 green, 10 yellow, 20 red. 64 usage, 66 VM not found, 69 environment (not root / not PVE / tool missing / bad fixture), 70 not implemented |
| The only host seam | `lib/pve.sh` | reads only: `qm config`, `pvesh get`, `pvesm status`, `pveversion`, `hostname -s`. Has a fixture mode |
| `qm config` parser, disk plan, NIC view | `lib/qmconf.sh` | stops at the first `[section]`; boot disk becomes rootfs, other data disks become mp0, mp1 (D6); cdrom, EFI, TPM, unused, raw host device recognised |
| Storage policy | `lib/storage.sh` | D1: only `zfspool` and `lvmthin`; everything else "not supported yet" with a plain reason |
| Findings / verdict engine | `lib/findings.sh` | levels red, yellow, info, pending; kinds vm, tool ("v1 limit"), guest; worst level wins; pending and info never change the verdict; a typo in a level or kind dies loudly |
| Config-level checks | `lib/checks_cfg.sh` | PVE 8/9, template, lock, ostype, appliance hints, hostpci, usb, virtiofs, args, hookscript, TPM, EFI, disks (missing/inactive/unsupported storage, raw device, none, multi-disk, boot guess) |
| Guest-check plug-in interface | `lib/checks_guest.sh` | 12 registered checks, all report `pending: needs disk inspection (not yet)`. Contract: `guest_check_<id>(guest_root)` emits findings via `finding`; the runner calls it only when a guest root is set |
| Sizing from RRD history (D8) | `lib/sizing.sh` | timeframe month/week/day, nearest-rank p95 and max, confidence label, memory and CPU choices, under 24h keeps the current size |
| `preflight` | `lib/preflight.sh` | verdict banner, findings, disk plan, NICs, sizing, pending guest checks |
| `scan` | `lib/scan.sh` | ranks by verdict, then RAM saved, then vmid; one-line why; totals; honesty footer |
| Tests, fixtures, stubs | `tests/` | 148 tests, 12-VM fixture host `tests/fixtures/pve8`, PVE CLI stubs `tests/stubs/pvestub.sh` |

The verdict is **provisional** by design. A GREEN today means "nothing in the VM config blocks it", not "go ahead",
and the output says so while any guest check is pending.

## What is stubbed or not built

- `convert`, `undo`, `cleanup`: validate their arguments, print "not implemented", exit 70, make **zero** host calls (tested).
- All 12 guest-internal checks (os-release, docker, kernel-modules, nfs-server, cloud-init, snap, fstab-netmounts,
  tailscale, uid-range, disk-layers, iscsi-multipath, nested-virt): pending only. They need the read-only snapshot mount.
- `--yes`, `--answers`, `--no-tui`, `--dry-run`: parsed and accepted, no consumer yet (preflight and scan are always read-only).
- Not started: snapshot mount (D1), whiptail TUI (D7), vzdump verify and test restore (D9), soak (D10), post-conversion
  compare, run log, lock file and run report (D12), Tailscale handoff (D3), journal and undo.
- Disk savings are **not estimated**. There is no read-only source for used bytes without looking inside the guest or
  at ZFS/thin-pool usage. `scan` shows allocated disk size and says so in the footer.

## How to run

```
make lint     # shellcheck -x on vm2lxc, lib/*.sh, tests/stubs/*.sh
make test     # bats --recursive tests   (serial; I did not time it, it is slow on this NFS-backed dir)
              # bats --jobs 4 --recursive tests   took 160 s here (needs GNU parallel)

# try it on any Linux box, no Proxmox needed. Output is labelled FIXTURE MODE.
VM2LXC_FIXTURE_DIR=$PWD/tests/fixtures/pve8 ./vm2lxc scan
VM2LXC_FIXTURE_DIR=$PWD/tests/fixtures/pve8 ./vm2lxc preflight 101
```

Needs bash 4.4+, jq, shellcheck, bats. On this host `bats` 1.14.0 was missing, so I installed it with
`pacman -S bats` (it pulled in `parallel`). That is the only change I made outside this folder, apart from moving
my own scratch litter out of `/tmp` (below).

## Test output summary

Final run, 2026-11-16: `bats --jobs 4 --recursive tests` gave **148 ok, 0 not ok, 0 skipped**, exit 0, 160 s. `make lint` clean.

| File | Tests | What it proves |
|---|---|---|
| `tests/cli.bats` | 10 | flags anywhere, exit codes, argument validation incl. injection strings, stubs exit 70 |
| `tests/qmconf.bats` | 15 | parser edge cases, numeric key sort, sizes, disk plan (boot order, legacy bootdisk, guess), NICs |
| `tests/storage.bats` | 4 | `pvesm status` parsing, the v1 storage policy |
| `tests/checks.bats` | 28 | every config check at every level, word-boundary appliance matching, verdict engine, guest plug-in contract |
| `tests/sizing.bats` | 36 | jq stats, timeframe choice, confidence boundaries to the minute, exact choices with clamps and floors |
| `tests/preflight.bats` | 25 | end to end per fixture VM, errors, PVE 7/9, node override |
| `tests/scan.bats` | 15 | exact ranking, exact RAM numbers, totals, unreadable VM, template via list, broken list |
| `tests/readonly_guard.bats` | 15 | the read-only proof |

### Why I trust the tests (they are not "binary exists")

1. **Independent cross-check.** The jq stats program was compared with a separate Python implementation on 300 randomised
   trials (random step, gaps, explicit nulls, shuffled rows): samples, step, span, p95 and max all agreed. The expected
   RAM/CPU numbers in the CLI tests (e.g. VM 101: lean 3456M, recommended 3712M, saves 4480M) come from a Python
   calculation written separately from the bash, not copied from the tool's output.
2. **Mutation testing**, in a scratch copy so the working tree was never touched. I injected deliberate bugs and checked a
   test failed: 16 logic mutants in parser/checks/engine (all caught), 15 in sizing (13 caught first time; the 2
   survivors exposed real gaps, so I added tests and re-ran: caught), 17 mutating-call mutants against the read-only guard
   (one survivor, `ssh` inside `{ ...; }`, exposed a hole in my static regex; fixed and re-run: caught).
3. **I read my own output before encoding it in tests** and fixed three real defects that way (CPU "recommended" below
   "lean"; cdrom size shown as `?`; scan "why" not saying why sizing was weak).

### The read-only proof, three independent layers

1. **Static**: the source never has a mutating `qm/pvesh/pvesm` verb, never mentions `pct`, never runs a mutating or
   out-of-scope tool in command position (also after `{ then else do`), no `sed -i`.
2. **Dynamic, stub binaries**: the tool runs in live mode against stub `qm`, `pvesh`, `pvesm`, `pveversion` that log every
   call, serve the fixtures, and refuse any call that is not an exact read. Stub `pct zfs mount rsync tar dd rm ssh curl sudo ...`
   are on PATH and must never be called. Tests assert the **exact call sequence** for `preflight 100`, that `scan` skips
   sizing for red VMs, that `convert/undo/cleanup/--help/usage errors` make zero host calls, and that live-mode output equals
   fixture-mode output. The tripwire itself is tested (a `qm set` through the stubs exits 99 and is logged).
3. **strace**: the tool and every child process, over `scan` and three `preflight` runs: no file is created, written,
   renamed, removed or chmod'd. The only write-ish syscalls are `/dev/null` and bash's own failed `/dev/tty` probe.
   (Skipped automatically where strace/ptrace is unavailable; it ran here.)

## Not verified against a real host (my assumptions, please check on a real PVE)

These are the things fixtures cannot prove. A read-only run through Proxmox Expert on the test VMs would settle them:

1. **`qm config` format**: I assume `key: value` lines, `size=32G` with a unit suffix, `memory:` a plain number (or
   `current=N`), and that snapshot/pending content appears only under a `[section]` header (I stop at the first one).
2. **`pvesh get /nodes/<n>/qemu/<id>/rrddata --timeframe T --output-format json`**: assumed rows with `time`, `cpu`, `maxcpu`,
   `mem`, `maxmem`; `mem` in bytes; `cpu` as a fraction of all vCPUs (so cores used = cpu x maxcpu); missing values absent or null.
   RRD resolution differs between PVE 8 and 9, so the code derives the step from the data and hardcodes none.
3. **What `mem` means for a VM without balloon driver or guest agent.** My "pinned near max, do not trust the saving"
   heuristic is a guess at that behaviour, not something I confirmed.
4. **`pvesm status`** columns (`Name Type Status ...`) and the type names `zfspool` and `lvmthin`.
5. **`pveversion`** first line `pve-manager/8.2.4/... (running kernel ...)`.
6. **Node name = `hostname -s`** (used in the API path; validated against `^[A-Za-z0-9-]+$`).
7. **`jq` on the PVE host.** I do not know whether a stock PVE install has jq. I kept to jq 1.6 features (PVE 8 ships 1.6)
   but only ever ran 1.8.2 here. `preflight` fails with exit 69 and a clear message if jq is missing.
8. Debian's default `awk` is mawk, not the gawk I tested with. I only use basic `awk -v` and `printf`, but it is unconfirmed.

## Decisions I made that you may want to change

- **Exit codes**: 0/10/20 for verdicts, sysexits-style for errors. Easy to change, but scripts will depend on them.
- **Verdict mapping**: unsupported storage is RED but tagged `(v1 limit)` so it is not mistaken for a fault of the VM.
  `ostype: other` is YELLOW (not RED). USB passthrough, virtiofs, custom `args`, hookscript, TPM are YELLOW. An appliance
  hint in name/tags is RED only when ostype is not Linux, otherwise YELLOW. Template and locked VM are RED.
- **Sizing constants** (my reading of D8, which only fixed "use history, label confidence, under 24h keep size"):
  lean = p95 x 1.15; recommended = max(p95 x 1.25, max x 1.10); 64M rounding; floors 128M / 256M; never above current;
  confidence none / insufficient (<24h) / low (<7d) / medium (<21d) / high; one step down if under 50% of expected samples;
  capped at low when p95 is within 10% of RAM. CPU: lean = p95 cores x 1.5, recommended = max x 1.25 but never below lean.
  Timeframe choice: longest history wins, a near tie goes to the finer timeframe.
- **The 12 guest check ids** come from the BRIEF's G3 list and D5 (Docker refused in v1), grouped by me.
- **Two environment hooks ship in the real script**: `VM2LXC_FIXTURE_DIR` (fixture mode, loudly labelled in the output) and
  `VM2LXC_ASSUME_ROOT=1` (skips the root check, for the stub tests). Both are test seams. The tool is read-only either way.

## Open questions for Fred

1. **Confirm the start.** `docs/BRIEF.md` line 158 still says "Larry NOT started (Fred: 'No larry yet')". The kickoff and the
   relay said Fred approved, so I proceeded. Please confirm, and update or remove that line.
2. **jq as a runtime dependency on PVE hosts, or move the stats into one small Python file?** Ask Proxmox Expert for `which jq` on hex.
3. **LICENSE credits.** I put the ArMaTeC / thushan credit block under the MIT text in `LICENSE` as asked. GitHub's license
   detector may then not recognise it as plain MIT. Alternative: keep `LICENSE` pure and move the credits to `CREDITS.md`
   (README already credits them). Also confirm the copyright line "Fred Nix".
4. **Should a v1 storage limit be RED** or a separate label (for example "NOT YET") in `scan`, so the ranking separates
   "VM cannot be converted" from "vm2lxc cannot do it yet"? Today it is RED with a `(v1 limit)` tag.
5. **Should templates appear in `scan` at all?** Today they are listed as RED.
6. **Disk savings**: want a read-only estimate from `zfs get used` / thin-pool `data_percent` in a later slice, or leave it to
   disk inspection?
7. **Scrub before any public push.** `docs/BRIEF.md` and `docs/KICKOFF.md` name real VM IDs on hex (110, 111, 120, 121, 301,
   351, and the 600-603 test VMs). Fine for a local repo; Fred should decide before anything is published.
8. Sizing constants and verdict mapping above: OK as picked, or tune?

## Housekeeping

- `bats` (+ `parallel`) installed with pacman on gus. Nothing else outside `/home/pi/nas/Projects/vm2lxc.proxmox`.
- My mutation experiments deliberately wrote files into `/tmp` so strace would catch them. I moved those 51 files into the
  session scratchpad (moved, not deleted). The shipped code has no `/tmp`, `mktemp` or `TMPDIR` reference at all.
- `docs/BRIEF.md` and `docs/KICKOFF.md` are committed unchanged in the first commit as the design record.
- The test-VM rule from the brief is respected: fixture VM ids avoid 110, 111, 120, 121, 301, 351 and 600-603.

## Suggested next slice (not started)

1. Read-only validation on a real node: `vm2lxc scan` and `preflight` on the test VMs 600-603 through Proxmox Expert, to settle
   the assumptions above. Add real captured output as new fixtures.
2. The read-only snapshot mount layer (D1: ZFS clone / LVM-thin snapshot, mounted `ro,noload`) with a bit-identical checksum
   proof of the source volume, so the guest checks can start running.

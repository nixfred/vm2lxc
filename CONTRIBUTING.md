# Contributing

Thanks for looking. A few ground rules, because this tool runs as root on a hypervisor.

## The one rule

**Anything that changes the host goes through `host_cmd` in `lib/hostexec.sh`**, as an exact argument shape on
the allowlist, with a test that proves the near-misses are refused. `tests/readonly_guard.bats` enforces that no
other file runs a mutating command. If you need a new command, add its validator and its refusals first.

## Working on it

```bash
make lint      # shellcheck -x on everything
make test      # bats --recursive tests   (bats --jobs 4 --recursive tests is faster, needs GNU parallel)
```

No Proxmox host is needed: the tests run the real code against canned data and a stateful fake of `zfs`, LVM,
`losetup`, `mount`, `qm` and `pct` (`tests/stubs/fakehost.sh`).

## What a good change looks like

- **A failing test first**, then the fix. Add a mutation check for anything safety-relevant: revert the fix and
  confirm a test goes red. A test that passes the first time proves nothing yet.
- **A fake that mirrors your assumption proves nothing.** Build fake output from what the real tool prints.
  Real-host runs found three bugs the fakes could not (see the README); if you have a different distro or storage,
  your run is valuable.
- Plain bash 4.4+ and `jq`. No new runtime dependencies, no network access, no AI in the tool.
- Match the existing style (`shellcheck -x` clean). Explain *why* in comments; the *what* is in the code.

## Reporting a bug

Open an issue with the output of `./vm2lxc preflight <vmid>` (and `qm config <vmid>` with anything private
removed), your PVE version and storage type. If something was left behind, include `./vm2lxc cleanup` output.
For anything security-relevant, see `SECURITY.md` instead.

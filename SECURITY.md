# Security policy

vm2lxc runs as root on a hypervisor and its whole promise is that it **never modifies a VM's disks** and
**only removes what it created**. A report that breaks either promise is a security issue.

## What to report privately

Please report any way to make vm2lxc:

- write to, or destroy, a source volume or any object it did not create;
- run a command that is not on its allowlist (`host_cmd` in `lib/hostexec.sh`);
- follow a symlink or path from a guest onto the host (read, write, or copy a host file into a guest);
- execute code from a guest, a journal file or an environment variable;
- leave a VM stopped, or a second copy of a machine running, after a failure.

Contact the maintainer directly (do not open a public issue). Include the command you ran, the output, your
Proxmox VE version and storage type, and, if you can, the smallest guest tree or journal that reproduces it.
**Never include credentials.**

## What is already covered

The design and the failure matrix are in `docs/snapshot-layer.html` and `docs/convert.html`. The safety rails
are enforced by one allowlist and are mutation-tested: each rail has a test that fails when the rail is
removed.

## Supported versions

Alpha software, `main` only. Verified on Proxmox VE 9.2 with LVM-thin storage; see the README for exactly what
has and has not been run on real hardware.

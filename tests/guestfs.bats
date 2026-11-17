#!/usr/bin/env bats
# The guest filesystem reader. The guest is untrusted: these tests are hostile on purpose.

bats_require_minimum_version 1.5.0
load helpers

setup() {
  load_libs common guestfs
  G="$BATS_TEST_TMPDIR/g"
  mkdir -p "$G"
}

gput() { # gput <guest-path> <content>
  mkdir -p "$G/$(dirname "$1")"
  printf '%s' "$2" >"$G/$1"
}

@test "resolve: an ordinary path maps under the root" {
  gput etc/hostname "web1"
  gfs_resolve "$G" /etc/hostname
  [ "$GFS_PATH" = "$G/etc/hostname" ]
  gfs_is_file "$G" /etc/hostname
  [ "$(gfs_cat "$G" /etc/hostname)" = web1 ]
}

@test "resolve: an ABSOLUTE symlink is re-rooted under the guest, never followed onto the host" {
  ln -s /etc "$G/etc" # the guest says: my /etc is the host's /etc
  [ -e /etc/hostname ] || [ -e /etc/passwd ] # the host really has such files
  must_fail gfs_is_file "$G" /etc/passwd
  must_fail gfs_exists "$G" /etc/passwd
  # re-rooted, it points at $G/etc, which is the symlink itself: a loop, reported, not followed
  run gfs_resolve "$G" /etc/passwd
  [ "$status" -eq 2 ]
}

@test "resolve: an absolute symlink to a directory the guest really has works (the normal case)" {
  gput usr/share/real/passwd "root:x:0:0"
  ln -s /usr/share/real "$G/etc"
  [ "$(gfs_cat "$G" /etc/passwd)" = "root:x:0:0" ]
  gfs_resolve "$G" /etc/passwd
  [ "$GFS_PATH" = "$G/usr/share/real/passwd" ]
}

@test "resolve: an absolute symlink NESTED below the root restarts from the guest root, not from where it sits" {
  gput etc/x "guest-etc-x"
  mkdir -p "$G/a/b"
  ln -s /etc "$G/a/b/lnk"
  gfs_resolve "$G" /a/b/lnk/x
  [ "$GFS_PATH" = "$G/etc/x" ] # not $G/a/b/etc/x
  [ "$(gfs_cat "$G" /a/b/lnk/x)" = guest-etc-x ]
}

@test "resolve: '..' can never climb above the guest root" {
  gput etc/secret "guest-secret"
  gfs_resolve "$G" /../../../etc/secret
  [ "$GFS_PATH" = "$G/etc/secret" ]
  [ "$(gfs_cat "$G" /../../../etc/secret)" = guest-secret ]
  gfs_resolve "$G" /a/../../../etc/secret
  [ "$GFS_PATH" = "$G/etc/secret" ]
}

@test "resolve: a relative symlink with too many '..' is clamped at the guest root" {
  gput etc/x "inside"
  mkdir -p "$G/a"
  ln -s ../../../../etc "$G/a/up"
  gfs_resolve "$G" /a/up/x
  [ "$GFS_PATH" = "$G/etc/x" ]
  [ "$(gfs_cat "$G" /a/up/x)" = inside ]
}

@test "resolve: a symlink loop is rc 2, and a long chain beyond the hop limit too" {
  ln -s b "$G/a"
  ln -s a "$G/b"
  run gfs_resolve "$G" /a
  [ "$status" -eq 2 ]
  local i
  ln -s end "$G/l0"
  for i in $(seq 1 60); do ln -s "l$((i - 1))" "$G/l$i"; done
  run gfs_resolve "$G" /l60
  [ "$status" -eq 2 ]
}

@test "resolve: a bad root is rc 1, and nothing is written under the root" {
  run gfs_resolve "$BATS_TEST_TMPDIR/does-not-exist" /etc
  [ "$status" -eq 1 ]
  gput etc/a "x"
  local before after
  before=$(find "$G" | sort | md5sum)
  gfs_cat "$G" /etc/a >/dev/null
  gfs_exists "$G" /nope || true
  gfs_dir_nonempty "$G" /etc
  gfs_entries "$G" /etc >/dev/null
  after=$(find "$G" | sort | md5sum)
  [ "$before" = "$after" ]
}

@test "cat: only regular files, never a FIFO (it would block), a device or a directory" {
  mkdir -p "$G/etc"
  mkfifo "$G/etc/fifo"
  run timeout 5 bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/guestfs.sh'; gfs_cat '$G' /etc/fifo"
  [ "$status" -eq 1 ] # rc 1 promptly, not 124 (timeout)
  run gfs_cat "$G" /etc
  [ "$status" -eq 1 ]
  ln -s /dev/null "$G/etc/null" # re-rooted: $G/dev/null does not exist
  run gfs_cat "$G" /etc/null
  [ "$status" -eq 1 ]
}

@test "cat: the size is capped" {
  head -c 5000 /dev/zero | tr '\0' 'a' >"$G/big"
  [ "$(gfs_cat "$G" /big 100 | wc -c)" -eq 100 ]
  [ "$(gfs_cat "$G" /big | wc -c)" -eq 5000 ]
}

@test "dir_nonempty and entries: dotfiles and odd names are listed as data" {
  mkdir -p "$G/d"
  gfs_dir_nonempty "$G" /d && return 1
  : >"$G/d/.hidden"
  : >"$G/d/a b"
  : >"$G/d/..twodots"
  gfs_dir_nonempty "$G" /d
  run gfs_entries "$G" /d
  [[ $output == *".hidden"* && $output == *"a b"* && $output == *"..twodots"* ]]
}

@test "pkg: dpkg 'installed' counts, 'config-files' and 'not-installed' do not; apk works" {
  mkdir -p "$G/var/lib/dpkg" "$G/lib/apk/db"
  cat >"$G/var/lib/dpkg/status" <<'EOT'
Package: nfs-kernel-server
Status: install ok installed
Version: 1

Package: docker-ce
Status: deinstall ok config-files
Version: 2

Package: snapd
Status: install ok not-installed
Version: 3

Package: cloud-init
Version: 4
Status: install ok installed
EOT
  printf 'P:open-iscsi\nV:1\n\nP:tailscale\nV:2\n' >"$G/lib/apk/db/installed"
  gfs_pkg_installed "$G" nfs-kernel-server
  gfs_pkg_installed "$G" cloud-init
  must_fail gfs_pkg_installed "$G" docker-ce
  must_fail gfs_pkg_installed "$G" snapd
  must_fail gfs_pkg_installed "$G" nfs-kernel # a prefix is not a match
  gfs_pkg_installed "$G" open-iscsi
  gfs_pkg_installed "$G" tailscale
  must_fail gfs_pkg_installed "$G" tail
}

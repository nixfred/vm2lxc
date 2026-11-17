# shellcheck shell=bash
# shellcheck disable=SC2034  # GFS_PATH is consumed by callers
# Reading a guest filesystem that is UNTRUSTED.
#
# The guest is mounted read-only under a root on the host, but its contents are chosen by whoever
# controls the VM. An absolute symlink inside it (/etc -> /etc, /var/lib/x -> /root) points at the
# HOST, not at the guest, so a plain `cat "$root/etc/passwd"` or `[[ -f $root/etc/x ]]` can be
# steered into the host's files. Every guest read in vm2lxc goes through this file:
#
#   gfs_resolve <root> <guest-path>   resolve chroot-style: every symlink is re-rooted under <root>,
#                                     '..' never climbs above it; sets GFS_PATH to the HOST path.
#                                     rc 0 resolved (the final entry may still not exist), 1 bad root,
#                                     2 symlink loop or too deep.
#   gfs_exists / gfs_is_file / gfs_is_dir <root> <guest-path>
#   gfs_cat <root> <guest-path> [max-bytes]   regular files only, size capped (a FIFO or device would
#                                             block or stream forever), prints the contents
#   gfs_dir_nonempty <root> <guest-path>
#   gfs_entries <root> <guest-dir>    names inside a directory, one per line (data, never a glob)
#   gfs_pkg_installed <root> <name>   dpkg or apk database says the package is installed
#
# Nothing here writes under the root.

GFS_MAX_HOPS=40
GFS_MAX_BYTES=1048576   # 1 MiB: plenty for any config file
GFS_MAX_DB_BYTES=67108864 # 64 MiB: a big dpkg status file

GFS_PATH=""

gfs_resolve() {
  local root=$1 rest=$2 cur=/ cand comp target hops=0
  GFS_PATH=""
  root=$(realpath -e -- "$root" 2>/dev/null) || return 1
  [[ $rest == /* ]] || rest=/$rest
  while [[ -n $rest ]]; do
    rest=${rest#/}
    while [[ $rest == /* ]]; do rest=${rest#/}; done
    [[ -n $rest ]] || break
    comp=${rest%%/*}
    if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=""; fi
    case $comp in
      "" | .) continue ;;
      ..)
        cur=${cur%/*}
        [[ -n $cur ]] || cur=/
        continue
        ;;
    esac
    if [[ $cur == / ]]; then cand=/$comp; else cand=$cur/$comp; fi
    if [[ -L $root$cand ]]; then
      hops=$((hops + 1))
      ((hops <= GFS_MAX_HOPS)) || return 2
      target=$(readlink -- "$root$cand") || return 1
      # An absolute target is re-rooted: it restarts from the GUEST root, not the host's.
      if [[ $target == /* ]]; then cur=/; fi
      rest=$target/$rest
    else
      cur=$cand
    fi
  done
  if [[ $cur == / ]]; then GFS_PATH=$root; else GFS_PATH=$root$cur; fi
  return 0
}

gfs_exists() { gfs_resolve "$1" "$2" && [[ -e $GFS_PATH ]]; }
gfs_is_file() { gfs_resolve "$1" "$2" && [[ -f $GFS_PATH && ! -L $GFS_PATH ]]; }
gfs_is_dir() { gfs_resolve "$1" "$2" && [[ -d $GFS_PATH && ! -L $GFS_PATH ]]; }

# gfs_cat <root> <guest-path> [max-bytes]: contents of a regular file, capped. rc 1 if it is not one.
gfs_cat() {
  local max=${3:-$GFS_MAX_BYTES}
  gfs_is_file "$1" "$2" || return 1
  head -c "$max" -- "$GFS_PATH"
}

gfs_dir_nonempty() {
  local f
  gfs_is_dir "$1" "$2" || return 1
  for f in "$GFS_PATH"/* "$GFS_PATH"/.[!.]* "$GFS_PATH"/..?*; do
    if [[ -e $f || -L $f ]]; then return 0; fi
  done
  return 1
}

# gfs_entries <root> <guest-dir>: the names inside it, one per line. Names are guest-controlled data:
# use them only as path components handed back to gfs_resolve, never as a pattern or a command.
gfs_entries() {
  local f
  gfs_is_dir "$1" "$2" || return 1
  for f in "$GFS_PATH"/* "$GFS_PATH"/.[!.]* "$GFS_PATH"/..?*; do
    if [[ -e $f || -L $f ]]; then printf '%s\n' "${f##*/}"; fi
  done
}

# gfs_pkg_installed <root> <name>: dpkg (Status: ... installed) or apk (P:name) says it is there.
# <name> is chosen by this tool, never by the guest.
gfs_pkg_installed() {
  local root=$1 pkg=$2
  if gfs_is_file "$root" /var/lib/dpkg/status; then
    gfs_cat "$root" /var/lib/dpkg/status "$GFS_MAX_DB_BYTES" |
      awk -v p="$pkg" 'BEGIN { RS = ""; FS = "\n" }
        $1 == "Package: " p { for (i = 2; i <= NF; i++) if ($i ~ /^Status: .* installed$/ && $i !~ /not-installed|config-files/) f = 1 }
        END { exit !f }' && return 0
  fi
  if gfs_is_file "$root" /lib/apk/db/installed; then
    gfs_cat "$root" /lib/apk/db/installed "$GFS_MAX_DB_BYTES" | grep -qx "P:$pkg" && return 0
  fi
  return 1
}

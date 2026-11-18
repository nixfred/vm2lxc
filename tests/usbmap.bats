#!/usr/bin/env bats
# USB passthrough (rail R39): usb_parse_spec, the sysfs inventory, usb_find and usb_resolve, against the
# fixture host's usb-devices.txt:
#   1-2 0bda:8153 bus 1 dev 4, driver bound, no serial port      1-3 10c4:ea60 bus 1 dev 5, serial port ttyUSB0
#   1-4 0403:6001 bus 1 dev 6, NO driver bound                   1-5 1a86:55d4 bus 1 dev 7, serial port ttyACM0
#   2-1 and 2-2: two identical 303a:1001 devices (bus 2 dev 3 and dev 4)

bats_require_minimum_version 1.5.0
load helpers

setup() {
  load_libs common pve qmconf usbmap
  export VM2LXC_FIXTURE_DIR="$FIXTURES/pve8"
}

kind_of() { usb_parse_spec "$1"; printf '%s|%s|%s|%s|%s' "$USB_KIND" "$USB_VID" "$USB_PID" "$USB_PORT" "$USB_MAP"; }

@test "usb_parse_spec: every form Proxmox writes, and the ones it does not" {
  [ "$(kind_of 'host=0bda:8153')" = 'vidpid|0bda|8153||' ]
  [ "$(kind_of 'host=0BDA:8153,usb3=1')" = 'vidpid|0bda|8153||' ]
  [ "$(kind_of '0bda:8153')" = 'vidpid|0bda|8153||' ]
  [ "$(kind_of 'usb3=1,host=0bda:8153')" = 'vidpid|0bda|8153||' ]
  [ "$(kind_of 'host=1-2')" = 'port|||1-2|' ]
  [ "$(kind_of 'host=1-2.3.4,usb3=1')" = 'port|||1-2.3.4|' ]
  [ "$(kind_of 'host=spice')" = 'spice||||' ]
  [ "$(kind_of 'spice')" = 'spice||||' ]
  [ "$(kind_of 'mapping=zigbee-stick')" = 'mapping||||zigbee-stick' ]
  [ "$(kind_of 'mapping=a b')" = 'unknown||||a b' ]
  [ "$(kind_of 'host=zzzz:8153')" = 'unknown||||' ]
  [ "$(kind_of 'host=0bda:8153;id')" = 'unknown||||' ]
  [ "$(kind_of 'host=1-2/../x')" = 'unknown||||' ]
  [ "$(kind_of '')" = 'unknown||||' ]
}

@test "usb_find: one match by vendor:product, one by port; the sysfs number is read as decimal (leading zeros are not octal)" {
  usb_find 'host=0bda:8153'
  [ "$USB_SYS" = 1-2 ] && [ "$USB_BUS" = 1 ] && [ "$USB_DEV" = 4 ] && [ "$USB_BOUND" = 1 ] && [ "$USB_FOUND_N" = 1 ]
  usb_find 'host=1-5'
  [ "$USB_SYS" = 1-5 ] && [ "$USB_DEV" = 7 ]
  local fx="$BATS_TEST_TMPDIR/fx"
  mkdir "$fx" && printf 'dev 1-9 aaaa bbbb 008 009 1\n' >"$fx/usb-devices.txt"
  VM2LXC_FIXTURE_DIR=$fx usb_find 'host=aaaa:bbbb'
  [ "$USB_BUS" = 8 ] && [ "$USB_DEV" = 9 ]
}

@test "usb_find: nothing plugged in is a clear 'no', not an error and not a guess" {
  must_fail usb_find 'host=dead:beef'
  [[ $USB_NOTE == *"no USB device matching dead:beef is plugged into the host"* ]]
  must_fail usb_find 'host=7-7'
  [[ $USB_NOTE == *"port 7-7"* ]]
  [ "$USB_FOUND_N" = 0 ]
}

@test "usb_find: two identical devices are AMBIGUOUS, nothing is chosen, and the note says how to pick" {
  must_fail usb_find 'host=303a:1001'
  [ "$USB_FOUND_N" = 2 ]
  [ -z "$USB_SYS" ] && [ -z "$USB_BUS" ] && [ -z "$USB_DEV" ]
  [[ $USB_NOTE == *"2 devices on the host match 303a:1001"* && $USB_NOTE == *"host=BUS-PORT"* ]]
  usb_find 'host=2-2' # naming the port picks exactly one
  [ "$USB_SYS" = 2-2 ] && [ "$USB_DEV" = 4 ]
}

@test "usb_find: spice, a cluster mapping and nonsense are not physical devices vm2lxc can resolve" {
  must_fail usb_find 'host=spice'
  [[ $USB_NOTE == *"SPICE"* ]]
  must_fail usb_find 'mapping=zigbee'
  [[ $USB_NOTE == *"cluster resource mapping (mapping=zigbee)"* ]]
  must_fail usb_find 'host=banana'
  [[ $USB_NOTE == *"not one vm2lxc understands"* ]]
}

@test "usb_find: an unreadable host inventory is reported, not treated as 'no device'" {
  local fx="$BATS_TEST_TMPDIR/empty"
  mkdir "$fx"
  VM2LXC_FIXTURE_DIR=$fx run usb_find 'host=0bda:8153'
  [ "$status" -eq 1 ]
  VM2LXC_FIXTURE_DIR=$fx usb_find 'host=0bda:8153' || true
  [[ $USB_NOTE == *"could not be read"* ]]
}

@test "usb_resolve: a plain device maps its raw node, zero-padded to three digits" {
  usb_resolve 'host=0bda:8153'
  [ "${#USB_NODES[@]}" = 1 ]
  [ "${USB_NODES[0]}" = /dev/bus/usb/001/004 ]
  [[ $USB_NOTE == *"port 1-2, bus 1 device 4, mapped as /dev/bus/usb/001/004"* ]]
  [[ $USB_NOTE != *"no driver"* ]]
}

@test "usb_resolve: a serial stick maps the raw node AND its port, ttyUSB and ttyACM alike" {
  usb_resolve 'host=10c4:ea60'
  [ "${USB_NODES[*]}" = "/dev/bus/usb/001/005 /dev/ttyUSB0" ]
  [[ $USB_NOTE == *"and the serial port ttyUSB0"* ]]
  usb_resolve 'host=1a86:55d4'
  [ "${USB_NODES[*]}" = "/dev/bus/usb/001/007 /dev/ttyACM0" ]
}

@test "usb_resolve: a port belongs to its OWN device (the tty of 1-3 is never given to 1-5)" {
  usb_resolve 'host=1-5'
  [[ ${USB_NODES[*]} != *ttyUSB0* ]]
  usb_resolve 'host=1-2'
  [ "${#USB_NODES[@]}" = 1 ]
}

@test "usb_resolve: a device with no host driver still maps its raw node, and says there is no serial port" {
  usb_resolve 'host=0403:6001'
  [ "${USB_NODES[*]}" = "/dev/bus/usb/001/006" ]
  [[ $USB_NOTE == *"no driver bound"* && $USB_NOTE == *"only the raw node"* ]]
}

@test "usb_resolve: every failure leaves USB_NODES EMPTY (a stale list from the last call must not leak)" {
  usb_resolve 'host=10c4:ea60'
  [ "${#USB_NODES[@]}" = 2 ]
  must_fail usb_resolve 'host=303a:1001'
  [ "${#USB_NODES[@]}" = 0 ]
  usb_resolve 'host=10c4:ea60'
  must_fail usb_resolve 'host=dead:beef'
  [ "${#USB_NODES[@]}" = 0 ]
  usb_resolve 'host=10c4:ea60'
  must_fail usb_resolve 'mapping=x'
  [ "${#USB_NODES[@]}" = 0 ]
}

@test "usb_resolve: a tty name that does not look like ttyUSBn/ttyACMn is ignored (the allowlist would refuse it anyway)" {
  local fx="$BATS_TEST_TMPDIR/fx"
  mkdir "$fx"
  printf 'dev 1-2 0bda 8153 1 4 1\ntty 1-2 sda\ntty 1-2 ttyS0\ntty 1-2 ../../sda\ntty 1-2 ttyUSB7\n' >"$fx/usb-devices.txt"
  VM2LXC_FIXTURE_DIR=$fx usb_resolve 'host=0bda:8153'
  [ "${USB_NODES[*]}" = "/dev/bus/usb/001/004 /dev/ttyUSB7" ]
}

@test "usb_resolve: inventory lines with bad fields are skipped, never turned into a node" {
  local fx="$BATS_TEST_TMPDIR/fx"
  mkdir "$fx"
  printf 'dev 1-2 0bda 8153 ../.. 4 1\ndev 1-2 0bda 8153 1 4x 1\ndev 1-2;id 0bda 8153 1 4 1\n' >"$fx/usb-devices.txt"
  VM2LXC_FIXTURE_DIR=$fx must_fail usb_resolve 'host=0bda:8153'
  [ "${#USB_NODES[@]}" = 0 ]
}

@test "pve_usb_inventory (live sysfs): prints only well-formed lines and skips interfaces and root hubs" {
  unset VM2LXC_FIXTURE_DIR
  run pve_usb_inventory
  [ "$status" -eq 0 ]
  local l
  while IFS= read -r l; do
    [[ -z $l ]] && continue
    [[ $l =~ ^dev\ [0-9]{1,3}-[0-9]{1,3}(\.[0-9]{1,3})*\ [0-9a-f]{4}\ [0-9a-f]{4}\ [0-9]{1,3}\ [0-9]{1,3}\ [01]$ ||
      $l =~ ^tty\ [0-9]{1,3}-[0-9]{1,3}(\.[0-9]{1,3})*\ tty(USB|ACM)[0-9]+$ ]] || { echo "bad line: $l"; return 1; }
  done <<<"$output"
}

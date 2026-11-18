# shellcheck shell=bash
# shellcheck disable=SC2034  # globals set here (USB_*) are consumed by convert.sh
# USB passthrough: from the VM's usbN setting to the device nodes the container is given. Rail R39,
# docs/convert.html. This file only READS (pve_usb_inventory, sysfs); the container is created by
# convert.sh through host_cmd, whose allowlist accepts exactly two shapes of --devN value.
#
# What the VM had is "the whole device" (QEMU hands the device over). A container shares the host kernel,
# so the nearest thing is its device nodes:
#   /dev/bus/usb/BBB/DDD   the raw node, for libusb programs (always exists while the device is enumerated)
#   /dev/ttyUSBn, ttyACMn  the serial port, when the HOST driver makes one (Zigbee/Z-Wave sticks, adapters)
# Both appear inside the container owned by its root with mode 0660 (Proxmox's default for a dev entry).
#
# It maps NOTHING it is not sure about: no device, two identical devices, a cluster resource mapping or a
# setting it does not understand all end in "not mapped" with the reason, never in a guess.

USB_NODES=() USB_NOTE="" USB_SYS="" USB_BUS="" USB_DEV="" USB_BOUND=0 USB_FOUND_N=0

# usb_find <usbN value>: look the device up in the host inventory.
#   sets USB_FOUND_N (how many devices match), and for exactly one: USB_SYS USB_BUS USB_DEV USB_BOUND
#   rc 0 when exactly one device matches, 1 otherwise (USB_NOTE says why, in words)
usb_find() {
  local inv line kind sys vid pid bus dev bound
  USB_FOUND_N=0 USB_SYS="" USB_BUS="" USB_DEV="" USB_BOUND=0 USB_NOTE=""
  usb_parse_spec "$1"
  case $USB_KIND in
    vidpid | port) ;;
    spice)
      USB_NOTE="SPICE USB redirection is not a physical device, nothing to map"
      return 1
      ;;
    mapping)
      USB_NOTE="it is a cluster resource mapping (mapping=$USB_MAP), which vm2lxc does not resolve"
      return 1
      ;;
    *)
      USB_NOTE="the setting is not one vm2lxc understands"
      return 1
      ;;
  esac
  inv=$(pve_usb_inventory) || {
    USB_NOTE="the host's USB devices could not be read"
    return 1
  }
  while read -r kind sys vid pid bus dev bound; do
    [[ $kind == dev ]] || continue
    [[ $sys =~ ^[0-9]{1,3}-[0-9]{1,3}(\.[0-9]{1,3})*$ && $vid =~ ^[0-9a-f]{4}$ && $pid =~ ^[0-9a-f]{4}$ &&
      $bus =~ ^[0-9]{1,3}$ && $dev =~ ^[0-9]{1,3}$ && $bound =~ ^[01]$ ]] || continue
    if [[ $USB_KIND == vidpid && $vid == "$USB_VID" && $pid == "$USB_PID" ]] ||
      [[ $USB_KIND == port && $sys == "$USB_PORT" ]]; then
      USB_FOUND_N=$((USB_FOUND_N + 1))
      USB_SYS=$sys USB_BUS=$((10#$bus)) USB_DEV=$((10#$dev)) USB_BOUND=$bound
    fi
  done <<<"$inv"
  if ((USB_FOUND_N == 0)); then
    USB_NOTE="no USB device matching ${USB_VID:+$USB_VID:$USB_PID}${USB_PORT:+port $USB_PORT} is plugged into the host"
    return 1
  fi
  if ((USB_FOUND_N > 1)); then
    USB_NOTE="$USB_FOUND_N devices on the host match $USB_VID:$USB_PID (identical vendor and product), so vm2lxc cannot tell which one the VM used: give the VM host=BUS-PORT (for example host=1-2) to say which"
    USB_SYS="" USB_BUS="" USB_DEV=""
    return 1
  fi
  return 0
}

# usb_resolve <usbN value>: the device nodes to give the container.
#   rc 0: USB_NODES holds the node paths, USB_NOTE says what was found.   rc 1: USB_NODES is empty, USB_NOTE says why.
# Call it AFTER the VM has stopped: while QEMU holds the device the host driver is detached and there is no
# serial port to find. A device with no host driver yet is looked up again for a moment (the driver re-binds
# when QEMU lets go); the raw node is mapped either way.
usb_resolve() {
  local tries=${VM2LXC_USB_TRIES:-5} t=1 inv kind sys name node ttys=""
  USB_NODES=()
  usb_find "$1" || return 1
  while ((!USB_BOUND && t < tries)) && ! pve_fixture_mode; do
    sleep 0.4
    t=$((t + 1))
    usb_find "$1" || return 1
  done
  node=$(printf '/dev/bus/usb/%03d/%03d' "$USB_BUS" "$USB_DEV")
  if ! pve_fixture_mode && [[ ! -c $node ]]; then
    USB_NOTE="the device is enumerated (port $USB_SYS) but $node does not exist"
    return 1
  fi
  USB_NODES+=("$node")
  inv=$(pve_usb_inventory) || inv=""
  while read -r kind sys name; do
    [[ $kind == tty && $sys == "$USB_SYS" && $name =~ ^tty(USB|ACM)[0-9]{1,3}$ ]] || continue
    if ! pve_fixture_mode && [[ ! -c /dev/$name ]]; then continue; fi
    USB_NODES+=("/dev/$name")
    ttys+=" $name"
  done <<<"$inv"
  USB_NOTE="port $USB_SYS, bus $USB_BUS device $USB_DEV, mapped as $node"
  if [[ -n $ttys ]]; then
    USB_NOTE+=" and the serial port${ttys}"
  elif ((!USB_BOUND)); then
    USB_NOTE+=" (the host has no driver bound to it, so there is no serial port; only the raw node is mapped)"
  fi
  return 0
}

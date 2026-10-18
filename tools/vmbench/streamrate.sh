#!/bin/bash
# streamrate: measure a Sunshine video stream's bitrate on the wire.
# Run this on the Linux client. The guest shows a full-screen noisy picture
# (dnoise.app) and Moonlight connects; tcpdump on the guest sums UDP payloads
# from the video port (47998).
# usage: VM_ADDRESS=<guest> [VM_USER=<ssh-user>] [VM_SSH_KEY=<path>] \
#        [VM_TOOLDIR=~/vmbench] [VM_IFACE=en0] \
#        ./streamrate.sh LABEL [BITRATE_KBPS]
#   BITRATE_KBPS is the Moonlight --bitrate setting (default 25000).
#   VM_TOOLDIR is a directory on the guest that contains dnoise.app.
# build: none (the guest app comes from build_all.sh)
# exit: 0 a mean was printed; 2 missing VM_ADDRESS, a bad LABEL, no GNU timeout
#   on this client, or tcpdump produced no full second of video packets
# output: per-second Mbit/s for the middle of the capture (the first and last
#   seconds are partial and are dropped), then mean, min, max, and packet count.
#   Payloads under 600 bytes are left out (control traffic, not a video datagram).
#   A "Streaming bitrate" line from the guest sunshine.log is printed when present.
# permission: SSH to the guest, and passwordless sudo on the guest for tcpdump.
#   Sunshine on the guest needs Screen Recording. This script does not.
# cannot show: frame spacing, loss inside a datagram, or decode time. The Moonlight
#   overlay lines at the end are the client's own log, and only when it wrote them.
#   An empty capture is sudo being refused, or the wrong interface (VM_IFACE).
set -eu
LABEL=${1:?usage: streamrate.sh LABEL [BITRATE_KBPS]}
BR=${2:-25000}
case $LABEL in
  *[!A-Za-z0-9._-]*) echo "LABEL must be letters, digits, dot, dash, or underscore" >&2; exit 2;;
esac
: "${VM_ADDRESS:?set VM_ADDRESS to the guest}"
case $VM_ADDRESS in
  *[!A-Za-z0-9.:-]*) echo "VM_ADDRESS must be a hostname or an address, with no spaces" >&2; exit 2;;
esac
if ! command -v timeout >/dev/null 2>&1; then
  echo "this client has no GNU timeout (macOS does not ship one; run streamrate on Linux)" >&2
  exit 2
fi
target="${VM_USER:+$VM_USER@}$VM_ADDRESS"
iface=${VM_IFACE:-en0}
# Keep the tilde for the guest shell. An unquoted ~/... here would expand on this client.
if [ -n "${VM_TOOLDIR:-}" ]; then tools=$VM_TOOLDIR; else tools='~/vmbench'; fi
B=$(mktemp -d "${TMPDIR:-/tmp}/vmbench-streamrate.XXXXXX")
ssh_base=(ssh)
scp_base=(scp -q)
if [ -n "${VM_SSH_KEY:-}" ]; then ssh_base+=(-i "$VM_SSH_KEY"); scp_base+=(-i "$VM_SSH_KEY"); fi

# dbar is an older full-screen bar from the same investigation; stop it so it cannot cover the noise.
"${ssh_base[@]}" "$target" "pkill -x dnoise || true; pkill -x dbar || true; caffeinate -u -t 3; rm -f /tmp/vmbench-nz.out /tmp/vmbench-nz.err; open -a ${tools}/dnoise.app --stdout /tmp/vmbench-nz.out --stderr /tmp/vmbench-nz.err --args 70 40; sleep 2; cat /tmp/vmbench-nz.out"
(timeout 48 flatpak run com.moonlight_stream.Moonlight stream "$VM_ADDRESS" Desktop --1080 --fps 60 --bitrate "$BR" --video-codec H.264 --display-mode windowed --performance-overlay > "$B/ml_$LABEL.log" 2>&1 &)
sleep 14
# The guest has no GNU timeout. tcpdump -G is what ends the capture.
"${ssh_base[@]}" "$target" "sudo -n tcpdump -i ${iface} -n -G 20 -W 1 -w /tmp/vmbench-rate.pcap \"udp and src host ${VM_ADDRESS} and src port 47998\" 2>&1 | tail -1; sudo -n tcpdump -r /tmp/vmbench-rate.pcap -n -tt -q 2>/dev/null | awk '{print \$1, \$NF}' > /tmp/vmbench-rate.txt; grep -E 'Streaming bitrate' ~/.config/sunshine/sunshine.log | tail -1 | cut -c1-90 || true"
"${scp_base[@]}" "$target:/tmp/vmbench-rate.txt" "$B/rate_$LABEL.txt"
sleep 16
"${ssh_base[@]}" "$target" "pkill -x dnoise || true"
python3 - "$B/rate_$LABEL.txt" "$LABEL" "$BR" <<'PY'
import sys
path, label, br = sys.argv[1:]
rows = []
for line in open(path):
    parts = line.split()
    if len(parts) != 2:
        continue
    try:
        rows.append((float(parts[0]), int(parts[1])))
    except ValueError:
        pass
v = [(t, l) for t, l in rows if l >= 600]
if not v:
    sys.stderr.write("no video-sized packets (tcpdump needs sudo on the guest, and a stream has to be up)\n")
    sys.exit(2)
t0 = v[0][0]
sec = {}
for t, l in v:
    sec[int(t - t0)] = sec.get(int(t - t0), 0) + l * 8
vals = [sec[k] / 1e6 for k in sorted(sec)][1:-1]
if not vals:
    sys.stderr.write("no full second of video packets\n")
    sys.exit(2)
print("%s (client setting %s kbit/s): video on the wire per second, Mbit/s:" % (label, br), " ".join("%.1f" % x for x in vals))
print("   mean %.1f  min %.1f  max %.1f  (%d packets)" % (sum(vals) / len(vals), min(vals), max(vals), len(v)))
PY
grep -E "Average decoding|Incoming frame rate|Frames dropped by your network" "$B/ml_$LABEL.log" | tail -3 | cut -c1-70 || true
wait || true

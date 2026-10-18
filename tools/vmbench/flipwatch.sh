#!/bin/sh
# flipwatch: append the zero-copy flip counters every 10 s for 40 minutes.
# usage: ./flipwatch.sh
# build: none
# exit: 0 when the 40 minutes end
# output: /tmp/flipwatch.log, one line per sample:
#   HH:MM:SS then the sysctl values in this order, space-separated:
#   debug.nvaccel_iop_flip, flips, flip_hit, flip_miss, flip_stale, flip_novram,
#   flip_refused, late, async_drop, nvrmfb_flip_latch_timeouts, flip_latch_max_us,
#   nvaccel_surface_gpu_timeouts, then ws=<WindowServer pid or empty>.
#   A counter that stays 0 means that path did not run during the sample.
# permission: none. These debug sysctls are read without root.
# cannot show: whether a tear was visible on the monitor. Pair it with the moving
#   bar in dgl, watched on the physical display. It also cannot show why a flip
#   was missed; the counters only say which refusal bucket incremented.
# logs the zero-copy flip counters every 10 s for 40 minutes
end=$(( $(date +%s) + 2400 ))
while [ $(date +%s) -lt $end ]; do
  v=$(sysctl -n debug.nvaccel_iop_flip debug.nvaccel_iop_flips debug.nvaccel_iop_flip_hit debug.nvaccel_iop_flip_miss debug.nvaccel_iop_flip_stale debug.nvaccel_iop_flip_novram debug.nvaccel_iop_flip_refused debug.nvaccel_iop_late debug.nvaccel_iop_async_drop debug.nvrmfb_flip_latch_timeouts debug.nvrmfb_flip_latch_max_us debug.nvaccel_surface_gpu_timeouts 2>/dev/null | tr "\n" " ")
  echo "$(date +%T) $v ws=$(pgrep -x WindowServer)" >> /tmp/flipwatch.log
  sleep 10
done

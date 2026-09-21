# Optional NVMe setting used during measurements

The historical throughput measurements used per-controller `pm_qos_latency_tolerance_us=0`, with controller APST disabled by that QoS setting. Engram lookups use local NVMe, so its latency matters. The ordinary launcher leaves the existing setting in place; its default launch alone does not reproduce this measurement condition.

`scripts/nvme_qos_lease.py` is a portable adaptation of the historical helper. Its syntax and source checks passed, but this public wrapper has not itself been run on hardware. It accepts only the measured starting condition: QoS `100000`, APST enabled, and a live APST-capable controller. It saves the device identity and complete original feature readback before changing anything. It does not modify firmware, boot configuration, or module defaults.

Identify the controller containing the Engram files on each node first. Substitute that controller for `nvme0` below. Use a fresh run directory each time:

```bash
DGX_QOS_RUN="local-results/nvme-qos-$(date -u +%Y%m%dT%H%M%SZ)"
sudo install -d -m 0700 "$DGX_QOS_RUN"
sudo python3 scripts/nvme_qos_lease.py snapshot \
  --controller nvme0 --output "$DGX_QOS_RUN/snapshot.json"
sudo python3 scripts/nvme_qos_lease.py hold \
  --snapshot "$DGX_QOS_RUN/snapshot.json" \
  --output "$DGX_QOS_RUN/lease" --seconds 10800 --execute
```

Leave the lease process running and run the benchmark from another terminal. Wait for its `ACTIVE_QOS0` receipt on every node before timing. The lease restores the exact saved setting when its timer expires or it receives Ctrl-C, SIGTERM, or SIGHUP. Allow restoration to finish, then inspect `lease/receipt.json` with `sudo`; successful restoration is recorded as `RESTORED_EXACT`. Keep these receipts local because they contain machine and drive identifiers.

If the process is forcibly killed, its `finally` block cannot restore the setting. On the same boot, use the saved snapshot and a new output filename:

```bash
sudo python3 scripts/nvme_qos_lease.py restore \
  --snapshot "$DGX_QOS_RUN/snapshot.json" \
  --output "$DGX_QOS_RUN/manual-restore.json" --execute
```

Restoration refuses a changed host, boot, controller, firmware, helper source, or unexpected QoS value. Do not bypass those checks or apply a snapshot to another node. No QoS change is required merely to build or launch the model.

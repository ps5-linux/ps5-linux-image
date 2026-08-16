# Local PS5 kernel fixes

These patches are intentionally kept in the image repository instead of being
silently applied in a developer's working tree. `build_image.sh` applies them
after the selected `ps5-linux-patches` ref and records a cache key beside the
packaged kernel. The key includes the external patch ref, its kernel config,
and the local patch hashes, so a cached kernel is reused only when all three
still match. The key is stored as `linux-bin/.kernel-cache-key`.

## `0001-mts-bounded-napi.patch`

The patch hardens the Salina `mts` Ethernet driver's NAPI completion path. A
sticky interrupt cause previously allowed an empty poll to requeue itself
continuously, driving CPU0 softirq load and starving the rest of the system.
The fix:

- respects a false return from `napi_complete_done()`;
- only requeues NAPI when the poll actually processed packets; and
- leaves the driver's watchdog as the bounded recovery path for a lost MSI.

It was validated against the PS5 live module/source collected from the
7.1.7-1 image and the `ps5-linux-patches` `kernel-7.1.7-56922cf` source.
The kernel builder fails closed if the expected driver source or either guard
is missing.

Patch SHA-256: `2cebdd9769b930762a0eaff97c77eb322861ff0981d8d3e08e8a325cc945f35d`

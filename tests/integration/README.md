# Save ingress/export integration tests

This suite covers the two complete 128 KiB save-memory paths that cross both
Pocket clock domains and the production PSRAM controller:

- a patterned cartridge-save import through the shared APF write ingress,
  including interleaved RTC sidecar writes; and
- an all-`FF` no-save clear and a deterministic nonzero save image exported
  through `data_unloader` at Pocket's fixed worst-case cadence of one
  pipelined 32-bit read every 88 bridge clocks.

The export regression does not wait for `bridge_rd_data_valid` before launching
the next host read. This preserves the real `io_bridge_peripheral` contract and
detects a response that misses Pocket's one-word pipeline window.
Short negative cases suppress a PSRAM response entirely and delay one beyond
the 88-clock boundary. The runner requires both simulations to fail with the
explicit fixed-cadence refusal instead of accepting zero or stale data.

Run both full-size regressions with Icarus Verilog and its `vvp` runtime:

```console
python tests/integration/run.py
```

Portable simulator bundles can be selected explicitly:

```console
python tests/integration/run.py --iverilog /path/to/iverilog --vvp /path/to/vvp
```

Before compiling, the runner statically requires both `data_unloader` CDC FIFOs
to use `use_eab = "OFF"`. This locks the known-good logic-FIFO implementation
for the save-export path and prevents an accidental return to the suspect M10K
mapping. The behavioral FIFO model then verifies functionality without needing
Quartus simulation libraries. The three independent full-size simulations run
concurrently to keep CI wall time bounded.

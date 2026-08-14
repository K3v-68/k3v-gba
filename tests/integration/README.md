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
the 88-clock boundary. The direct-pulse testbench must detect both deadline
misses. This is a testbench assertion, not a production refusal mechanism.
The current production bridge does not consume `bridge_rd_data_valid`.

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

## Physical PMP characterization

`tb_pmp_save_export.sv` drives the production `io_bridge_peripheral` pins and
scores what the Pocket side would physically receive. It models the mandatory
initial dummy word, sample-before-request pipeline, and final flush transaction.
The healthy case verifies a patterned save plus RTC data. A one-word fault
case suppresses every cart PSRAM completion and confirms the current unsafe
behavior: the bridge emits one zero payload word while its ignored valid
signal remains low.

```console
python tests/integration/run_pmp.py
```

The full 128 KiB starvation reproduction needs Intel's FIFO model because the
portable behavioral model deliberately stops at the first FIFO overflow:

```console
python tests/integration/run_pmp.py --bytes 131072 --full-starvation \
  --vendor-model /opt/intelFPGA_lite/21.1/quartus/eda/sim_lib/altera_mf.v
```

This characterization deliberately passes when the known all-zero failure is
reproduced. It prevents the failure mechanism from being forgotten; it does
not certify the current RTL as safe.

# Save lifecycle corruption reproduction

This isolated regression models the reported hardware sequence against the
production APF ingress, save unloader, and host-command RTL:

1. Import a complete, nonzero 128 KiB Ruby save over unrelated clocks with
   memory-side backpressure. One address bit is deliberately mutated to model
   an otherwise unspecified import failure.
2. Assert data-slot all-complete before the final CDC words drain, then prove
   finalization rejects the sequence and keeps the GBA reset held.
3. Issue the documented shutdown commands (`0x0010`, then slot-10 `0x0080`).
4. If the command is incorrectly accepted, model the APF's one-word read
   pipeline through all 32,768 declared dwords. With the unloader blocked, all
   128 KiB are the initialized zero word.
5. Import that exported file into a fresh launch and prove its exact size makes
   boot succeed even though every save byte is now zero.

Run the safety regression:

```powershell
python tests/save_lifecycle/run.py --iverilog <path> --vvp <path>
```

The normal run requires a finalized failed import to return result `1` and
proves that no export read starts. To reproduce the historical unsafe behavior
inside the test harness as a diagnostic:

```powershell
python tests/save_lifecycle/run.py --characterize-unsafe --iverilog <path> --vvp <path>
```

The injected address mutation does not claim to identify the original import
fault. It makes the downstream safety requirement deterministic: no failed or
incomplete save may receive a successful nonvolatile request-read response.

## Required request-read contract

The regression also specifies a three-result interface. A boolean `ok` input is
not sufficient:

- `0`: the selected slot is verified, quiescent, and safe to read;
- `1`: a finalized import is invalid, so exporting it is permanently forbidden;
- `2`: finalization or draining is incomplete, so Pocket should check later.

`core_bridge_cmd` should accept a two-bit result input. Its ACK must be driven by
the request level rather than tied high; that one-cycle feedback leaves the
newly latched slot ID and result stable before the command consumes them.

Slot 11 remains independent of a failed cart because unloader readiness is
selected by address: cart readiness for region `0x20`, RTC readiness for region
`0x21`. The contract test verifies that independence through the production
unloader with a real two-halfword RTC response.

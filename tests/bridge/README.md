# Pocket bridge regressions

The pipeline regression protects the Analogue PMP bridge's one-word read pipeline. The
current buffered word must start transmitting after four `clk_74a` cycles;
only then may `pmp_rd` request the following word. Waiting for memory completion
before starting the current response causes Pocket read timeouts and exported
save files filled with `0xDEADDEAD`.

The command regression protects K3V's specialized `core_bridge_cmd`. It covers
all retained host commands, status/reset, dataslot and RTC notifications,
savestate queries and requests, endian conversion, constant target pointers,
and the mandatory target Ready-to-Run handshake. K3V does not expose the
generic target dataslot/getfile/openfile request interface.

Run it with:

```console
python tests/bridge/run.py --iverilog <path-to-iverilog> --vvp <path-to-vvp>
```

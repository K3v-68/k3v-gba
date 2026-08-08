# Pocket bridge pipeline regression

This test protects the Analogue PMP bridge's one-word read pipeline. The
current buffered word must start transmitting after four `clk_74a` cycles;
only then may `pmp_rd` request the following word. Waiting for memory completion
before starting the current response causes Pocket read timeouts and exported
save files filled with `0xDEADDEAD`.

Run it with:

```console
python tests/bridge/run.py --iverilog <path-to-iverilog> --vvp <path-to-vvp>
```

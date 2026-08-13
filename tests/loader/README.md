# APF write-ingress simulation tests

These regressions verify the asynchronous APF-to-memory contracts for both the
generic `data_loader` and K3V's shared `apf_write_ingress`, using the lightweight
`dcfifo` model shared with the save-path tests.

It covers unrelated bridge and memory clocks, upper-address-nibble filtering,
both endian modes, maximum-rate consecutive bridge words, exact halfword address
and data ordering, ready backpressure with a stable payload, and busy remaining
asserted until every queued halfword drains. The shared-ingress test additionally
interleaves ROM/save/BIOS traffic, changes bridge inputs immediately after atomic
capture, stalls save traffic ahead of queued ROM/BIOS words, verifies destination
cooldowns, and checks the final busy barrier.

Run it with Icarus Verilog:

```console
python tests/loader/run.py --iverilog /path/to/iverilog --vvp /path/to/vvp
```

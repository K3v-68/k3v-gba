# Data-loader simulation test

This regression verifies the asynchronous APF-to-memory `data_loader` contract
using the lightweight `dcfifo` model shared with the save-path tests.

It covers unrelated bridge and memory clocks, upper-address-nibble filtering,
both endian modes, maximum-rate consecutive bridge words, exact halfword address
and data ordering, `USE_WRITE_READY` backpressure with a stable payload, and
`write_busy` remaining asserted until every queued halfword drains.

Run it with Icarus Verilog:

```console
python tests/loader/run.py --iverilog /path/to/iverilog --vvp /path/to/vvp
```

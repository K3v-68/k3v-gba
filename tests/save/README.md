# Save-path simulation tests

This directory verifies the variable-latency `data_unloader` memory contract
without Quartus libraries. The behavioral `dcfifo` model supplies only the
primitive behavior used by the DUT.

The default run transfers 4 KiB each of patterned, deterministic-random, and
all-`FF` save data, then launches a separate missing-response regression:

```console
python tests/save/run.py
```

Use `--full` for three complete 128 KiB transfers, or select a shorter size and
simulator explicitly:

```console
python tests/save/run.py --full --simulator iverilog
python tests/save/run.py --bytes 1024 --simulator verilator
```

The tests use unrelated bridge/memory clocks, randomized and deliberately long
`read_ready` backpressure and response latency, and check every returned byte.
They also assert request stability, one accepted request per response, and that
neither the response FIFO nor bridge-valid can advance before real memory data.
The missing-response run proves an unanswered read remains stalled and does not
fabricate a zero or stale completion.

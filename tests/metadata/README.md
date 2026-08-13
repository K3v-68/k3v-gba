# Boot-metadata regression

This self-checking Icarus regression protects the two pieces of metadata read
while a ROM is downloaded:

- the complete 26-prefix / 44-exact cart-quirk database and its sequential
  ready/hold contract; and
- both byte alignments of `FLASH1M_V`, stream discontinuities, malformed
  signatures, sticky detection, reset priority, and ROM-header byte order.

The testbench owns an independent golden lookup table. Mutated IDs are always
checked against that oracle because a one-bit mutation can legitimately become
another database key.

Run it directly with:

```text
python tests/metadata/run.py --iverilog <iverilog> --vvp <vvp>
```

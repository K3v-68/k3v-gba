# RTC tests

`tb_gba_rtc_clock.vhd` is a self-checking VHDL-2008 testbench. It runs each
startup case in a fresh elaboration so initialization remains one-shot, just as
it is after loading a Pocket FPGA configuration.

Run the dependency-free calendar/reference checks:

```powershell
python tests/rtc/run.py --model-only
```

Run all reference and RTL scenarios when GHDL and Icarus Verilog are installed:

```powershell
python tests/rtc/run.py --require-ghdl --require-iverilog
```

The testbench uses a five-cycle second only to keep simulation short. The run
script separately asserts that production RTL defaults and integration use the
measured `100,663,296 Hz` PLL output; the divider terminal is therefore
`100,663,295`.

Coverage includes atomic startup, exact divider phase, duplicate initialization,
1-second/10-minute/1-hour/24-hour catch-up, persisted restart, host-clock
rollback, month/year/weekday/leap rollovers, valid game writes, RTC reset, and
write/reset/tick priority. It also covers the separate 16-byte RTC sidecar,
legacy-footer migration, source precedence, validation, and tear-free shutdown
serialization. Separate uninterrupted runs cover 10 simulated
minutes, 1 simulated hour, and 24 simulated hours.

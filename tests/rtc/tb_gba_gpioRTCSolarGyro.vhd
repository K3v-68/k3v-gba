library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library std;
use std.env.all;

use work.pProc_bus_gba.all;

-- End-to-end S-3511A GPIO protocol checks.  This bench deliberately drives the
-- same C4/C6/C8 register interface as the GBA, rather than reaching into the
-- wrapper's internal RTC signals.
entity tb_gba_gpioRTCSolarGyro is
end entity;

architecture test of tb_gba_gpioRTCSolarGyro is

   constant CLK_PERIOD : time := 10 ns;

   type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

   signal clk100             : std_logic := '0';
   signal reset              : std_logic := '0';
   signal gba_on             : std_logic := '1';
   signal GPIO_readEna       : std_logic := '0';
   signal GPIO_done          : std_logic;
   signal GPIO_Din           : std_logic_vector(3 downto 0);
   signal GPIO_Dout          : std_logic_vector(3 downto 0) := (others => '0');
   signal GPIO_writeEna      : std_logic := '0';
   signal GPIO_addr          : std_logic_vector(1 downto 0) := (others => '0');
   signal RTC_timestampNew   : std_logic := '0';
   signal RTC_timestampIn    : std_logic_vector(31 downto 0) := (others => '0');
   signal RTC_timestampSaved : std_logic_vector(31 downto 0) := (others => '0');
   signal RTC_savedtimeIn    : std_logic_vector(41 downto 0) := (others => '0');
   signal RTC_saveLoaded     : std_logic := '0';
   signal RTC_timestampOut   : std_logic_vector(31 downto 0);
   signal RTC_savedtimeOut   : std_logic_vector(41 downto 0);
   signal RTC_inuse          : std_logic;
   signal RTC_initDone       : std_logic;

   signal savestate_bus : proc_bus_gb_type :=
   (
      Din  => (others => '0'),
      Dout => (others => 'Z'),
      Adr  => (others => '0'),
      rnw  => '0',
      ena  => '0',
      done => 'Z',
      acc  => "00",
      bEna => "0000",
      rst  => '0'
   );

   function integer_to_bcd(value : natural;
                           width : positive) return std_logic_vector is
      variable encoded : natural;
   begin
      encoded := ((value / 10) * 16) + (value mod 10);
      return std_logic_vector(to_unsigned(encoded, width));
   end function;

   function pack_time(year_value  : natural;
                      month_value : natural;
                      day_value   : natural;
                      wday_value  : natural;
                      hour_value  : natural;
                      min_value   : natural;
                      sec_value   : natural) return std_logic_vector is
   begin
      return integer_to_bcd(year_value, 8) &
             integer_to_bcd(month_value, 5) &
             integer_to_bcd(day_value, 6) &
             std_logic_vector(to_unsigned(wday_value, 3)) &
             integer_to_bcd(hour_value, 6) &
             integer_to_bcd(min_value, 7) &
             integer_to_bcd(sec_value, 7);
   end function;

   function wire_hour_12(display_hour : natural;
                         is_pm        : boolean) return std_logic_vector is
      variable result : std_logic_vector(7 downto 0) := (others => '0');
   begin
      result(5 downto 0) := integer_to_bcd(display_hour, 6);
      if is_pm then
         result(7) := '1';
      end if;
      return result;
   end function;

begin

   clk100 <= not clk100 after CLK_PERIOD / 2;

   dut : entity work.gba_gpioRTCSolarGyro
   port map
   (
      clk100             => clk100,
      reset              => reset,
      GBA_on             => gba_on,
      savestate_bus      => savestate_bus,
      GPIO_readEna       => GPIO_readEna,
      GPIO_done          => GPIO_done,
      GPIO_Din           => GPIO_Din,
      GPIO_Dout          => GPIO_Dout,
      GPIO_writeEna      => GPIO_writeEna,
      GPIO_addr          => GPIO_addr,
      vblank_trigger     => '0',
      RTC_timestampNew   => RTC_timestampNew,
      RTC_timestampIn    => RTC_timestampIn,
      RTC_timestampSaved => RTC_timestampSaved,
      RTC_savedtimeIn    => RTC_savedtimeIn,
      RTC_saveLoaded     => RTC_saveLoaded,
      RTC_timestampOut   => RTC_timestampOut,
      RTC_savedtimeOut   => RTC_savedtimeOut,
      RTC_inuse          => RTC_inuse,
      RTC_initDone       => RTC_initDone,
      dummy              => '0'
   );

   stimulus : process
      procedure clock_edge is
      begin
         wait until rising_edge(clk100);
         -- Let both registered updates and concurrent output assignments settle.
         wait for 1 ns;
      end procedure;

      procedure gpio_write(address_value : std_logic_vector(1 downto 0);
                           data_value    : std_logic_vector(3 downto 0)) is
      begin
         GPIO_addr     <= address_value;
         GPIO_Dout     <= data_value;
         GPIO_writeEna <= '1';
         clock_edge;
         GPIO_writeEna <= '0';
         wait for 1 ns;
      end procedure;

      procedure gpio_read(address_value : std_logic_vector(1 downto 0);
                          variable data_value : out std_logic_vector(3 downto 0)) is
      begin
         GPIO_addr    <= address_value;
         GPIO_readEna <= '1';
         clock_edge;
         data_value   := GPIO_Din;
         assert GPIO_done = '1'
            report "GPIO read did not assert done"
            severity failure;
         GPIO_readEna <= '0';
         wait for 1 ns;
      end procedure;

      procedure set_direction(value : std_logic_vector(3 downto 0)) is
      begin
         gpio_write("01", value);
      end procedure;

      procedure drive_pins(value : std_logic_vector(3 downto 0)) is
      begin
         gpio_write("00", value);
      end procedure;

      procedure pulse_serial_bit(value : std_logic) is
         variable pins : std_logic_vector(3 downto 0);
      begin
         -- Bit 2 is chip select, bit 1 is serial data, and bit 0 is clock.
         pins := "0100";
         pins(1) := value;
         drive_pins(pins);
         pins(0) := '1';
         drive_pins(pins);
      end procedure;

      procedure begin_transaction(opcode : std_logic_vector(7 downto 0)) is
      begin
         set_direction(x"7");
         -- The wrapper recognizes CS low/high while the serial clock is high.
         drive_pins(x"1");
         drive_pins(x"5");
         -- Command bytes are transmitted MSB first.
         for bit_index in 7 downto 0 loop
            pulse_serial_bit(opcode(bit_index));
         end loop;
      end procedure;

      procedure end_transaction is
      begin
         drive_pins(x"1");
      end procedure;

      procedure write_transaction(opcode  : std_logic_vector(7 downto 0);
                                  payload : byte_array_t) is
      begin
         begin_transaction(opcode);
         -- Payload bytes are transmitted LSB first.
         for byte_index in payload'range loop
            for bit_index in 0 to 7 loop
               pulse_serial_bit(payload(byte_index)(bit_index));
            end loop;
         end loop;
      end procedure;

      procedure read_transaction(opcode : std_logic_vector(7 downto 0);
                                 variable payload : out byte_array_t) is
         variable pins       : std_logic_vector(3 downto 0);
         variable read_value : std_logic_vector(3 downto 0);
      begin
         begin_transaction(opcode);
         -- Release the data pin while retaining clock and CS as outputs.
         set_direction(x"5");
         for byte_index in payload'range loop
            payload(byte_index) := (others => '0');
            for bit_index in 0 to 7 loop
               drive_pins(x"4");
               drive_pins(x"5");
               gpio_read("00", read_value);
               payload(byte_index)(bit_index) := read_value(1);
            end loop;
         end loop;
         end_transaction;
      end procedure;

      procedure set_control(value : std_logic_vector(7 downto 0)) is
         variable payload : byte_array_t(0 to 0);
      begin
         payload(0) := value;
         write_transaction(x"62", payload);
         -- This edge both deselects the serial device and commits saveCTL_next.
         end_transaction;
      end procedure;

      procedure write_rtc_and_expect(opcode        : std_logic_vector(7 downto 0);
                                     payload       : byte_array_t;
                                     expected_time : std_logic_vector(41 downto 0);
                                     label_text    : string) is
         variable previous_time : std_logic_vector(41 downto 0);
      begin
         previous_time := RTC_savedtimeOut;
         write_transaction(opcode, payload);

         -- The GPIO wrapper captures the assembled value on the final serial
         -- edge.  gba_rtc_clock sees that registered pulse one edge later and
         -- performs its atomic decode/commit on the following edge.  A stale
         -- final byte, early update, or an extra wrapper stage fails here.
         assert RTC_savedtimeOut = previous_time
            report label_text & ": RTC changed on the final serial edge"
            severity failure;
         clock_edge;
         assert RTC_savedtimeOut = previous_time
            report label_text & ": RTC changed before its atomic commit edge"
            severity failure;
         clock_edge;
         assert RTC_savedtimeOut = expected_time
            report label_text & ": RTC value missing at the expected commit edge"
            severity failure;
         end_transaction;
      end procedure;

      variable full_write     : byte_array_t(0 to 6);
      variable full_read      : byte_array_t(0 to 6);
      variable hms_write      : byte_array_t(0 to 2);
      variable hms_read       : byte_array_t(0 to 2);
      variable expected_time  : std_logic_vector(41 downto 0);
      variable expected_hour  : std_logic_vector(7 downto 0);
      variable internal_hour  : natural;
      variable second_value   : natural;
      variable initialized    : boolean := false;
   begin
      -- Establish deterministic GPIO FSM/savestate state first.
      reset <= '1';
      clock_edge;
      reset <= '0';
      gpio_write("10", x"1"); -- enable GPIO register access

      RTC_savedtimeIn    <= pack_time(24, 1, 2, 2, 0, 0, 3);
      RTC_timestampSaved <= std_logic_vector(to_unsigned(1000, 32));
      RTC_timestampIn    <= std_logic_vector(to_unsigned(1000, 32));
      RTC_saveLoaded     <= '1';
      for cycle_count in 0 to 100 loop
         clock_edge;
         if RTC_initDone = '1' then
            initialized := true;
            exit;
         end if;
      end loop;
      assert initialized
         report "integrated RTC initialization did not finish"
         severity failure;

      -- 12-hour mode.  A full write uses 00 PM, which must become internal
      -- hour 12.  Its deliberately nonzero final seconds byte catches the
      -- historical last-byte shift/capture bug.
      set_control(x"00");
      full_write(0) := x"24";
      full_write(1) := x"08";
      full_write(2) := x"06";
      full_write(3) := x"04";
      full_write(4) := x"80"; -- 00 PM in S-3511A 12-hour representation
      full_write(5) := x"34";
      full_write(6) := x"57";
      expected_time := pack_time(24, 8, 6, 4, 12, 34, 57);
      write_rtc_and_expect(x"64", full_write, expected_time,
                           "12-hour full write/final byte");

      read_transaction(x"65", full_read);
      assert full_read(0) = x"24" and full_read(1) = x"08" and
             full_read(2) = x"06" and full_read(3) = x"04" and
             full_read(4) = x"80" and full_read(5) = x"34" and
             full_read(6) = x"57"
         report "12-hour full read did not return 00 PM and the full payload"
         severity failure;

      -- Exhaustively exercise 00..11 in both AM and PM.  The final byte is
      -- varied with the expected internal hour so every command-0x66 write
      -- also proves that its eighth/final seconds bit was captured.
      for pm_index in 0 to 1 loop
         for display_hour in 0 to 11 loop
            internal_hour := display_hour + (pm_index * 12);
            hms_write(0) := wire_hour_12(display_hour, pm_index = 1);
            hms_write(1) := x"34";
            hms_write(2) := integer_to_bcd(internal_hour, 8);
            expected_time := pack_time(24, 8, 6, 4,
                                       internal_hour, 34, internal_hour);
            write_rtc_and_expect(x"66", hms_write, expected_time,
                                 "12-hour command 0x66");

            read_transaction(x"67", hms_read);
            assert hms_read(0) = hms_write(0)
               report "12-hour readback did not preserve 00..11 plus AM/PM at hour " &
                      integer'image(internal_hour)
               severity failure;
            assert hms_read(1) = x"34" and hms_read(2) = hms_write(2)
               report "12-hour time-only readback payload mismatch at hour " &
                      integer'image(internal_hour)
               severity failure;
         end loop;
      end loop;

      -- In 24-hour mode the six BCD hour bits remain 00..23, while bit 7 must
      -- still report PM for every hour from 12 through 23.
      set_control(x"40");
      for hour_value in 0 to 23 loop
         second_value := (hour_value + 7) mod 60;
         hms_write(0) := integer_to_bcd(hour_value, 8);
         hms_write(1) := x"45";
         hms_write(2) := integer_to_bcd(second_value, 8);
         expected_time := pack_time(24, 8, 6, 4,
                                    hour_value, 45, second_value);
         write_rtc_and_expect(x"66", hms_write, expected_time,
                              "24-hour command 0x66");

         read_transaction(x"67", hms_read);
         expected_hour := integer_to_bcd(hour_value, 8);
         if hour_value >= 12 then
            expected_hour(7) := '1';
         end if;
         assert hms_read(0) = expected_hour
            report "24-hour read PM-bit mismatch at hour " &
                   integer'image(hour_value)
            severity failure;
         assert hms_read(1) = x"45" and
                hms_read(2) = integer_to_bcd(second_value, 8)
            report "24-hour time-only readback payload mismatch at hour " &
                   integer'image(hour_value)
            severity failure;
      end loop;

      report "GPIO S-3511A protocol checks passed" severity note;
      finish;
      wait;
   end process;

end architecture;

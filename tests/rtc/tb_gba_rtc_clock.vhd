library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library std;
use std.env.all;

-- Self-checking behavioral testbench for gba_rtc_clock.  run.py executes each
-- scenario in a fresh elaboration, which also models a new FPGA configuration.
entity tb_gba_rtc_clock is
   generic
   (
      SCENARIO : natural := 0;
      CLK_HZ   : positive := 5
   );
end entity;

architecture test of tb_gba_rtc_clock is

   constant CLK_PERIOD : time := 10 ns;

   signal clk                 : std_logic := '0';
   signal initialize          : std_logic := '0';
   signal timestamp_now       : std_logic_vector(31 downto 0) := (others => '0');
   signal timestamp_saved     : std_logic_vector(31 downto 0) := (others => '0');
   signal saved_time_in       : std_logic_vector(41 downto 0) := (others => '0');
   signal game_time_write     : std_logic := '0';
   signal game_time_time_only : std_logic := '0';
   signal game_reset          : std_logic := '0';
   signal game_time_in        : std_logic_vector(41 downto 0) := (others => '0');
   signal timestamp_out       : std_logic_vector(31 downto 0);
   signal saved_time_out      : std_logic_vector(41 downto 0);
   signal initialization_done : std_logic;

   function integer_to_bcd(value : natural; width : positive) return std_logic_vector is
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

begin

   clk <= not clk after CLK_PERIOD / 2;

   dut : entity work.gba_rtc_clock
   generic map
   (
      CLK_FREQUENCY_HZ => CLK_HZ
   )
   port map
   (
      clk                 => clk,
      initialize          => initialize,
      timestamp_now       => timestamp_now,
      timestamp_saved     => timestamp_saved,
      saved_time_in       => saved_time_in,
      game_time_write     => game_time_write,
      game_time_time_only => game_time_time_only,
      game_reset          => game_reset,
      game_time_in        => game_time_in,
      timestamp_out       => timestamp_out,
      saved_time_out      => saved_time_out,
      initialization_done => initialization_done
   );

   stimulus : process
      procedure clock_edge is
      begin
         wait until rising_edge(clk);
         -- Allow registered and concurrent output assignments to settle.
         wait for 1 ns;
      end procedure;

      procedure start_initialization(source_time : std_logic_vector(41 downto 0);
                                     saved_epoch : natural;
                                     now_epoch   : natural) is
      begin
         saved_time_in   <= source_time;
         timestamp_saved <= std_logic_vector(to_unsigned(saved_epoch, 32));
         timestamp_now   <= std_logic_vector(to_unsigned(now_epoch, 32));
         initialize      <= '1';
         clock_edge;
         initialize      <= '0';
      end procedure;

      procedure wait_for_commit(expected_time  : std_logic_vector(41 downto 0);
                                expected_epoch : natural) is
         variable old_time  : std_logic_vector(41 downto 0);
         variable old_epoch : std_logic_vector(31 downto 0);
         variable committed : boolean := false;
      begin
         old_time  := saved_time_out;
         old_epoch := timestamp_out;

         for cycle_count in 0 to 50050 loop
            clock_edge;
            if initialization_done = '1' then
               committed := true;
               exit;
            end if;

            assert saved_time_out = old_time
               report "calendar changed before atomic initialization commit"
               severity failure;
            assert timestamp_out = old_epoch
               report "timestamp changed before atomic initialization commit"
               severity failure;
         end loop;

         assert committed
            report "initialization did not complete within the bounded catch-up interval"
            severity failure;
         assert saved_time_out = expected_time
            report "calendar mismatch after initialization"
            severity failure;
         assert unsigned(timestamp_out) = expected_epoch
            report "timestamp mismatch after initialization"
            severity failure;
      end procedure;

      procedure initialize_and_expect(source_time   : std_logic_vector(41 downto 0);
                                      elapsed       : natural;
                                      expected_time : std_logic_vector(41 downto 0)) is
         constant SAVED_EPOCH : natural := 100000;
      begin
         start_initialization(source_time, SAVED_EPOCH, SAVED_EPOCH + elapsed);
         wait_for_commit(expected_time, SAVED_EPOCH + elapsed);
      end procedure;

      procedure write_game_time(value : std_logic_vector(41 downto 0);
                                 expected_epoch : natural) is
         variable previous_time : std_logic_vector(41 downto 0);
      begin
         previous_time   := saved_time_out;
         game_time_in    <= value;
         game_time_write <= '1';
         clock_edge;
         game_time_write <= '0';
         assert saved_time_out = previous_time
            report "game time changed before the registered atomic commit"
            severity failure;
         clock_edge;
         assert saved_time_out = value
            report "valid game time write was not committed atomically"
            severity failure;
         assert unsigned(timestamp_out) = expected_epoch
            report "game time write unexpectedly changed the epoch marker"
            severity failure;
      end procedure;

      procedure write_game_time_only(value          : std_logic_vector(41 downto 0);
                                     expected_time  : std_logic_vector(41 downto 0);
                                     expected_epoch : natural) is
         variable previous_time : std_logic_vector(41 downto 0);
      begin
         previous_time       := saved_time_out;
         game_time_in        <= value;
         game_time_time_only <= '1';
         game_time_write     <= '1';
         clock_edge;
         game_time_write     <= '0';
         game_time_time_only <= '0';
         assert saved_time_out = previous_time
            report "time-only write changed the calendar before atomic commit"
            severity failure;
         clock_edge;
         assert saved_time_out = expected_time
            report "time-only write did not preserve the decoded live date"
            severity failure;
         assert unsigned(timestamp_out) = expected_epoch
            report "time-only write/tick collision advanced the epoch marker"
            severity failure;
      end procedure;

      procedure expect_one_tick(before_time  : std_logic_vector(41 downto 0);
                                after_time   : std_logic_vector(41 downto 0);
                                before_epoch : natural) is
      begin
         for edge_count in 1 to CLK_HZ - 1 loop
            clock_edge;
            assert saved_time_out = before_time
               report "calendar ticked before CLK_FREQUENCY_HZ cycles"
               severity failure;
            assert unsigned(timestamp_out) = before_epoch
               report "epoch ticked before CLK_FREQUENCY_HZ cycles"
               severity failure;
         end loop;

         clock_edge;
         assert saved_time_out = after_time
            report "calendar did not tick on the exact divider terminal cycle"
            severity failure;
         assert unsigned(timestamp_out) = before_epoch + 1
            report "epoch did not advance with the calendar tick"
            severity failure;
      end procedure;

      procedure expect_uninterrupted_run(elapsed_seconds : natural;
                                         expected_time   : std_logic_vector(41 downto 0);
                                         initial_epoch   : natural) is
      begin
         for second_count in 1 to elapsed_seconds loop
            for edge_count in 1 to CLK_HZ - 1 loop
               clock_edge;
               assert unsigned(timestamp_out) = initial_epoch + second_count - 1
                  report "extra epoch tick during uninterrupted simulated run"
                  severity failure;
            end loop;
            clock_edge;
            assert unsigned(timestamp_out) = initial_epoch + second_count
               report "missing epoch tick during uninterrupted simulated run"
               severity failure;
         end loop;
         assert saved_time_out = expected_time
            report "calendar mismatch after uninterrupted simulated run"
            severity failure;
         assert unsigned(timestamp_out) = initial_epoch + elapsed_seconds
            report "epoch mismatch after uninterrupted simulated run"
            severity failure;
      end procedure;

      variable base_epoch : natural;
      variable before_time : std_logic_vector(41 downto 0);
   begin
      wait for 1 ns;
      assert CLK_HZ >= 4
         report "testbench CLK_HZ must be at least four"
         severity failure;
      assert initialization_done = '0'
         report "initialization_done must start low"
         severity failure;

      case SCENARIO is
         when 0 =>
            -- Startup atomicity, exact divider, and duplicate initialize.
            initialize_and_expect(pack_time(24, 1, 1, 1, 0, 0, 0), 1,
                                  pack_time(24, 1, 1, 1, 0, 0, 1));
            base_epoch := 100001;

            -- Keeping/reasserting initialize high with changed inputs must not
            -- re-anchor the already running RTC or disturb divider phase.
            saved_time_in   <= pack_time(99, 12, 31, 6, 23, 59, 59);
            timestamp_saved <= std_logic_vector(to_unsigned(1, 32));
            timestamp_now   <= std_logic_vector(to_unsigned(999999, 32));
            initialize      <= '1';
            expect_one_tick(pack_time(24, 1, 1, 1, 0, 0, 1),
                            pack_time(24, 1, 1, 1, 0, 0, 2), base_epoch);

            -- A second pulse is also ignored and cannot reset the divider.
            initialize <= '0';
            clock_edge;
            initialize <= '1';
            clock_edge;
            initialize <= '0';
            for edge_count in 1 to CLK_HZ - 3 loop
               clock_edge;
            end loop;
            assert saved_time_out = pack_time(24, 1, 1, 1, 0, 0, 2)
               report "duplicate initialize changed the running calendar"
               severity failure;
            assert unsigned(timestamp_out) = base_epoch + 1
               report "duplicate initialize re-anchored the epoch"
               severity failure;
            clock_edge;
            assert saved_time_out = pack_time(24, 1, 1, 1, 0, 0, 3)
               report "duplicate initialize disturbed divider phase"
               severity failure;
            assert unsigned(timestamp_out) = base_epoch + 2
               report "second exact tick missing after duplicate initialize"
               severity failure;

         when 1 =>
            initialize_and_expect(pack_time(24, 6, 15, 6, 12, 34, 56), 1,
                                  pack_time(24, 6, 15, 6, 12, 34, 57));

         when 2 =>
            initialize_and_expect(pack_time(24, 6, 15, 6, 12, 34, 56), 600,
                                  pack_time(24, 6, 15, 6, 12, 44, 56));

         when 3 =>
            initialize_and_expect(pack_time(24, 6, 15, 6, 12, 34, 56), 3600,
                                  pack_time(24, 6, 15, 6, 13, 34, 56));

         when 4 =>
            initialize_and_expect(pack_time(24, 6, 15, 6, 12, 34, 56), 86400,
                                  pack_time(24, 6, 16, 0, 12, 34, 56));

         when 5 =>
            initialize_and_expect(pack_time(24, 1, 31, 3, 23, 59, 59), 1,
                                  pack_time(24, 2, 1, 4, 0, 0, 0));

         when 6 =>
            initialize_and_expect(pack_time(24, 4, 30, 2, 23, 59, 59), 1,
                                  pack_time(24, 5, 1, 3, 0, 0, 0));

         when 7 =>
            initialize_and_expect(pack_time(1, 2, 28, 3, 23, 59, 59), 1,
                                  pack_time(1, 3, 1, 4, 0, 0, 0));

         when 8 =>
            initialize_and_expect(pack_time(4, 2, 28, 6, 23, 59, 59), 1,
                                  pack_time(4, 2, 29, 0, 0, 0, 0));

         when 9 =>
            initialize_and_expect(pack_time(4, 2, 29, 0, 23, 59, 59), 1,
                                  pack_time(4, 3, 1, 1, 0, 0, 0));

         when 10 =>
            initialize_and_expect(pack_time(99, 12, 31, 6, 23, 59, 59), 1,
                                  pack_time(0, 1, 1, 0, 0, 0, 0));

         when 11 =>
            -- Host rollback clamps elapsed to zero but anchors the new epoch.
            start_initialization(pack_time(24, 8, 6, 2, 7, 8, 9), 200000, 199000);
            wait_for_commit(pack_time(24, 8, 6, 2, 7, 8, 9), 199000);

         when 12 =>
            -- A fresh elaboration models restart with a persisted timestamp.
            initialize_and_expect(pack_time(24, 8, 5, 1, 7, 8, 9), 90061,
                                  pack_time(24, 8, 6, 2, 8, 9, 10));

         when 13 =>
            -- Valid game writes, all requested live rollovers, reset, and
            -- priority when reset/write collide with the terminal tick.
            initialize_and_expect(pack_time(24, 6, 15, 6, 12, 0, 0), 0,
                                  pack_time(24, 6, 15, 6, 12, 0, 0));
            base_epoch := 100000;

            clock_edge;
            clock_edge;
            write_game_time(pack_time(1, 2, 28, 3, 23, 59, 59), base_epoch);
            expect_one_tick(pack_time(1, 2, 28, 3, 23, 59, 59),
                            pack_time(1, 3, 1, 4, 0, 0, 0), base_epoch);
            base_epoch := base_epoch + 1;

            write_game_time(pack_time(4, 2, 28, 6, 23, 59, 59), base_epoch);
            expect_one_tick(pack_time(4, 2, 28, 6, 23, 59, 59),
                            pack_time(4, 2, 29, 0, 0, 0, 0), base_epoch);
            base_epoch := base_epoch + 1;

            write_game_time(pack_time(4, 2, 29, 0, 23, 59, 59), base_epoch);
            expect_one_tick(pack_time(4, 2, 29, 0, 23, 59, 59),
                            pack_time(4, 3, 1, 1, 0, 0, 0), base_epoch);
            base_epoch := base_epoch + 1;

            write_game_time(pack_time(24, 4, 30, 2, 23, 59, 59), base_epoch);
            expect_one_tick(pack_time(24, 4, 30, 2, 23, 59, 59),
                            pack_time(24, 5, 1, 3, 0, 0, 0), base_epoch);
            base_epoch := base_epoch + 1;

            write_game_time(pack_time(99, 12, 31, 6, 23, 59, 59), base_epoch);
            expect_one_tick(pack_time(99, 12, 31, 6, 23, 59, 59),
                            pack_time(0, 1, 1, 0, 0, 0, 0), base_epoch);
            base_epoch := base_epoch + 1;

            clock_edge;
            clock_edge;
            game_reset <= '1';
            clock_edge;
            game_reset <= '0';
            assert saved_time_out = pack_time(0, 1, 1, 0, 0, 0, 0)
               report "game reset did not restore the S-3511 reset calendar"
               severity failure;
            assert unsigned(timestamp_out) = base_epoch
               report "game reset unexpectedly changed the epoch marker"
               severity failure;

            -- Place the divider at its terminal value, then collide reset and
            -- write with the would-be tick.  Reset must win and suppress it.
            for edge_count in 1 to CLK_HZ - 1 loop
               clock_edge;
            end loop;
            before_time := saved_time_out;
            game_time_in    <= pack_time(50, 5, 5, 5, 5, 5, 5);
            game_time_write <= '1';
            game_reset      <= '1';
            clock_edge;
            game_time_write <= '0';
            game_reset      <= '0';
            assert saved_time_out = before_time
               report "game reset lost priority over write/tick collision"
               severity failure;
            assert unsigned(timestamp_out) = base_epoch
               report "tick was not suppressed by game reset priority"
               severity failure;

         when 14 =>
            -- Invalid packed BCD never receives an untrusted catch-up delta.
            start_initialization(pack_time(24, 13, 1, 1, 0, 0, 0), 1, 2000000000);
            wait_for_commit(pack_time(0, 1, 1, 6, 0, 0, 0), 2000000000);

         when 15 =>
            initialize_and_expect(pack_time(24, 6, 15, 6, 12, 34, 56), 0,
                                  pack_time(24, 6, 15, 6, 12, 34, 56));
            expect_uninterrupted_run(600, pack_time(24, 6, 15, 6, 12, 44, 56),
                                     100000);

         when 16 =>
            initialize_and_expect(pack_time(24, 6, 15, 6, 12, 34, 56), 0,
                                  pack_time(24, 6, 15, 6, 12, 34, 56));
            expect_uninterrupted_run(3600, pack_time(24, 6, 15, 6, 13, 34, 56),
                                     100000);

         when 17 =>
            initialize_and_expect(pack_time(24, 6, 15, 6, 12, 34, 56), 0,
                                  pack_time(24, 6, 15, 6, 12, 34, 56));
            expect_uninterrupted_run(86400, pack_time(24, 6, 16, 0, 12, 34, 56),
                                     100000);

         when 18 =>
            initialize_and_expect(pack_time(24, 12, 31, 2, 23, 59, 58), 0,
                                  pack_time(24, 12, 31, 2, 23, 59, 58));

            -- Put the divider at its terminal count.  A valid command 0x66
            -- write must win over the would-be tick, preserve the decoded
            -- date, and leave the epoch marker unchanged.  Deliberately bad
            -- date bits prove that time-only validation ignores them.
            for edge_count in 1 to CLK_HZ - 1 loop
               clock_edge;
            end loop;
            write_game_time_only(pack_time(99, 13, 31, 7, 5, 6, 7),
                                 pack_time(24, 12, 31, 2, 5, 6, 7), 100000);

            -- An invalid time field is rejected and therefore must not steal
            -- the terminal tick from the running clock.
            for edge_count in 1 to CLK_HZ - 1 loop
               clock_edge;
            end loop;
            game_time_in        <= pack_time(0, 1, 1, 0, 24, 0, 0);
            game_time_time_only <= '1';
            game_time_write     <= '1';
            clock_edge;
            game_time_write     <= '0';
            game_time_time_only <= '0';
            assert saved_time_out = pack_time(24, 12, 31, 2, 5, 6, 8)
               report "invalid time-only write suppressed the running tick"
               severity failure;
            assert unsigned(timestamp_out) = 100001
               report "invalid time-only write suppressed the epoch tick"
               severity failure;

         when others =>
            assert false report "unknown SCENARIO generic" severity failure;
      end case;

      report "RTC scenario " & integer'image(SCENARIO) & " passed" severity note;
      finish;
      wait;
   end process;

end architecture;

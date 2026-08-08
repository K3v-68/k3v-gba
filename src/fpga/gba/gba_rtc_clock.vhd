library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Cartridge RTC timekeeper.
--
-- The Pocket core clock is 100.663296 MHz (6 * 2^24 Hz), not 100 MHz.
-- Offline elapsed time is calculated into shadow registers and committed once;
-- it never drives the live one-second state machine as a fast-forward loop.
entity gba_rtc_clock is
   generic
   (
      CLK_FREQUENCY_HZ : positive := 100663296
   );
   port
   (
      clk                 : in  std_logic;
      initialize          : in  std_logic;
      timestamp_now       : in  std_logic_vector(31 downto 0);
      timestamp_saved     : in  std_logic_vector(31 downto 0);
      saved_time_in       : in  std_logic_vector(41 downto 0);
      game_time_write     : in  std_logic;
      game_time_time_only : in  std_logic;
      game_reset          : in  std_logic;
      game_time_in        : in  std_logic_vector(41 downto 0);
      timestamp_out       : out std_logic_vector(31 downto 0);
      saved_time_out      : out std_logic_vector(41 downto 0);
      initialization_done : out std_logic := '0'
   );
end entity;

architecture rtl of gba_rtc_clock is

   type init_state_t is
   (
      WAIT_FOR_INITIALIZE,
      ADD_SOURCE_HOURS,
      ADD_SOURCE_MINUTES,
      ADD_SOURCE_SECONDS,
      LOAD_OFFLINE_DAYS,
      APPLY_OFFLINE_DAYS,
      ADVANCE_OFFLINE_DAY,
      SUBTRACT_OFFLINE_DAY,
      APPLY_OFFLINE_HOURS,
      SUBTRACT_OFFLINE_HOUR,
      APPLY_OFFLINE_MINUTES,
      SUBTRACT_OFFLINE_MINUTE,
      COMMIT_INITIALIZATION,
      RUNNING
   );
   signal init_state : init_state_t := WAIT_FOR_INITIALIZE;

   signal live_year  : integer range 0 to 99 := 0;
   signal live_month : integer range 1 to 12 := 1;
   signal live_day   : integer range 1 to 31 := 1;
   signal live_wday  : integer range 0 to 6 := 6;
   signal live_hour  : integer range 0 to 23 := 0;
   signal live_min   : integer range 0 to 59 := 0;
   signal live_sec   : integer range 0 to 59 := 0;

   signal work_year  : integer range 0 to 99 := 0;
   signal work_month : integer range 1 to 12 := 1;
   signal work_day   : integer range 1 to 31 := 1;
   signal work_wday  : integer range 0 to 6 := 6;
   signal work_hour  : integer range 0 to 23 := 0;
   signal work_min   : integer range 0 to 59 := 0;
   signal work_sec   : integer range 0 to 59 := 0;

   -- One extra bit is required because the saved time-of-day is added to the
   -- full 32-bit elapsed interval.  Separate, width-reduced phase accumulators
   -- prevent synthesis from sharing the initialization adder with the repeated
   -- day/hour/minute subtractors into one long feedback cone.
   signal offline_total_seconds     : unsigned(32 downto 0) := (others => '0');
   signal day_seconds_remaining     : unsigned(32 downto 0) := (others => '0');
   signal hour_seconds_remaining    : unsigned(16 downto 0) := (others => '0');
   signal minute_seconds_remaining  : unsigned(11 downto 0) := (others => '0');
   signal source_hours_remaining    : integer range 0 to 23 := 0;
   signal source_minutes_remaining  : integer range 0 to 59 := 0;
   signal source_seconds_remaining  : integer range 0 to 59 := 0;
   signal second_divider            : integer range 0 to CLK_FREQUENCY_HZ - 1 := 0;
   signal timestamp_reg             : unsigned(31 downto 0) := (others => '0');
   signal work_timestamp            : unsigned(31 downto 0) := (others => '0');
   signal pending_game_time         : std_logic_vector(41 downto 0) := (others => '0');
   signal pending_time_only         : std_logic := '0';
   signal game_time_pending         : std_logic := '0';
   signal init_done_reg             : std_logic := '0';

   constant SECONDS_PER_MINUTE_12 : unsigned(11 downto 0) := to_unsigned(60, 12);
   constant SECONDS_PER_HOUR_17   : unsigned(16 downto 0) := to_unsigned(3600, 17);
   constant SECONDS_PER_DAY_33    : unsigned(32 downto 0) := to_unsigned(86400, 33);

   attribute preserve : boolean;
   attribute preserve of offline_total_seconds    : signal is true;
   attribute preserve of day_seconds_remaining    : signal is true;
   attribute preserve of hour_seconds_remaining   : signal is true;
   attribute preserve of minute_seconds_remaining : signal is true;

   function bcd_to_integer(value : std_logic_vector) return integer is
   begin
      -- Every packed field uses a four-bit ones digit with the remaining
      -- upper bits holding the tens digit.  Expressing that structure
      -- directly avoids inferring a generic divider/modulo datapath.
      return (to_integer(unsigned(value(value'high downto value'low + 4))) * 10) +
             to_integer(unsigned(value(value'low + 3 downto value'low)));
   end function;

   function integer_to_bcd(value : integer; width : positive) return std_logic_vector is
      variable tens : integer range 0 to 9;
      variable ones : integer range 0 to 9;
   begin
      -- Constant threshold/subtract logic is dramatically smaller and faster
      -- than the lpm_divide blocks Quartus infers for /10 and mod 10.
      if value >= 90 then tens := 9; ones := value - 90;
      elsif value >= 80 then tens := 8; ones := value - 80;
      elsif value >= 70 then tens := 7; ones := value - 70;
      elsif value >= 60 then tens := 6; ones := value - 60;
      elsif value >= 50 then tens := 5; ones := value - 50;
      elsif value >= 40 then tens := 4; ones := value - 40;
      elsif value >= 30 then tens := 3; ones := value - 30;
      elsif value >= 20 then tens := 2; ones := value - 20;
      elsif value >= 10 then tens := 1; ones := value - 10;
      else tens := 0; ones := value;
      end if;

      return std_logic_vector(to_unsigned(tens, width - 4)) &
             std_logic_vector(to_unsigned(ones, 4));
   end function;

   function is_leap_year(year_value : integer) return boolean is
      variable year_bits : unsigned(6 downto 0);
   begin
      -- The S-3511 RTC exposes only 00..99.  GBA software conventionally
      -- interprets that range as 2000..2099, where every /4 year is leap.
      year_bits := to_unsigned(year_value, year_bits'length);
      return year_bits(1 downto 0) = "00";
   end function;

   function days_in_month(year_value : integer; month_value : integer) return integer is
   begin
      case month_value is
         when 1 | 3 | 5 | 7 | 8 | 10 | 12 => return 31;
         when 4 | 6 | 9 | 11              => return 30;
         when 2 =>
            if is_leap_year(year_value) then return 29;
            else return 28;
            end if;
         when others => return 31;
      end case;
   end function;

   function valid_bcd_hms(value : std_logic_vector(19 downto 0)) return boolean is
   begin
      if unsigned(value(17 downto 14)) > 9 or
         unsigned(value(10 downto 7)) > 9 or
         unsigned(value(3 downto 0)) > 9 then
         return false;
      end if;

      return (unsigned(value(19 downto 18)) < 2 or
              (unsigned(value(19 downto 18)) = 2 and
               unsigned(value(17 downto 14)) <= 3)) and
             unsigned(value(13 downto 11)) <= 5 and
             unsigned(value(6 downto 4)) <= 5;
   end function;

   function valid_bcd_time(value : std_logic_vector(41 downto 0)) return boolean is
      variable year_value  : integer;
      variable month_value : integer;
      variable day_value   : integer;
   begin
      if unsigned(value(41 downto 38)) > 9 or unsigned(value(37 downto 34)) > 9 or
         unsigned(value(32 downto 29)) > 9 or unsigned(value(26 downto 23)) > 9 or
         not valid_bcd_hms(value(19 downto 0)) then
         return false;
      end if;

      year_value  := bcd_to_integer(value(41 downto 34));
      month_value := bcd_to_integer(value(33 downto 29));
      day_value   := bcd_to_integer(value(28 downto 23));

      return month_value >= 1 and month_value <= 12 and
             day_value >= 1 and day_value <= days_in_month(year_value, month_value) and
             unsigned(value(22 downto 20)) <= 6;
   end function;

begin

   timestamp_out      <= std_logic_vector(timestamp_reg);
   initialization_done <= init_done_reg;

   saved_time_out(41 downto 34) <= integer_to_bcd(live_year, 8);
   saved_time_out(33 downto 29) <= integer_to_bcd(live_month, 5);
   saved_time_out(28 downto 23) <= integer_to_bcd(live_day, 6);
   saved_time_out(22 downto 20) <= std_logic_vector(to_unsigned(live_wday, 3));
   saved_time_out(19 downto 14) <= integer_to_bcd(live_hour, 6);
   saved_time_out(13 downto 7)  <= integer_to_bcd(live_min, 7);
   saved_time_out(6 downto 0)   <= integer_to_bcd(live_sec, 7);

   process (clk)
      variable source_time     : std_logic_vector(41 downto 0);
      variable elapsed         : unsigned(31 downto 0);
      variable source_hour     : integer range 0 to 23;
      variable source_min      : integer range 0 to 59;
      variable source_sec      : integer range 0 to 59;
   begin
      if rising_edge(clk) then
         case init_state is
            when WAIT_FOR_INITIALIZE =>
               init_done_reg  <= '0';
               second_divider <= 0;

               if initialize = '1' then
                  if valid_bcd_time(saved_time_in) then
                     source_time := saved_time_in;
                     if unsigned(timestamp_now) >= unsigned(timestamp_saved) then
                        elapsed := unsigned(timestamp_now) - unsigned(timestamp_saved);
                     else
                        -- A host clock rollback must not run the cartridge
                        -- calendar backwards or turn into an unsigned wrap.
                        elapsed := (others => '0');
                     end if;
                  else
                     -- Defensive last resort.  Integration is expected to
                     -- select validated footer or Pocket BCD data.  If neither
                     -- is valid, use the RTC power-on date without applying an
                     -- untrusted elapsed interval.
                     source_time := (others => '0');
                     source_time(33 downto 29) := "00001";  -- January
                     source_time(28 downto 23) := "000001"; -- day 1
                     source_time(22 downto 20) := "110";    -- Saturday
                     elapsed := (others => '0');
                  end if;

                  source_hour := bcd_to_integer(source_time(19 downto 14));
                  source_min  := bcd_to_integer(source_time(13 downto 7));
                  source_sec  := bcd_to_integer(source_time(6 downto 0));

                  work_year  <= bcd_to_integer(source_time(41 downto 34));
                  work_month <= bcd_to_integer(source_time(33 downto 29));
                  work_day   <= bcd_to_integer(source_time(28 downto 23));
                  work_wday  <= to_integer(unsigned(source_time(22 downto 20)));
                  work_hour  <= 0;
                  work_min   <= 0;
                  work_sec   <= 0;
                  source_hours_remaining   <= source_hour;
                  source_minutes_remaining <= source_min;
                  source_seconds_remaining <= source_sec;
                  offline_total_seconds    <= resize(elapsed, 33);
                  day_seconds_remaining    <= (others => '0');
                  hour_seconds_remaining   <= (others => '0');
                  minute_seconds_remaining <= (others => '0');

                  -- Keep the epoch in the same shadow transaction as the
                  -- calendar.  No consumer can observe a new timestamp paired
                  -- with the old/default calendar during catch-up.
                  work_timestamp <= unsigned(timestamp_now);
                  init_state      <= ADD_SOURCE_HOURS;
               end if;

            when ADD_SOURCE_HOURS =>
               -- Build saved time-of-day with constant additions instead of
               -- a combinational *3600/*60 datapath.  At most 23 additions
               -- are required before moving to the next independent phase.
               second_divider <= 0;
               if source_hours_remaining > 0 then
                  offline_total_seconds <= offline_total_seconds +
                                           to_unsigned(3600, 33);
                  source_hours_remaining <= source_hours_remaining - 1;
               else
                  init_state <= ADD_SOURCE_MINUTES;
               end if;

            when ADD_SOURCE_MINUTES =>
               second_divider <= 0;
               if source_minutes_remaining > 0 then
                  offline_total_seconds <= offline_total_seconds +
                                           to_unsigned(60, 33);
                  source_minutes_remaining <= source_minutes_remaining - 1;
               else
                  init_state <= ADD_SOURCE_SECONDS;
               end if;

            when ADD_SOURCE_SECONDS =>
               second_divider <= 0;
               offline_total_seconds <= offline_total_seconds +
                                        resize(to_unsigned(source_seconds_remaining, 6), 33);
               source_seconds_remaining <= 0;
               init_state <= LOAD_OFFLINE_DAYS;

            when LOAD_OFFLINE_DAYS =>
               -- This registered hand-off is the physical timing cut between
               -- initialization arithmetic and the day comparator/subtractor.
               second_divider        <= 0;
               day_seconds_remaining <= offline_total_seconds;
               init_state            <= APPLY_OFFLINE_DAYS;

            when APPLY_OFFLINE_DAYS =>
               -- Date catch-up occurs only in shadow registers.  No
               -- intermediate value is observable by the emulated cartridge.
               second_divider <= 0;
               if day_seconds_remaining >= SECONDS_PER_DAY_33 then
                  -- Register the comparison result before calendar arithmetic.
                  -- This prevents the 33-bit day comparator from sharing a
                  -- same-cycle path with month/year rollover logic.
                  init_state <= ADVANCE_OFFLINE_DAY;
               else
                  hour_seconds_remaining <= day_seconds_remaining(16 downto 0);
                  init_state <= APPLY_OFFLINE_HOURS;
               end if;

            when ADVANCE_OFFLINE_DAY =>
               second_divider <= 0;
               -- Date catch-up occurs only in shadow registers.  No
               -- intermediate value is observable by the emulated cartridge.
               if work_wday = 6 then work_wday <= 0;
               else work_wday <= work_wday + 1;
               end if;

               if work_day = days_in_month(work_year, work_month) then
                  work_day <= 1;
                  if work_month = 12 then
                     work_month <= 1;
                     if work_year = 99 then work_year <= 0;
                     else work_year <= work_year + 1;
                     end if;
                  else
                     work_month <= work_month + 1;
                  end if;
               else
                  work_day <= work_day + 1;
               end if;
               -- Keep the calendar update and 33-bit subtractor in separate
               -- cycles so catch-up closes at the 100.663296 MHz clock.
               init_state <= SUBTRACT_OFFLINE_DAY;

            when SUBTRACT_OFFLINE_DAY =>
               second_divider <= 0;
               day_seconds_remaining <= day_seconds_remaining - SECONDS_PER_DAY_33;
               init_state <= APPLY_OFFLINE_DAYS;

            when APPLY_OFFLINE_HOURS =>
               second_divider <= 0;
               if hour_seconds_remaining >= SECONDS_PER_HOUR_17 then
                  work_hour <= work_hour + 1;
                  init_state <= SUBTRACT_OFFLINE_HOUR;
               else
                  minute_seconds_remaining <= hour_seconds_remaining(11 downto 0);
                  init_state <= APPLY_OFFLINE_MINUTES;
               end if;

            when SUBTRACT_OFFLINE_HOUR =>
               second_divider <= 0;
               hour_seconds_remaining <= hour_seconds_remaining - SECONDS_PER_HOUR_17;
               init_state <= APPLY_OFFLINE_HOURS;

            when APPLY_OFFLINE_MINUTES =>
               second_divider <= 0;
               if minute_seconds_remaining >= SECONDS_PER_MINUTE_12 then
                  work_min <= work_min + 1;
                  init_state <= SUBTRACT_OFFLINE_MINUTE;
               else
                  -- The remainder is now in 0..59, so this conversion cannot
                  -- overflow the constrained seconds register.
                  work_sec <= to_integer(minute_seconds_remaining(5 downto 0));
                  init_state <= COMMIT_INITIALIZATION;
               end if;

            when SUBTRACT_OFFLINE_MINUTE =>
               second_divider <= 0;
               minute_seconds_remaining <= minute_seconds_remaining - SECONDS_PER_MINUTE_12;
               init_state <= APPLY_OFFLINE_MINUTES;

            when COMMIT_INITIALIZATION =>
               -- Calendar, epoch and ready flag become visible together.
               live_year    <= work_year;
               live_month   <= work_month;
               live_day     <= work_day;
               live_wday    <= work_wday;
               live_hour    <= work_hour;
               live_min     <= work_min;
               live_sec     <= work_sec;
               timestamp_reg <= work_timestamp;
               second_divider <= 0;
               init_done_reg <= '1';
               init_state    <= RUNNING;

            when RUNNING =>
               if game_reset = '1' then
                  -- S-3511 RESET command: reset calendar/time and status.
                  -- The host timestamp marker remains current so later
                  -- persisted catch-up starts from the reset calendar.
                  live_year  <= 0;
                  live_month <= 1;
                  live_day   <= 1;
                  live_wday  <= 0;
                  live_hour  <= 0;
                  live_min   <= 0;
                  live_sec   <= 0;
                  second_divider <= 0;
                  game_time_pending <= '0';
                  pending_time_only <= '0';
               elsif game_time_write = '1' and game_time_time_only = '1' and
                     valid_bcd_hms(game_time_in(19 downto 0)) then
                  -- Command 0x66 replaces only hour/minute/second.  Keep the
                  -- live date decoded in place so a write aligned with the
                  -- one-second terminal count cannot mix pre/post-tick dates.
                  pending_game_time(19 downto 0) <= game_time_in(19 downto 0);
                  pending_time_only <= '1';
                  game_time_pending <= '1';
                  second_divider <= 0;
               elsif game_time_write = '1' and game_time_time_only = '0' and
                     valid_bcd_time(game_time_in) then
                  -- Validate and capture first, then decode on the following
                  -- clock.  This removes validation + BCD conversion from one
                  -- long path while keeping the externally visible write atomic.
                  pending_game_time <= game_time_in;
                  pending_time_only <= '0';
                  game_time_pending <= '1';
                  second_divider <= 0;
               elsif game_time_pending = '1' then
                  -- A game write is an atomic calendar replacement.  Resetting
                  -- the fractional divider gives the newly written second a
                  -- full, deterministic duration.
                  if pending_time_only = '0' then
                     live_year  <= bcd_to_integer(pending_game_time(41 downto 34));
                     live_month <= bcd_to_integer(pending_game_time(33 downto 29));
                     live_day   <= bcd_to_integer(pending_game_time(28 downto 23));
                     live_wday  <= to_integer(unsigned(pending_game_time(22 downto 20)));
                  end if;
                  live_hour  <= bcd_to_integer(pending_game_time(19 downto 14));
                  live_min   <= bcd_to_integer(pending_game_time(13 downto 7));
                  live_sec   <= bcd_to_integer(pending_game_time(6 downto 0));
                  game_time_pending <= '0';
                  pending_time_only <= '0';
                  second_divider <= 0;
               elsif second_divider = CLK_FREQUENCY_HZ - 1 then
                  second_divider <= 0;
                  timestamp_reg  <= timestamp_reg + 1;

                  if live_sec < 59 then
                     live_sec <= live_sec + 1;
                  else
                     live_sec <= 0;
                     if live_min < 59 then
                        live_min <= live_min + 1;
                     else
                        live_min <= 0;
                        if live_hour < 23 then
                           live_hour <= live_hour + 1;
                        else
                           live_hour <= 0;
                           if live_wday = 6 then live_wday <= 0;
                           else live_wday <= live_wday + 1;
                           end if;

                           if live_day = days_in_month(live_year, live_month) then
                              live_day <= 1;
                              if live_month = 12 then
                                 live_month <= 1;
                                 if live_year = 99 then live_year <= 0;
                                 else live_year <= live_year + 1;
                                 end if;
                              else
                                 live_month <= live_month + 1;
                              end if;
                           else
                              live_day <= live_day + 1;
                           end if;
                        end if;
                     end if;
                  end if;
               else
                  second_divider <= second_divider + 1;
               end if;
         end case;
      end if;
   end process;

end architecture;

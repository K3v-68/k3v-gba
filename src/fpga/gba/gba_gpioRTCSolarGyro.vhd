library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

use work.pProc_bus_gba.all;
use work.pReg_savestates.all;

entity gba_gpioRTCSolarGyro is
   port 
   (
      clk100               : in     std_logic; 
      reset                : in     std_logic;
      GBA_on               : in     std_logic;
      
      savestate_bus        : inout  proc_bus_gb_type;
      
      GPIO_readEna         : in     std_logic;                     -- request pulse coming together with address
      GPIO_done            : out    std_logic := '0';              -- pulse for 1 clock cycle when read value in Din is valid
      GPIO_Din             : out    std_logic_vector(3 downto 0);  -- 
      GPIO_Dout            : in     std_logic_vector(3 downto 0);  --
      GPIO_writeEna        : in     std_logic;                     -- request pulse coming together with address, no response required
      GPIO_addr            : in     std_logic_vector(1 downto 0);  -- 0..2 for 0x80000C4..0x80000C8
   
      vblank_trigger       : in     std_logic;  
      RTC_timestampNew     : in     std_logic;                     -- new current timestamp from system
      RTC_timestampIn      : in     std_logic_vector(31 downto 0); -- timestamp in seconds, current time
      RTC_timestampSaved   : in     std_logic_vector(31 downto 0); -- timestamp in seconds, saved time
      RTC_savedtimeIn      : in     std_logic_vector(41 downto 0); -- time structure, loaded
      RTC_saveLoaded       : in     std_logic;                     -- must be 0 when loading new game, should go and stay 1 when RTC was loaded and values are valid
      RTC_timestampOut     : out    std_logic_vector(31 downto 0); -- timestamp to be saved
      RTC_savedtimeOut     : out    std_logic_vector(41 downto 0); -- time structure to be saved
      RTC_inuse            : out    std_logic := '0';              -- will indicate that RTC is in use and should be saved on next saving
      RTC_initDone         : out    std_logic := '0';              -- offline catch-up committed; safe to release the GBA
   
      dummy                : in     std_logic := '0'
   );
end entity;

architecture arch of gba_gpioRTCSolarGyro is

   type GPIOState is
   (
      IDLE,
      COMMANDSTATE,
      DATASTATE,
      READDATA
   );
   signal state : GPIOState := IDLE;
   
   signal retval    : std_logic_vector(3 downto 0) := (others => '0');
   signal selected  : std_logic_vector(3 downto 0) := (others => '0');
   signal enable    : std_logic := '0';
   signal command   : std_logic_vector(7 downto 0) := (others => '0');
   signal dataLen   : unsigned(2 downto 0) := (others => '0');
   signal bits      : unsigned(5 downto 0) := (others => '0'); -- 0..55 max (8*7)
   signal clockslow : unsigned(7 downto 0) := (others => '0');
   
   type t_data is array(0 to 6) of std_logic_vector(7 downto 0);
   signal data : t_data := (others => (others => '0'));
   
   signal bitcheck : integer range 0 to 55 := 0;
   
   -- RTC
   signal saveRTC          : std_logic := '0';
   signal saveRTC_timeonly : std_logic := '0';
   signal resetRTC_next    : std_logic := '0';
   
   signal saveCTL          : std_logic := '0';
   signal saveCTL_next     : std_logic := '0';
   signal CTLval           : std_logic_vector(7 downto 0) := x"40";
   
   signal buf_tm_year      : std_logic_vector(7 downto 0);
   signal buf_tm_mon       : std_logic_vector(4 downto 0);
   signal buf_tm_mday      : std_logic_vector(5 downto 0);
   signal buf_tm_wday      : std_logic_vector(2 downto 0);
   signal buf_tm_hour      : std_logic_vector(5 downto 0);
   signal buf_tm_min       : std_logic_vector(6 downto 0);
   signal buf_tm_sec       : std_logic_vector(6 downto 0);

   signal rtc_clock_timestamp        : std_logic_vector(31 downto 0) := (others => '0');
   signal rtc_clock_time             : std_logic_vector(41 downto 0) := (others => '0');
   signal rtc_game_time_registered   : std_logic_vector(41 downto 0) := (others => '0');
   signal rtc_game_write_registered  : std_logic := '0';
   signal rtc_game_timeonly_registered : std_logic := '0';
   signal rtc_read_hour              : std_logic_vector(7 downto 0);
   signal rtc_clock_init_done        : std_logic;

   -- Keep the serial-command decoder and the RTC validation/calendar logic on
   -- opposite sides of a real register boundary.  Without these attributes,
   -- Quartus can retime the RTC capture registers back through the GPIO shift
   -- buffer and recreate the original critical path.
   attribute preserve : boolean;
   attribute preserve of rtc_game_time_registered  : signal is true;
   attribute preserve of rtc_game_write_registered : signal is true;
   attribute preserve of rtc_game_timeonly_registered : signal is true;
   attribute dont_retime : boolean;
   attribute dont_retime of rtc_game_time_registered  : signal is true;
   attribute dont_retime of rtc_game_write_registered : signal is true;
   attribute dont_retime of rtc_game_timeonly_registered : signal is true;
   
   -- savestate
   signal SAVESTATE_GPIO          : std_logic_vector(29 downto 0);
   signal SAVESTATE_GPIO_BACK     : std_logic_vector(29 downto 0);
                                  
   signal SAVESTATE_GPIOBITS      : std_logic_vector(21 downto 16);
   signal SAVESTATE_GPIOBITS_BACK : std_logic_vector(21 downto 16);

   function bcd_hour_to_integer(value : std_logic_vector(5 downto 0)) return integer is
   begin
      return (to_integer(unsigned(value(5 downto 4))) * 10) +
             to_integer(unsigned(value(3 downto 0)));
   end function;

   function integer_to_bcd_hour(value : integer) return std_logic_vector is
      variable tens : integer range 0 to 2;
      variable ones : integer range 0 to 9;
   begin
      if value >= 20 then tens := 2; ones := value - 20;
      elsif value >= 10 then tens := 1; ones := value - 10;
      else tens := 0; ones := value;
      end if;
      return std_logic_vector(to_unsigned(tens, 2)) &
             std_logic_vector(to_unsigned(ones, 4));
   end function;

   function format_read_hour(value : std_logic_vector(5 downto 0);
                              mode_24 : std_logic) return std_logic_vector is
      variable hour_value : integer range 0 to 23;
      variable display_hour : integer range 0 to 11;
      variable result     : std_logic_vector(7 downto 0) := (others => '0');
   begin
      hour_value := bcd_hour_to_integer(value);
      if hour_value >= 12 then
         -- The S-3511A returns AM/PM on reads in both modes.  In 24-hour
         -- mode the bit is derived from the 00..23 value.
         result(7) := '1';
      end if;
      if mode_24 = '1' then
         result(5 downto 0) := value;
      else
         if hour_value >= 12 then
            display_hour := hour_value - 12;
         else
            display_hour := hour_value;
         end if;
         result(5 downto 0) := integer_to_bcd_hour(display_hour);
      end if;
      return result;
   end function;

   function format_written_hour(value : std_logic_vector(7 downto 0);
                                 mode_24 : std_logic) return std_logic_vector is
   begin
      if mode_24 = '1' then
         return value(5 downto 0);
      end if;

      -- The S-3511A represents 12-hour values as BCD 00..11 plus bit 7 as
      -- AM/PM (not 01..12).  Direct lookup also keeps this serial-write path
      -- out of integer multiply/add/compare logic.
      case value(5 downto 0) is
         when "000000" => if value(7) = '1' then return "010010"; else return "000000"; end if; -- 0 / 12
         when "000001" => if value(7) = '1' then return "010011"; else return "000001"; end if; -- 1 / 13
         when "000010" => if value(7) = '1' then return "010100"; else return "000010"; end if; -- 2 / 14
         when "000011" => if value(7) = '1' then return "010101"; else return "000011"; end if; -- 3 / 15
         when "000100" => if value(7) = '1' then return "010110"; else return "000100"; end if; -- 4 / 16
         when "000101" => if value(7) = '1' then return "010111"; else return "000101"; end if; -- 5 / 17
         when "000110" => if value(7) = '1' then return "011000"; else return "000110"; end if; -- 6 / 18
         when "000111" => if value(7) = '1' then return "011001"; else return "000111"; end if; -- 7 / 19
         when "001000" => if value(7) = '1' then return "100000"; else return "001000"; end if; -- 8 / 20
         when "001001" => if value(7) = '1' then return "100001"; else return "001001"; end if; -- 9 / 21
         when "010000" => if value(7) = '1' then return "100010"; else return "010000"; end if; -- 10 / 22
         when "010001" => if value(7) = '1' then return "100011"; else return "010001"; end if; -- 11 / 23
         when others   => return "111111"; -- rejected atomically by gba_rtc_clock
      end case;
   end function;
   
begin 

   iSAVESTATE_GPIO     : entity work.eProcReg_gba generic map (REG_SAVESTATE_GPIO)     port map (clk100, savestate_bus, SAVESTATE_GPIO_BACK,     SAVESTATE_GPIO);
   iSAVESTATE_GPIOBITS : entity work.eProcReg_gba generic map (REG_SAVESTATE_GPIOBITS) port map (clk100, savestate_bus, SAVESTATE_GPIOBITS_BACK, SAVESTATE_GPIOBITS);

   -- The synthesized PLL drives clk100 at exactly 100.663296 MHz.  Keep the
   -- frequency explicit here so the one-second enable is derived from the
   -- actual build configuration rather than the legacy signal name/comment.
   iRTCClock : entity work.gba_rtc_clock
   generic map
   (
      CLK_FREQUENCY_HZ => 100663296
   )
   port map
   (
      clk                 => clk100,
      initialize          => RTC_saveLoaded,
      timestamp_now       => RTC_timestampIn,
      timestamp_saved     => RTC_timestampSaved,
       saved_time_in       => RTC_savedtimeIn,
       game_time_write     => rtc_game_write_registered,
       game_time_time_only => rtc_game_timeonly_registered,
       game_reset          => resetRTC_next,
       game_time_in        => rtc_game_time_registered,
      timestamp_out       => rtc_clock_timestamp,
      saved_time_out      => rtc_clock_time,
      initialization_done => rtc_clock_init_done
   );

   rtc_read_hour <= format_read_hour(buf_tm_hour, CTLval(6));

   RTC_timestampOut <= rtc_clock_timestamp;
   RTC_savedtimeOut <= rtc_clock_time;
   RTC_initDone     <= rtc_clock_init_done;

   buf_tm_year <= rtc_clock_time(41 downto 34);
   buf_tm_mon  <= rtc_clock_time(33 downto 29);
   buf_tm_mday <= rtc_clock_time(28 downto 23);
   buf_tm_wday <= rtc_clock_time(22 downto 20);
   buf_tm_hour <= rtc_clock_time(19 downto 14);
   buf_tm_min  <= rtc_clock_time(13 downto 7);
   buf_tm_sec  <= rtc_clock_time(6 downto 0);

   SAVESTATE_GPIO_BACK( 7 downto  0) <= std_logic_vector(clockslow);
   SAVESTATE_GPIO_BACK(15 downto  8) <= command;
   SAVESTATE_GPIO_BACK(18 downto 16) <= std_logic_vector(dataLen);
   SAVESTATE_GPIO_BACK(19)           <= enable;
   SAVESTATE_GPIO_BACK(23 downto 20) <= retval;
   SAVESTATE_GPIO_BACK(27 downto 24) <= selected;
   SAVESTATE_GPIO_BACK(29 downto 28) <= std_logic_vector(to_unsigned(GPIOState'POS(state), 2));
   
   SAVESTATE_GPIOBITS_BACK <= std_logic_vector(bits);

   process (clk100)
      variable new_command : std_logic_vector(7 downto 0);
      variable final_data_byte : std_logic_vector(7 downto 0);
      variable captured_game_time : std_logic_vector(41 downto 0);
   begin
      if rising_edge(clk100) then
      
         -- overwritten later
         GPIO_done    <= '0';
         saveCTL_next <= '0';
         resetRTC_next <= '0';
         rtc_game_write_registered <= '0';
         
         if (saveCTL_next = '1') then
            -- Only the four documented status bits are writable.  POWER and
            -- reserved bits always read as zero in this virtual RTC.
            CTLval <= data(0) and x"6A";
         end if;
         
         if (dataLen > 0) then
            bitcheck <= (8 * to_integer(dataLen)) - 1; 
         else
            bitcheck <= 0;
         end if;
      
         if (reset = '1') then

            -- The legacy save-state payload does not contain data(0..6) or
            -- CTLval.  Resuming a saved mid-byte FSM would therefore combine
            -- old control state with unrelated transfer bytes.  Preserve the
            -- externally visible GPIO configuration, but abort the serial
            -- transaction cleanly.  The wall clock itself is intentionally
            -- not reset or rewound by a gameplay save-state load.
            clockslow <= (others => '0');
            command   <= (others => '0');
            dataLen   <= (others => '0');
            enable    <= SAVESTATE_GPIO(19);
            retval    <= SAVESTATE_GPIO(23 downto 20);
            selected  <= SAVESTATE_GPIO(27 downto 24);
            state     <= IDLE;

            bits      <= (others => '0');

            saveRTC   <= '0';
            saveRTC_timeonly <= '0';
            saveCTL   <= '0';
            rtc_game_time_registered <= (others => '0');
            rtc_game_timeonly_registered <= '0';
            
            RTC_inuse <= RTC_saveLoaded;
            
         elsif (gba_on = '1') then
         
            if (RTC_saveLoaded = '1') then
               RTC_inuse <= '1';
            end if;
      
            if (GPIO_readEna = '1') then
            
               GPIO_done <= '1';
               GPIO_Din  <= x"0";
               
               case GPIO_addr is
                  when "10" => -- 0x80000c8
                     GPIO_Din <= "000" & enable;
                     
                  when "01" => -- 0x80000c6
                     GPIO_Din <= selected;
               
                  when "00" => -- 0x80000c4
                     if (enable = '1') then
                        
                        -- RTC
                        if (selected(2) = '1') then
                           GPIO_Din <= retval;
                        end if;
                        
                     end if;
               
                  when others => null;
               end case;
            end if;
         
      
            if (GPIO_writeEna = '1') then
               
               case GPIO_addr is
                  when "10" => -- 0x80000c8
                     enable <= GPIO_Dout(0);
                     
                  when "01" => -- 0x80000c6
                     selected <= GPIO_Dout;
               
                  when "00" => -- 0x80000c4
               
                     -- RTC
                     --if (selected(2) = '1') then -- don't check for clock as Sennen Kazoku doesn't handle it "correct"
                     
                        if (state = IDLE and retval = x"1" and GPIO_Dout = x"5") then
                        
                           state   <= COMMANDSTATE;
                           bits    <= (others => '0');
                           command <= (others => '0');
                           
                           RTC_inuse <= '1';
                              
                        elsif (retval(0) = '0' and GPIO_Dout(0) = '1') then -- bit transfer

                           retval <= GPIO_Dout;
      
                           case (state) is

                              when COMMANDSTATE =>
                                 new_command := command;                             
                                 new_command(7 - to_integer(bits)) := command(7 - to_integer(bits)) or GPIO_Dout(1);
                                 command <= new_command;
                                 
                                 bits <= bits + 1;
      
                                 if (bits = 7) then -- would be 8 next step
      
                                    bits <= (others => '0');
      
                                    case (new_command) is

                                       when x"60" | x"61" => -- reset (R/W bit is ignored)
                                          state <= IDLE;
                                          CTLval <= x"00";
                                          resetRTC_next <= '1';
      
                                       when x"62" => --control state
                                          state   <= READDATA;
                                          dataLen <= to_unsigned(1, dataLen'length);
                                          saveCTL <= '1';
      
                                       when x"63" =>
                                          dataLen <= to_unsigned(1, dataLen'length);
                                          data(0) <= CTLval;
                                          state   <= DATASTATE;
                                               
                                       when x"64" =>
                                          state   <= READDATA;
                                          dataLen <= to_unsigned(7, dataLen'length);
                                          saveRTC <= '1';
                                          saveRTC_timeonly <= '0';
      
                                       when x"65" =>
                                          dataLen <= to_unsigned(7, dataLen'length);
                                          data(0) <= buf_tm_year;
                                          data(1) <= "000" & buf_tm_mon;
                                          data(2) <= "00" & buf_tm_mday;
                                          data(3) <= "00000" & buf_tm_wday;
                                          data(4) <= rtc_read_hour;
                                          data(5) <= '0' & buf_tm_min;
                                          data(6) <= '0' & buf_tm_sec;
                                          state   <= DATASTATE;

                                       when x"66" =>
                                          state   <= READDATA;
                                          dataLen <= to_unsigned(3, dataLen'length);
                                          saveRTC <= '1';
                                          saveRTC_timeonly <= '1';

                                       when x"67" => 
                                          dataLen <= to_unsigned(3, dataLen'length);
                                          data(0) <= rtc_read_hour;
                                          data(1) <= '0' & buf_tm_min;
                                          data(2) <= '0' & buf_tm_sec;
                                          state   <= DATASTATE;

                                       when others => state <= IDLE;
                                          
                                    end case;
                                    
                                 end if;
      
                              when DATASTATE =>
                                 if (selected(1) = '1') then

                                 elsif (selected(2) = '1') then
                                 
                                    retval(1) <= data(to_integer(bits) / 8)(to_integer(bits(2 downto 0)));
                                    bits <= bits + 1;
      
                                    if (bits = bitcheck) then
                                       bits  <= (others => '0');
                                       state <= IDLE;
                                    end if;
                                    
                                 end if;
      
                              when READDATA =>
                                 if (selected(1) = '1') then
                                 
                                    data(to_integer(bits) / 8) <= GPIO_Dout(1) & data(to_integer(bits) / 8)(7 downto 1);
                                    bits <= bits + 1;
      
                                    if (bits = bitcheck) then
                                       bits  <= (others => '0');
                                       state <= IDLE;
                                       if saveRTC = '1' then
                                          -- Capture on the same edge as the
                                          -- final serial bit.  This preserves
                                          -- the original RTC write/tick
                                          -- priority while keeping the shift
                                          -- decoder behind a protected
                                          -- register boundary.
                                          final_data_byte := GPIO_Dout(1) &
                                             data(to_integer(bits) / 8)(7 downto 1);
                                          captured_game_time := (others => '0');
                                          if saveRTC_timeonly = '1' then
                                             captured_game_time(19 downto 14) := format_written_hour(data(0), CTLval(6));
                                             captured_game_time(13 downto 7)  := data(1)(6 downto 0);
                                          else
                                             captured_game_time(41 downto 34) := data(0);
                                             captured_game_time(33 downto 29) := data(1)(4 downto 0);
                                             captured_game_time(28 downto 23) := data(2)(5 downto 0);
                                             captured_game_time(22 downto 20) := data(3)(2 downto 0);
                                             captured_game_time(19 downto 14) := format_written_hour(data(4), CTLval(6));
                                             captured_game_time(13 downto 7)  := data(5)(6 downto 0);
                                          end if;
                                          captured_game_time(6 downto 0) := final_data_byte(6 downto 0);
                                          rtc_game_time_registered <= captured_game_time;
                                          rtc_game_timeonly_registered <= saveRTC_timeonly;
                                          rtc_game_write_registered <= '1';
                                       end if;
                                       saveCTL_next <= saveCTL;
                                       saveRTC      <= '0';
                                       saveRTC_timeonly <= '0';
                                       saveCTL      <= '0';
                                    end if;
                                    
                                 end if;
                                 
                              when others => null;
                                 
                           end case;
                        
                        else
                        
                           retval <= GPIO_Dout;
                              
                        end if;
                     --end if;
                  
                  when others => null;
               end case;
               
            end if;
            
         end if; 
         
      end if;
   end process;
   
end architecture;






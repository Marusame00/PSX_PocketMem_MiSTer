library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all; 

-- Memory card device on the controller/memory card SIO port.
--
-- isPocketStation = '0' : original Sony card protocol (81h/52h/57h), unchanged.
-- isPocketStation = '1' : PocketStation BU command set on top of the same
--                         128KB image. Command/response bytes follow the
--                         no$psx "Pocketstation BU command summary".
--                         FUNC 00h (date/time) is served from rtc_in.
--                         FUNC 01h/02h/03h/80h+ are accepted with the
--                         documented lengths but return zero data and ignore
--                         writes (no PocketStation kernel/flash is emulated
--                         here; minigame execution is done by PocketStation_MiSTer).
--
-- rtc_in: MiSTer framework RTC bus (MSM6242B layout, BCD):
--   [7:0] sec  [15:8] min  [23:16] hour  [31:24] day  [39:32] month
--   [47:40] year (20xx)  [50:48] day of week 0..6

entity joypad_mem is
   port 
   (
      clk1x                : in  std_logic;
      clk2x                : in  std_logic;
      clk2xIndex           : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;
      
      memcard_available    : in  std_logic;
      mem_request          : out std_logic := '0';
      mem_BURSTCNT         : out std_logic_vector(7 downto 0) := (others => '0'); 
      mem_ADDR             : out std_logic_vector(19 downto 0) := (others => '0');                       
      mem_DIN              : out std_logic_vector(63 downto 0) := (others => '0');
      mem_BE               : out std_logic_vector(7 downto 0) := (others => '0'); 
      mem_WE               : out std_logic := '0';
      mem_RD               : out std_logic := '0';
      mem_ack              : in  std_logic;
      mem_DOUT             : in  std_logic_vector(63 downto 0);
      mem_DOUT_READY       : in  std_logic;
      
      selected             : in  std_logic;
      actionNext           : in  std_logic := '0';
      transmitting         : in  std_logic := '0';
      transmitValue        : in  std_logic_vector(7 downto 0);
      
      isPocketStation      : in  std_logic := '0';
      rtc_in               : in  std_logic_vector(64 downto 0) := (others => '0');
      
      isActive             : out std_logic := '0';
      slotIdle             : in  std_logic;
      
      receiveValid         : out std_logic;
      receiveBuffer        : out std_logic_vector(7 downto 0);
      ack                  : out std_logic
   );
end entity;

architecture arch of joypad_mem is
   
   type tState is
   (
      IDLE,
      COMMAND,
      
      READID1,
      READID2,
      READADDR1,
      READADDR2,
      READACK1,
      READACK2,
      READCONFADDR1,
      READCONFADDR2,
      READDATA,
      READCHECKSUM,
      READEND,

      WRITEID1,
      WRITEID2,
      WRITEADDR1,
      WRITEADDR2,
      WRITEDATA,
      WRITECHECKSUM,
      WRITEACK1,
      WRITEACK2,
      WRITEEND,

      -- PocketStation only
      GETID1,
      GETID2,
      GETID3,
      GETID4,
      GETID5,
      GETID6,
      GETID7,
      GETID8,
      PS50_VAL,
      PS58_LEN,
      PS58_1,
      PS58_2,
      PS59_LEN,
      PS59_DIH,
      PS59_DIL,
      PS59_P0,
      PS59_P1,
      PS59_P2,
      PS59_P3,
      PS5A_LEN,
      PS5A_DATA,
      PS5D_LEN,
      PS5D_B16,
      PS5D_B8,
      PS5D_B0,
      PS5E_LEN,
      PS5E_B1,
      PS5E_B3,
      PS5E_B2,
      PS5F_LEN,
      PS5F_B0,
      PSBC_FUNC,
      PSBC_LEN1,
      PSBC_PARAM,
      PSBC_LEN2,
      PSBC_DATA,
      PSBC_END
   );
   signal state         : tState := IDLE;
         
   signal flags         : std_logic_vector(7 downto 0);
  
   signal lastData      : std_logic_vector(7 downto 0);
   signal cardAddr      : std_logic_vector(9 downto 0);
   signal addrCounter   : unsigned(6 downto 0);
   
   signal checksum      : std_logic_vector(7 downto 0);
  
   -- memory
   signal mem_addrA     : std_logic_vector(6 downto 0) := (others => '0');
   signal mem_DataInA   : std_logic_vector(7 downto 0);
   signal mem_wrenA     : std_logic := '0';
   signal mem_DataOutA  : std_logic_vector(7 downto 0);
  
   signal mem_addrB     : std_logic_vector(3 downto 0) := (others => '0');
   signal mem_DataInB   : std_logic_vector(63 downto 0);
   signal mem_wrenB     : std_logic := '0';
   signal mem_DataOutB  : std_logic_vector(63 downto 0);

   type tMemState is
   (
      MEMIDLE,
      MEMCPUWRITE_READDATA,
      MEMCPUWRITE_REQWRITE,
      MEMCPUWRITE_WAITACK,
      MEMCPUREAD_REQDATA,
      MEMCPUREAD_WAITACK,
      MEMCPUREAD_READDATA
   );
   signal memstate      : tMemState := MEMIDLE;

   signal triggerRead   : std_logic := '0';
   signal triggerWrite  : std_logic := '0';
   
   signal cardAddr2X    : std_logic_vector(9 downto 0);
   signal readCnt2X     : std_logic_vector(3 downto 0);

   -- PocketStation state
   signal dirIndex      : std_logic_vector(15 downto 0) := (others => '0');
   signal comFlags      : std_logic_vector(15 downto 0) := (others => '0');
   signal execParam     : std_logic_vector(31 downto 0) := (others => '0');
   signal dirNewHi      : std_logic_vector(7 downto 0) := (others => '0');
   signal psFunc        : std_logic_vector(7 downto 0) := (others => '0');
   signal psDirIn       : std_logic := '0';   -- '1' = 5Ch (PSX to PocketStation)
   signal psLen1        : unsigned(7 downto 0) := (others => '0');
   signal psLen2        : unsigned(7 downto 0) := (others => '0');
   signal psCnt         : unsigned(7 downto 0) := (others => '0');
   signal psWrOk        : std_logic := '0';   -- write checksum matched
   signal wrProtect     : std_logic;   -- ComFlags.10 and sector 16..55

   signal rtcSec        : std_logic_vector(7 downto 0);
   signal rtcMin        : std_logic_vector(7 downto 0);
   signal rtcHour       : std_logic_vector(7 downto 0);
   signal rtcDay        : std_logic_vector(7 downto 0);
   signal rtcMonth      : std_logic_vector(7 downto 0);
   signal rtcYear       : std_logic_vector(7 downto 0);
   signal rtcDow        : std_logic_vector(7 downto 0);

   signal ps5aByte      : std_logic_vector(7 downto 0) := (others => '0');
   signal psFuncByte    : std_logic_vector(7 downto 0) := (others => '0');

begin 

   rtcSec   <= rtc_in( 7 downto  0);
   rtcMin   <= rtc_in(15 downto  8);
   rtcHour  <= rtc_in(23 downto 16);
   rtcDay   <= rtc_in(31 downto 24);
   rtcMonth <= rtc_in(39 downto 32);
   rtcYear  <= rtc_in(47 downto 40);
   rtcDow   <= std_logic_vector(unsigned("00000" & rtc_in(50 downto 48)) + 1);

   wrProtect <= comFlags(10) when (unsigned(cardAddr) >= 16 and unsigned(cardAddr) <= 55) else '0';

   -- 5Ah payload, index 0..17 (the 12h length byte is sent by PS5A_LEN)
   process (psCnt, dirIndex, comFlags, rtcSec, rtcMin, rtcHour, rtcDay, rtcMonth, rtcYear, rtcDow)
   begin
      case to_integer(psCnt) is
         when 0  => ps5aByte <= dirIndex(15 downto 8);
         when 1  => ps5aByte <= dirIndex(7 downto 0);
         when 2  => ps5aByte <= "0000000" & comFlags(0);
         when 3  => ps5aByte <= "0000000" & comFlags(1);
         when 4  => ps5aByte <= "0000000" & comFlags(3);
         when 5  => ps5aByte <= "0000000" & comFlags(2);
         when 10 => ps5aByte <= rtcDay;
         when 11 => ps5aByte <= rtcMonth;
         when 12 => ps5aByte <= rtcYear;
         when 13 => ps5aByte <= x"20";
         when 14 => ps5aByte <= rtcSec;
         when 15 => ps5aByte <= rtcMin;
         when 16 => ps5aByte <= rtcHour;
         when 17 => ps5aByte <= rtcDow;
         when others => ps5aByte <= x"00"; -- F_SN, not emulated
      end case;
   end process;

   -- 5Bh/5Ch FUNC 00h payload (date/time), 8 bytes. Other FUNCs read as zero.
   process (psFunc, psCnt, rtcDay, rtcMonth, rtcYear, rtcSec, rtcMin, rtcHour, rtcDow)
   begin
      psFuncByte <= x"00";
      if (psFunc = x"00") then
         case to_integer(psCnt) is
            when 0 => psFuncByte <= rtcDay;
            when 1 => psFuncByte <= rtcMonth;
            when 2 => psFuncByte <= rtcYear;
            when 3 => psFuncByte <= x"20";
            when 4 => psFuncByte <= rtcSec;
            when 5 => psFuncByte <= rtcMin;
            when 6 => psFuncByte <= rtcHour;
            when 7 => psFuncByte <= rtcDow;
            when others => psFuncByte <= x"00";
         end case;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
      
         receiveValid   <= '0';
         receiveBuffer  <= x"00";
         
         ack            <= '0';
         
         mem_wrenA      <= '0';
         
         triggerRead    <= '0';
         triggerWrite   <= '0';

         if (reset = '1' or memcard_available = '0') then
         
            state      <= IDLE;
            isActive   <= '0';
            flags      <= x"08";
            if (reset = '1') then
               dirIndex <= (others => '0');
               comFlags <= (others => '0');
            end if;

         elsif (ce = '1') then
         
            if (selected = '0') then
               isActive <= '0';
               state    <= IDLE;
            end if;
         
            if (actionNext = '1' and transmitting = '1') then
               if (selected = '1' and memcard_available = '1') then
                  if (isActive = '0' and slotIdle = '1') then
                     if (state = IDLE and transmitValue = x"81") then
                        state           <= COMMAND;
                        isActive        <= '1';
                        ack             <= '1'; 
                        receiveValid    <= '1';
                        receiveBuffer   <= x"FF";
                     end if;
                  elsif (isActive = '1') then
                     lastData <= transmitValue;
                     case (state) is
                        when IDLE => 
                           if (transmitValue = x"81") then
                              state           <= COMMAND;
                              isActive        <= '1';
                              ack             <= '1';
                              receiveValid    <= '1';
                              receiveBuffer   <= x"FF";
                           end if;
                           
                        when COMMAND => 
                           receiveBuffer <= flags;
                           receiveValid  <= '1';
                           state         <= IDLE;
                           if (transmitValue = x"52") then
                              state         <= READID1;
                              ack           <= '1';
                           elsif (transmitValue = x"57") then
                              state         <= WRITEID1;
                              ack           <= '1';
                           elsif (isPocketStation = '1') then
                              case transmitValue is
                                 when x"53" => state <= GETID1;    ack <= '1';
                                 when x"50" => state <= PS50_VAL;  ack <= '1';
                                 when x"58" => state <= PS58_LEN;  ack <= '1';
                                 when x"59" => state <= PS59_LEN;  ack <= '1';
                                 when x"5A" => state <= PS5A_LEN;  ack <= '1';
                                 when x"5B" => state <= PSBC_FUNC; ack <= '1'; psDirIn <= '0';
                                 when x"5C" => state <= PSBC_FUNC; ack <= '1'; psDirIn <= '1';
                                 when x"5D" => state <= PS5D_LEN;  ack <= '1';
                                 when x"5E" => state <= PS5E_LEN;  ack <= '1';
                                 when x"5F" => state <= PS5F_LEN;  ack <= '1';
                                 when others => null;
                              end case;
                           end if;
                        
                        -- reading (standard)
                        when READID1       => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5A";                           state <= READID2;                     
                        when READID2       => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5D";                           state <= READADDR1;                     
                        when READADDR1     => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00";                           state <= READADDR2;      cardAddr(9 downto 8) <= transmitValue(1 downto 0);
                        when READADDR2     =>
                           ack           <= '1';
                           receiveValid  <= '1';
                           if (isPocketStation = '1') then
                              receiveBuffer <= x"00";
                           else
                              receiveBuffer <= lastData;
                           end if;
                           state <= READACK1;
                           cardAddr(7 downto 0) <= transmitValue; 
                        when READACK1      => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5C";                           state <= READACK2;       triggerRead <= '1';
                        when READACK2      => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5D";                           state <= READCONFADDR1;
                        when READCONFADDR1 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= "000000" & cardAddr(9 downto 8); state <= READCONFADDR2;  
                        when READCONFADDR2 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= cardAddr(7 downto 0);            state <= READDATA;       
                           addrCounter <= (others => '0');
                           checksum    <= ("000000" & cardAddr(9 downto 8)) xor cardAddr(7 downto 0);
                           mem_addrA   <= "0000000";
                        
                        when READDATA      =>
                           ack           <= '1'; 
                           receiveBuffer <= mem_DataOutA;
                           receiveValid  <= '1';
                           checksum      <= checksum xor mem_DataOutA;
                           mem_addrA     <= std_logic_vector(unsigned(mem_addrA) + 1);
                           if (addrCounter = 127) then
                              state      <= READCHECKSUM;
                           else
                              addrCounter <= addrCounter + 1;
                           end if;
                        
                        when READCHECKSUM  => ack <= '1'; receiveValid <= '1'; receiveBuffer <= checksum; state <= READEND;
                        when READEND       => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"47";    state <= IDLE;
                        
                        -- writing (standard and PocketStation)
                        when WRITEID1      => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5A";    state <= WRITEID2;
                        when WRITEID2      => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5D";    state <= WRITEADDR1;
                        when WRITEADDR1    => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00";    state <= WRITEADDR2; cardAddr(9 downto 8) <= transmitValue(1 downto 0);
                        when WRITEADDR2    =>
                           ack           <= '1';
                           receiveValid  <= '1';
                           if (isPocketStation = '1') then
                              receiveBuffer <= x"00";
                           else
                              receiveBuffer <= lastData;
                           end if;
                           state         <= WRITEDATA;
                           cardAddr(7 downto 0) <= transmitValue;
                           addrCounter   <= (others => '0');
                           checksum      <= ("000000" & cardAddr(9 downto 8)) xor transmitValue;
                        
                        when WRITEDATA     =>
                           flags(3)      <= '0';
                           ack           <= '1'; 
                           receiveValid  <= '1';
                           if (isPocketStation = '1') then
                              receiveBuffer <= x"00";
                           else
                              receiveBuffer <= lastData;
                           end if;
                           mem_wrenA     <= '1';
                           mem_DataInA   <= transmitValue;
                           mem_addrA     <= std_logic_vector(addrCounter);
                           checksum      <= checksum xor transmitValue;
                           if (addrCounter = 127) then
                              state        <= WRITECHECKSUM;
                              -- standard cards commit here; PocketStation commits
                              -- in WRITECHECKSUM only if the checksum matches
                              if (isPocketStation = '0') then
                                 triggerWrite <= '1';
                              end if;
                           else
                              addrCounter <= addrCounter + 1;
                           end if;
                        
                        when WRITECHECKSUM =>
                           ack <= '1'; receiveValid <= '1'; receiveBuffer <= checksum; state <= WRITEACK1;
                           if (transmitValue = checksum) then psWrOk <= '1'; else psWrOk <= '0'; end if;
                           if (isPocketStation = '1' and transmitValue = checksum and wrProtect = '0') then
                              triggerWrite <= '1';
                           end if;
                        when WRITEACK1     => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5C";    state <= WRITEACK2; 
                        when WRITEACK2     => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5D";    state <= WRITEEND;                  
                        when WRITEEND      =>
                           ack           <= '0';
                           receiveValid  <= '1';
                           receiveBuffer <= x"47";
                           if (isPocketStation = '1') then
                              if (wrProtect = '1') then
                                 receiveBuffer <= x"FE";
                              elsif (psWrOk = '0') then
                                 receiveBuffer <= x"4E";
                              end if;
                           end if;
                           state <= IDLE;

                        -- PocketStation: Get ID (53h), same values as Sony cards
                        when GETID1 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5A"; state <= GETID2;
                        when GETID2 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5D"; state <= GETID3;
                        when GETID3 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5C"; state <= GETID4;
                        when GETID4 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"5D"; state <= GETID5;
                        when GETID5 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"04"; state <= GETID6;
                        when GETID6 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00"; state <= GETID7;
                        when GETID7 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00"; state <= GETID8;
                        when GETID8 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"80"; state <= IDLE;

                        -- 50h: VAL -> length of following data (0)
                        when PS50_VAL => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00"; state <= IDLE;

                        -- 58h: ID/version: 02h, 01h, 01h
                        when PS58_LEN => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"02"; state <= PS58_1;
                        when PS58_1   => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"01"; state <= PS58_2;
                        when PS58_2   => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"01"; state <= IDLE;

                        -- 59h: prepare file execution. dir_index 0000h..000Fh is accepted;
                        -- FFFFh is read-only; other values are ignored (FFFEh not emulated).
                        when PS59_LEN => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"06"; state <= PS59_DIH;
                        when PS59_DIH => ack <= '1'; receiveValid <= '1'; receiveBuffer <= dirIndex(15 downto 8); state <= PS59_DIL; dirNewHi <= transmitValue;
                        when PS59_DIL =>
                           ack           <= '1';
                           receiveValid  <= '1';
                           receiveBuffer <= dirIndex(7 downto 0);
                           state         <= PS59_P0;
                           if (dirNewHi = x"00" and transmitValue(7 downto 4) = "0000") then
                              dirIndex <= x"00" & transmitValue;
                           end if;
                        when PS59_P0 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00"; state <= PS59_P1; execParam(7 downto 0)   <= transmitValue;
                        when PS59_P1 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00"; state <= PS59_P2; execParam(15 downto 8)  <= transmitValue;
                        when PS59_P2 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00"; state <= PS59_P3; execParam(23 downto 16) <= transmitValue;
                        when PS59_P3 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00"; state <= IDLE;   execParam(31 downto 24) <= transmitValue;

                        -- 5Ah: 12h length, then 18 bytes of status
                        when PS5A_LEN => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"12"; psCnt <= (others => '0'); state <= PS5A_DATA;
                        when PS5A_DATA =>
                           ack           <= '1';
                           receiveValid  <= '1';
                           receiveBuffer <= ps5aByte;
                           if (psCnt = 17) then
                              state <= IDLE;
                           else
                              psCnt <= psCnt + 1;
                           end if;

                        -- 5Dh: download notification, value bytes 16-23, 8-15, 0-7
                        when PS5D_LEN => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"03"; state <= PS5D_B16;
                        when PS5D_B16 => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00"; state <= PS5D_B8;
                        when PS5D_B8  =>
                           ack           <= '1';
                           receiveValid  <= '1';
                           receiveBuffer <= x"00";
                           state         <= PS5D_B0;
                           if (transmitValue = x"00") then
                              comFlags(10) <= '1';
                           else
                              comFlags(10) <= '0';
                           end if;
                        when PS5D_B0  => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00"; state <= IDLE;

                        -- 5Eh: new ComFlags.bit1, bit3, bit2 (old value returned)
                        when PS5E_LEN => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"03"; state <= PS5E_B1;
                        when PS5E_B1  => ack <= '1'; receiveValid <= '1'; receiveBuffer <= "0000000" & comFlags(1); state <= PS5E_B3; comFlags(1) <= transmitValue(0);
                        when PS5E_B3  => ack <= '1'; receiveValid <= '1'; receiveBuffer <= "0000000" & comFlags(3); state <= PS5E_B2; comFlags(3) <= transmitValue(0);
                        when PS5E_B2  => ack <= '1'; receiveValid <= '1'; receiveBuffer <= "0000000" & comFlags(2); state <= IDLE;    comFlags(2) <= transmitValue(0);

                        -- 5Fh: new ComFlags.bit0 (old value returned)
                        when PS5F_LEN => ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"01"; state <= PS5F_B0;
                        when PS5F_B0  => ack <= '1'; receiveValid <= '1'; receiveBuffer <= "0000000" & comFlags(0); state <= IDLE; comFlags(0) <= transmitValue(0);

                        -- 5Bh / 5Ch: FUNC, LEN1 params, LEN2 data, FFh end
                        when PSBC_FUNC =>
                           ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"FF";
                           psFunc <= transmitValue;
                           state  <= PSBC_LEN1;
                        when PSBC_LEN1 =>
                           ack <= '1'; receiveValid <= '1';
                           psCnt <= (others => '0');
                           -- LEN1 and LEN2 from FUNC (LEN2 of FUNC 01h comes from its 5th parameter)
                           case psFunc is
                              when x"00" => receiveBuffer <= x"00"; psLen1 <= x"00"; psLen2 <= x"08";
                              when x"01" => receiveBuffer <= x"05"; psLen1 <= x"05"; psLen2 <= x"00";
                              when x"02" => receiveBuffer <= x"00"; psLen1 <= x"00"; psLen2 <= x"08";
                              when x"03" => receiveBuffer <= x"04"; psLen1 <= x"04"; psLen2 <= x"00";
                              when others => receiveBuffer <= x"00"; psLen1 <= x"00"; psLen2 <= x"00";
                           end case;
                           case psFunc is
                              when x"01" | x"03" => state <= PSBC_PARAM;   -- parameter bytes follow
                              when others        => state <= PSBC_LEN2;    -- no parameters
                           end case;
                        when PSBC_PARAM =>
                           ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"00";
                           if (psCnt = 4 and psFunc = x"01") then
                              if (unsigned(transmitValue) > 128) then
                                 psLen2 <= x"80";
                              else
                                 psLen2 <= unsigned(transmitValue);
                              end if;
                           end if;
                           if (psCnt = psLen1 - 1) then
                              state <= PSBC_LEN2;
                           else
                              psCnt <= psCnt + 1;
                           end if;
                        when PSBC_LEN2 =>
                           ack <= '1'; receiveValid <= '1'; receiveBuffer <= std_logic_vector(psLen2);
                           psCnt <= (others => '0');
                           if (psLen2 = 0) then
                              state <= PSBC_END;
                           else
                              state <= PSBC_DATA;
                           end if;
                        when PSBC_DATA =>
                           ack <= '1'; receiveValid <= '1';
                           if (psDirIn = '0') then
                              receiveBuffer <= psFuncByte;
                           else
                              receiveBuffer <= x"00";
                           end if;
                           if (psCnt = psLen2 - 1) then
                              state <= PSBC_END;
                           else
                              psCnt <= psCnt + 1;
                           end if;
                        when PSBC_END =>
                           ack <= '1'; receiveValid <= '1'; receiveBuffer <= x"FF"; state <= IDLE;
                     end case;
                  end if;
               end if; -- joy select
               
            end if; -- transmit
            
         end if; -- ce
      end if; -- clock
   end process;
   
   iramSectorBuffer: entity work.dpram_dif
   generic map 
   ( 
      addr_width_a  => 7,
      data_width_a  => 8,
      addr_width_b  => 4,
      data_width_b  => 64
   )
   port map
   (
      clock_a     => clk1x,
      address_a   => mem_addrA,
      data_a      => mem_DataInA,
      wren_a      => mem_wrenA,
      q_a         => mem_DataOutA,
      
      clock_b     => clk2x,
      address_b   => mem_addrB,
      data_b      => mem_DataInB,
      wren_b      => mem_wrenB,
      q_b         => mem_DataOutB
   );
   
   
   process (clk2x)
   begin
      if rising_edge(clk2x) then
      
         mem_wrenB <= '0';
      
         if (reset = '1') then

            memstate    <= MEMIDLE;
            mem_request <= '0';

         else
            
            case (memstate) is
            
               when MEMIDLE =>
                  if (triggerWrite = '1') then
                     memstate   <= MEMCPUWRITE_READDATA;
                     mem_addrB  <= (others => '0');
                     cardAddr2X <= cardAddr;
                  elsif (triggerRead = '1') then
                     memstate   <= MEMCPUREAD_REQDATA;
                     readCnt2X  <= (others => '0');
                     cardAddr2X <= cardAddr;
                  end if;
            
               -- write from CPU to DDR3
               when MEMCPUWRITE_READDATA =>
                  memstate <= MEMCPUWRITE_REQWRITE;
            
               when MEMCPUWRITE_REQWRITE =>
                  memstate     <= MEMCPUWRITE_WAITACK;
                  mem_request  <= '1';
                  mem_BURSTCNT <= x"01";
                  mem_ADDR     <= "000" & cardAddr2X & mem_addrB & "000";
                  mem_DIN      <= mem_DataOutB;
                  mem_BE       <= x"FF";
                  mem_WE       <= '1';
                  mem_RD       <= '0';
                  
               when MEMCPUWRITE_WAITACK =>
                  if (mem_ack = '1') then
                     mem_request <= '0';
                     if (unsigned(mem_addrB) = 15) then
                        memstate    <= MEMIDLE;
                        mem_WE      <= '0';
                        mem_RD      <= '0';
                     else
                        mem_addrB <= std_logic_vector(unsigned(mem_addrB) + 1);
                        memstate  <= MEMCPUWRITE_READDATA;
                     end if;
                  end if;
                  
               -- read from DDR3 to CPU
               when MEMCPUREAD_REQDATA =>
                  memstate     <= MEMCPUREAD_WAITACK;
                  mem_request  <= '1';
                  mem_BURSTCNT <= x"10";
                  mem_ADDR     <= "000" & cardAddr2X & "0000" & "000";
                  mem_BE       <= x"FF";
                  mem_WE       <= '0';
                  mem_RD       <= '1';
               
               when MEMCPUREAD_WAITACK =>
                  if (mem_ack = '1') then
                     memstate <= MEMCPUREAD_READDATA;
                  end if;
                  
               when MEMCPUREAD_READDATA =>
                  if (mem_DOUT_READY = '1') then
                  
                     mem_addrB   <= readCnt2X;
                     mem_DataInB <= mem_DOUT;
                     mem_wrenB   <= '1';
                  
                     if (unsigned(readCnt2X) = 15) then
                        memstate    <= MEMIDLE;
                        mem_request <= '0';
                        mem_WE      <= '0';
                        mem_RD      <= '0';
                     else 
                        readCnt2X <= std_logic_vector(unsigned(readCnt2X) + 1);
                     end if;
                  end if;
            
            end case;
         
         
         end if;
      
      end if;
   end process;
   
end architecture;

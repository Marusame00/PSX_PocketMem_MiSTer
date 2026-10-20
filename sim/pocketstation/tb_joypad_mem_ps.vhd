-- Testbench for rtl/joypad_mem.vhd (memory card device on the SIO port).
--
-- Phase A: standard Sony card (isPocketStation = '0') regression:
--          81h handshake, 53h/58h/5Bh ignored (flags only), 57h write + 52h read round trip.
-- Phase B: PocketStation (isPocketStation = '1'): 53h ID, 58h, 50h, 59h, 5Ah (status with
--          RTC), 5Eh/5Fh, 5Bh FUNC 00/01, write/read, ComFlags.10 write protection (16..55),
--          bad checksum (4Eh), no commit on rejected write.
--
-- Each byte exchange: transmitValue set, actionNext pulsed for one clock, response is
-- the next receiveValid pulse. Expected values: -1 = no response, -2 = any response,
-- >= 0 = exact byte.
--
-- Run (GHDL 6, std=08):
--   ghdl -a --std=08 dpram_dif_sim.vhd joypad_mem.vhd tb_joypad_mem_ps.vhd
--   ghdl -e --std=08 tb_joypad_mem_ps
--   ghdl -r --std=08 tb_joypad_mem_ps

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_joypad_mem_ps is
end entity;

architecture sim of tb_joypad_mem_ps is

   constant CLK_PERIOD : time := 10 ns;

   signal clk           : std_logic := '0';
   signal reset         : std_logic := '1';
   signal memcard_avail : std_logic := '1';

   signal mem_request   : std_logic;
   signal mem_BURSTCNT  : std_logic_vector(7 downto 0);
   signal mem_ADDR      : std_logic_vector(19 downto 0);
   signal mem_DIN       : std_logic_vector(63 downto 0);
   signal mem_BE        : std_logic_vector(7 downto 0);
   signal mem_WE        : std_logic;
   signal mem_RD        : std_logic;
   signal mem_ack       : std_logic := '0';
   signal mem_DOUT      : std_logic_vector(63 downto 0) := (others => '0');
   signal mem_DOUT_READY: std_logic := '0';

   signal selected      : std_logic := '1';
   signal actionNext    : std_logic := '0';
   signal transmitting  : std_logic := '1';
   signal transmitValue : std_logic_vector(7 downto 0) := (others => '0');
   signal isPocketStation : std_logic := '0';
   signal rtc_in        : std_logic_vector(64 downto 0) := (others => '0');
   signal isActive      : std_logic;
   signal slotIdle      : std_logic := '1';
   signal receiveValid  : std_logic;
   signal receiveBuffer : std_logic_vector(7 downto 0);
   signal ack           : std_logic;

   -- response monitor
   signal rx_cnt        : integer := 0;
   signal rx_last       : std_logic_vector(7 downto 0) := (others => '0');

   -- DDR3 model: 16384 words of 64 bit (index = card sector * 16 + word)
   type tMem is array (0 to 16383) of std_logic_vector(63 downto 0);
   signal ddr : tMem := (others => (others => '0'));

   function B(n : integer) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(n, 8));
   end function;

   -- Test pattern for sector s, variant v, byte i
   function pat(s : integer; v : integer; i : integer) return integer is
   begin
      return (i * 3 + s + v * 37) mod 256;
   end function;

   -- Standard checksum: (addr_hi xor addr_lo) xor all data bytes (sector < 256 here)
   function ckof(s : integer; v : integer) return integer is
      variable c : std_logic_vector(7 downto 0) := B(s mod 256);
   begin
      for i in 0 to 127 loop
         c := c xor B(pat(s, v, i));
      end loop;
      return to_integer(unsigned(c));
   end function;

begin

   clk <= not clk after CLK_PERIOD / 2;

   -- Device under test
   dut : entity work.joypad_mem
   port map
   (
      clk1x                => clk,
      clk2x                => clk,
      clk2xIndex           => '0',
      ce                   => '1',
      reset                => reset,
      memcard_available    => memcard_avail,
      mem_request          => mem_request,
      mem_BURSTCNT         => mem_BURSTCNT,
      mem_ADDR             => mem_ADDR,
      mem_DIN              => mem_DIN,
      mem_BE               => mem_BE,
      mem_WE               => mem_WE,
      mem_RD               => mem_RD,
      mem_ack              => mem_ack,
      mem_DOUT             => mem_DOUT,
      mem_DOUT_READY       => mem_DOUT_READY,
      selected             => selected,
      actionNext           => actionNext,
      transmitting         => transmitting,
      transmitValue        => transmitValue,
      isPocketStation      => isPocketStation,
      rtc_in               => rtc_in,
      isActive             => isActive,
      slotIdle             => slotIdle,
      receiveValid         => receiveValid,
      receiveBuffer        => receiveBuffer,
      ack                  => ack
   );

   -- Response monitor
   rxmon : process (clk)
   begin
      if rising_edge(clk) then
         if (receiveValid = '1') then
            rx_cnt  <= rx_cnt + 1;
            rx_last <= receiveBuffer;
         end if;
      end if;
   end process;

   -- DDR3 model: acknowledges writes/reads and returns 16 beats for a read
   ddrmodel : process
      variable base : integer;
   begin
      mem_ack         <= '0';
      mem_DOUT_READY  <= '0';
      loop
         wait until rising_edge(clk);
         if (mem_request = '1' and mem_WE = '1') then
            base := to_integer(unsigned(mem_ADDR(16 downto 3)));
            ddr(base) <= mem_DIN;
            mem_ack <= '1';
            wait until rising_edge(clk);
            mem_ack <= '0';
            while (mem_request = '1') loop
               wait until rising_edge(clk);
            end loop;
         elsif (mem_request = '1' and mem_RD = '1') then
            base := to_integer(unsigned(mem_ADDR(16 downto 3)));
            mem_ack <= '1';
            wait until rising_edge(clk);
            mem_ack <= '0';
            for i in 0 to 15 loop
               mem_DOUT        <= ddr(base + i);
               mem_DOUT_READY  <= '1';
               wait until rising_edge(clk);
            end loop;
            mem_DOUT_READY <= '0';
            while (mem_request = '1') loop
               wait until rising_edge(clk);
            end loop;
         end if;
      end loop;
   end process;

   -- Stimulus
   stim : process
      variable nerr   : integer := 0;
      variable ntests : integer := 0;
      variable fl     : integer := 8;   -- expected COMMAND flags byte (08h until first write)

      -- One byte exchange; expv: -1 none, -2 any, >=0 exact
      procedure ex(constant tx : in integer; constant expv : in integer) is
         variable c0 : integer;
      begin
         c0 := rx_cnt;
         transmitValue <= B(tx);
         wait until rising_edge(clk);
         actionNext <= '1';
         wait until rising_edge(clk);
         actionNext <= '0';
         for i in 1 to 80 loop
            wait until rising_edge(clk);
         end loop;
         ntests := ntests + 1;
         if (expv = -1) then
            if (rx_cnt /= c0) then
               report "tx " & integer'image(tx) & ": unexpected response " & integer'image(to_integer(unsigned(rx_last))) severity error;
               nerr := nerr + 1;
            end if;
         elsif (rx_cnt = c0) then
            report "tx " & integer'image(tx) & ": no response, expected " & integer'image(expv) severity error;
            nerr := nerr + 1;
         elsif (expv >= 0 and to_integer(unsigned(rx_last)) /= expv) then
            report "tx " & integer'image(tx) & ": got " & integer'image(to_integer(unsigned(rx_last))) &
                   " expected " & integer'image(expv) severity error;
            nerr := nerr + 1;
         end if;
      end procedure;

      -- End of transaction (selected low) and start of a new one with 81h
      procedure endtx is
      begin
         selected <= '0';
         for i in 1 to 5 loop wait until rising_edge(clk); end loop;
         selected <= '1';
         for i in 1 to 5 loop wait until rising_edge(clk); end loop;
      end procedure;

      procedure start is
      begin
         endtx;
         ex(16#81#, 16#FF#);
      end procedure;

      -- Write sector s (variant v). bad = send wrong checksum. endexp = final code.
      procedure wr_sector(constant s : in integer; constant v : in integer;
                          constant bad : in boolean; constant endexp : in integer) is
         variable ck : integer;
      begin
         ck := ckof(s, v);
         ex(16#57#, fl);
         ex(16#00#, 16#5A#);
         ex(16#00#, 16#5D#);
         ex(16#00#, 16#00#);     -- address hi
         ex(s mod 256, -2);      -- address lo (PS: 00h; standard: echo of hi = 00h)
         for i in 0 to 127 loop
            ex(pat(s, v, i), -2);
         end loop;
         fl := 0;                -- WRITEDATA clears flags.3
         if (bad) then
            ex((ck + 1) mod 256, ck);
         else
            ex(ck, ck);
         end if;
         ex(16#00#, 16#5C#);
         ex(16#00#, 16#5D#);
         ex(16#00#, endexp);
      end procedure;

      -- Read sector s (variant v) and verify all 128 bytes + checksum
      procedure rd_sector(constant s : in integer; constant v : in integer) is
      begin
         ex(16#52#, fl);
         ex(16#00#, 16#5A#);
         ex(16#00#, 16#5D#);
         ex(16#00#, 16#00#);
         ex(s mod 256, -2);      -- address lo (PS: 00h response)
         ex(16#00#, 16#5C#);
         ex(16#00#, 16#5D#);
         ex(16#00#, 16#00#);     -- confirm address hi
         ex(16#00#, s mod 256);  -- confirm address lo
         for i in 0 to 127 loop
            ex(16#00#, pat(s, v, i));
         end loop;
         ex(16#00#, ckof(s, v));
         ex(16#00#, 16#47#);
      end procedure;

   begin
      -- ------------------------------------------------------------------
      -- Reset
      -- ------------------------------------------------------------------
      isPocketStation <= '0';
      reset <= '1';
      for i in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      for i in 1 to 4 loop wait until rising_edge(clk); end loop;

      -- ------------------------------------------------------------------
      -- Phase A: standard card regression
      -- ------------------------------------------------------------------
      report "=== Phase A: standard card ===" severity note;
      fl := 8;
      start;
      ex(16#53#, 8);          -- COMMAND flags only; 53h is not a standard command
      ex(16#00#, -1);
      start;
      ex(16#58#, 8);          -- PocketStation-only command
      ex(16#00#, -1);
      start;
      ex(16#5B#, 8);
      ex(16#00#, -1);
      start;
      wr_sector(17, 0, false, 16#47#);
      start;
      rd_sector(17, 0);

      -- ------------------------------------------------------------------
      -- Phase B: PocketStation
      -- ------------------------------------------------------------------
      report "=== Phase B: PocketStation ===" severity note;
      -- RTC: 2026-10-20 (BCD) 09:15:30, Tuesday (rtc dow 0=Sun..6=Sat -> 2 = Tue -> PS 03h)
      rtc_in(7 downto 0)   <= x"30";
      rtc_in(15 downto 8)  <= x"15";
      rtc_in(23 downto 16) <= x"09";
      rtc_in(31 downto 24) <= x"20";
      rtc_in(39 downto 32) <= x"10";
      rtc_in(47 downto 40) <= x"26";
      rtc_in(50 downto 48) <= "010";
      isPocketStation <= '1';
      reset <= '1';
      for i in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      for i in 1 to 4 loop wait until rising_edge(clk); end loop;
      fl := 8;

      -- 53h Get ID: 5A 5D 5C 5D 04 00 00 80
      start;
      ex(16#53#, 8);
      ex(16#00#, 16#5A#); ex(16#00#, 16#5D#); ex(16#00#, 16#5C#); ex(16#00#, 16#5D#);
      ex(16#00#, 16#04#); ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#80#);

      -- 58h: 02h 01h 01h
      start;
      ex(16#58#, 8);
      ex(16#00#, 16#02#); ex(16#00#, 16#01#); ex(16#00#, 16#01#);

      -- 50h: length 00h
      start;
      ex(16#50#, 8);
      ex(16#00#, 16#00#);

      -- 59h: prepare execute, dir_index 0005h (old values 0000h returned)
      start;
      ex(16#59#, 8);
      ex(16#00#, 16#06#);     -- length
      ex(16#00#, 16#00#);     -- dir_index hi (old)
      ex(16#05#, 16#00#);     -- dir_index lo (old)
      ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#);

      -- 5Ah: status, dir_index now 0005h, ComFlags 0, date/time from RTC
      start;
      ex(16#5A#, 8);
      ex(16#00#, 16#12#);
      ex(16#00#, 16#00#);     -- dir hi
      ex(16#00#, 16#05#);     -- dir lo
      ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#); -- ComFlags 0,1,3,2
      ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#); -- F_SN
      ex(16#00#, 16#20#);     -- day
      ex(16#00#, 16#10#);     -- month
      ex(16#00#, 16#26#);     -- year
      ex(16#00#, 16#20#);     -- century
      ex(16#00#, 16#30#);     -- sec
      ex(16#00#, 16#15#);     -- min
      ex(16#00#, 16#09#);     -- hour
      ex(16#00#, 16#03#);     -- day of week (Tuesday)

      -- 5Eh: new ComFlags.1=1, .3=0, .2=1 (old values 0 returned)
      start;
      ex(16#5E#, 8);
      ex(16#00#, 16#03#);
      ex(16#01#, 16#00#);
      ex(16#00#, 16#00#);
      ex(16#01#, 16#00#);

      -- 5Fh: new ComFlags.0=1 (old 0 returned)
      start;
      ex(16#5F#, 8);
      ex(16#00#, 16#01#);
      ex(16#01#, 16#00#);

      -- 5Ah again: ComFlags 0/1/3/2 = 01,01,00,01
      start;
      ex(16#5A#, 8);
      ex(16#00#, 16#12#);
      ex(16#00#, 16#00#); ex(16#00#, 16#05#);
      ex(16#00#, 16#01#); ex(16#00#, 16#01#); ex(16#00#, 16#00#); ex(16#00#, 16#01#);
      ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#);
      ex(16#00#, 16#20#); ex(16#00#, 16#10#); ex(16#00#, 16#26#); ex(16#00#, 16#20#);
      ex(16#00#, 16#30#); ex(16#00#, 16#15#); ex(16#00#, 16#09#); ex(16#00#, 16#03#);

      -- 5Bh FUNC 00h: date/time, LEN1 00h, LEN2 08h, 8 data bytes, FFh end
      start;
      ex(16#5B#, 8);
      ex(16#00#, 16#FF#);     -- FUNC byte
      ex(16#00#, 16#00#);     -- LEN1
      ex(16#00#, 16#08#);     -- LEN2
      ex(16#00#, 16#20#); ex(16#00#, 16#10#); ex(16#00#, 16#26#); ex(16#00#, 16#20#);
      ex(16#00#, 16#30#); ex(16#00#, 16#15#); ex(16#00#, 16#09#); ex(16#00#, 16#03#);
      ex(16#00#, 16#FF#);     -- end

      -- 5Bh FUNC 01h: LEN1 05h, 5 params, LEN2 = 5th param (10h), 16 data bytes, FFh
      start;
      ex(16#5B#, 8);
      ex(16#01#, 16#FF#);
      ex(16#00#, 16#05#);
      ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#);
      ex(16#10#, 16#00#);
      ex(16#00#, 16#10#);
      for i in 1 to 16 loop
         ex(16#00#, 16#00#);
      end loop;
      ex(16#00#, 16#FF#);

      -- Writes: sector 20 (variant 0) commits, sector 60 (variant 2) commits
      start;
      wr_sector(20, 0, false, 16#47#);
      start;
      wr_sector(60, 2, false, 16#47#);

      -- 5Dh value 00h in bits 8-15 -> ComFlags.10 = 1 (write-protect sectors 16..55)
      start;
      ex(16#5D#, fl);
      ex(16#00#, 16#03#);
      ex(16#00#, 16#00#); ex(16#00#, 16#00#); ex(16#00#, 16#00#);

      -- Sector 20 still reads variant 0
      start;
      rd_sector(20, 0);

      -- Write to protected sector 20 -> FEh, not committed
      start;
      wr_sector(20, 1, false, 16#FE#);

      -- Sector 20 unchanged
      start;
      rd_sector(20, 0);

      -- Bad checksum to sector 60 (not protected) -> 4Eh, not committed
      start;
      wr_sector(60, 1, true, 16#4E#);

      -- Sector 60 unchanged (variant 2)
      start;
      rd_sector(60, 2);

      -- Sector 60 write with ComFlags.10 still set is allowed outside 16..55
      start;
      wr_sector(60, 3, false, 16#47#);
      start;
      rd_sector(60, 3);

      -- ------------------------------------------------------------------
      report "Tests executed: " & integer'image(ntests) & ", errors: " & integer'image(nerr) severity note;
      if (nerr = 0) then
         report "ALL TESTS PASSED" severity note;
      else
         report "TESTS FAILED" severity failure;
      end if;
      stop(0);
      wait;
   end process;

end architecture;

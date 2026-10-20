-- Behavioral simulation model of the 128-byte sector buffer (rtl/dpram.vhd: dpram_dif).
-- Simulation only: the synthesis build uses the Altera altsyncram-based dpram_dif.
-- Port A: 128 x 8 (byte access). Port B: 16 x 64 (word k = bytes 8k..8k+7, little endian).
-- Both ports are assumed to use the same clock, read-before-write, 1-cycle latency.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity dpram_dif is
   generic (
      addr_width_a  : integer := 8;
      data_width_a  : integer := 8;
      addr_width_b  : integer := 8;
      data_width_b  : integer := 8
   );
   port
   (
      clock_a     : in  std_logic;
      address_a   : in  std_logic_vector (addr_width_a-1 downto 0);
      data_a      : in  std_logic_vector (data_width_a-1 downto 0) := (others => '0');
      clken_a     : in  std_logic := '1';
      wren_a      : in  std_logic := '0';
      q_a         : out std_logic_vector (data_width_a-1 downto 0);
      cs_a        : in  std_logic := '1';

      clock_b     : in  std_logic;
      address_b   : in  std_logic_vector (addr_width_b-1 downto 0) := (others => '0');
      data_b      : in  std_logic_vector (data_width_b-1 downto 0) := (others => '0');
      clken_b     : in  std_logic := '1';
      wren_b      : in  std_logic := '0';
      q_b         : out std_logic_vector (data_width_b-1 downto 0);
      cs_b        : in  std_logic := '1'
   );
end entity;

architecture sim of dpram_dif is
   type tBytes is array (0 to 127) of std_logic_vector(7 downto 0);
   signal bytes : tBytes := (others => (others => '0'));
begin
   process (clock_a)
      variable a : integer;
      variable b : integer;
      variable qb : std_logic_vector(63 downto 0);
   begin
      if rising_edge(clock_a) then
         if (clken_a = '1') then
            a := to_integer(unsigned(address_a));
            q_a <= bytes(a);
            if (wren_a = '1') then
               bytes(a) <= data_a;
            end if;
         end if;

         if (clken_b = '1') then
            b := to_integer(unsigned(address_b));
            for j in 0 to 7 loop
               qb(8*j+7 downto 8*j) := bytes(8*b+j);
            end loop;
            q_b <= qb;
            if (wren_b = '1') then
               for j in 0 to 7 loop
                  bytes(8*b+j) <= data_b(8*j+7 downto 8*j);
               end loop;
            end if;
         end if;
      end if;
   end process;
end architecture;

------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2009 Tobias Gubener                                        -- 
-- Subdesign fAMpIGA by TobiFlex                                            --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU General Public License as published        --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

 
library ieee;
use ieee.std_logic_1164.all;
use IEEE.numeric_std.ALL;

use work.sdram_pkg.ALL;
use work.sdram_config.all;

entity sdram is
port
	(
		-- Physical connections to the SDRAM
		pins_io : inout SDRAM_Pins_io;	-- Data lines
		pins_o : out SDRAM_Pins_o; -- control signals
		pins_clk : out SDRAM_Pins_clk; -- clock signals
		
--	-- Physical connections to the SDRAM
--		sdata		: inout std_logic_vector(15 downto 0);
--		sdaddr		: out std_logic_vector((sdram_rows-1) downto 0);
--		sd_we		: out std_logic;	-- Write enable, active low
--		sd_ras		: out std_logic;	-- Row Address Strobe, active low
--		sd_cas		: out std_logic;	-- Column Address Strobe, active low
--		sd_cs		: out std_logic;	-- Chip select - only the lsb does anything.
--		dqm			: out std_logic_vector(1 downto 0);	-- Data mask, upper and lower byte
--		ba			: buffer std_logic_vector(1 downto 0); -- Bank?

	-- Housekeeping
		sysclk		: in std_logic;
		sdram_clk : in std_logic;
		reset		: in std_logic;
		reset_out	: out std_logic;
		reinit : in std_logic :='0';

	-- Port 0 - VGA
		vga_addr : in std_logic_vector(31 downto 0) := X"00000000";
		vga_data	: out std_logic_vector(15 downto 0);
		vga_req : in std_logic := '0';
		vga_fill : out std_logic;
		vga_ack : out std_logic;
		vga_refresh : in std_logic := '1'; -- SDRAM won't come out of reset without this.
		vga_reservebank : in std_logic := '0'; -- Keep a bank clear for instant access in slot 1
		vga_reserveaddr : in std_logic_vector(31 downto 0) := X"00000000";

		-- Port 1
		port1_i : in SDRAM_Port_FromCPU;
		port1_o : out SDRAM_Port_ToCPU
	);
end;

architecture rtl of sdram is


signal initstate	:unsigned(3 downto 0);	-- Counter used to initialise the RAM
signal cas_sd_cs	:std_logic;	-- Temp registers...
signal cas_sd_ras	:std_logic;
signal cas_sd_cas	:std_logic;
signal cas_sd_we 	:std_logic;
signal cas_dqm		:std_logic_vector(1 downto 0);	-- ...mask register for entire burst
signal init_done	:std_logic;
signal datain		:std_logic_vector(15 downto 0);
signal casaddr		:std_logic_vector(31 downto 0);
signal sdwrite 		:std_logic;
signal sdata_reg	:std_logic_vector(15 downto 0);

signal refreshcycle :std_logic;

type sdram_states is (ph0,ph1,ph2,ph3,ph4,ph5,ph6,ph7,ph8,ph9,ph10,ph11,ph12,ph13,ph14,ph15);
signal sdram_state		: sdram_states;

type sdram_ports is (idle,refresh,port0,port1,writecache);

signal sdram_slot1 : sdram_ports :=refresh;
signal sdram_slot1_readwrite : std_logic;
signal sdram_slot2 : sdram_ports :=idle;
signal sdram_slot2_readwrite : std_logic;

-- Since VGA has absolute priority, we keep track of the next bank and disallow accesses
-- to either the current or next bank in the interleaved access slots.
signal slot1_bank : std_logic_vector(1 downto 0) := "00";
signal slot2_bank : std_logic_vector(1 downto 0) := "11";

-- refresh timer - once per scanline, so don't need the counter...
signal refreshcounter : unsigned(11 downto 0);	-- 12 bits gives us 4096 cycles between refreshes => pretty conservative.
signal refreshpending : std_logic :='0';

signal port1_dtack : std_logic;

type writecache_states is (waitwrite,fill,finish);
signal writecache_state : writecache_states;

signal writecache_addr : std_logic_vector(31 downto 3);
signal writecache_word0 : std_logic_vector(15 downto 0);
signal writecache_word1 : std_logic_vector(15 downto 0);
signal writecache_word2 : std_logic_vector(15 downto 0);
signal writecache_word3 : std_logic_vector(15 downto 0);
signal writecache_dqm : std_logic_vector(7 downto 0);
signal writecache_req : std_logic;
signal writecache_dirty : std_logic;
signal writecache_dtack : std_logic;
signal writecache_burst : std_logic;

type readcache_states is (waitread,req,fill1,fill2,fill3,fill4,fill2_1,fill2_2,fill2_3,fill2_4,finish);
signal readcache_state : readcache_states;

signal readcache_addr : std_logic_vector(31 downto 3);
signal readcache_word0 : std_logic_vector(15 downto 0);
signal readcache_word1 : std_logic_vector(15 downto 0);
signal readcache_word2 : std_logic_vector(15 downto 0);
signal readcache_word3 : std_logic_vector(15 downto 0);
signal readcache_dirty : std_logic;
signal readcache_req : std_logic;
signal readcache_dtack : std_logic;
signal readcache_fill : std_logic;

signal instcache_addr : std_logic_vector(31 downto 3);
signal instcache_word0 : std_logic_vector(15 downto 0);
signal instcache_word1 : std_logic_vector(15 downto 0);
signal instcache_word2 : std_logic_vector(15 downto 0);
signal instcache_word3 : std_logic_vector(15 downto 0);
signal instcache_dirty : std_logic;

signal cache_ready : std_logic;

COMPONENT TwoWayCache
	GENERIC ( WAITING : INTEGER := 0; WAITRD : INTEGER := 1; WAITFILL : INTEGER := 2; FILL2 : INTEGER := 3;
		 FILL3 : INTEGER := 4; FILL4 : INTEGER := 5; FILL5 : INTEGER := 6; PAUSE1 : INTEGER := 7 );
		
	PORT
	(
		clk		:	 IN STD_LOGIC;
		reset	: IN std_logic;
		ready : out std_logic;
		cpu_addr		:	 IN STD_LOGIC_VECTOR(31 DOWNTO 0);
		cpu_req		:	 IN STD_LOGIC;
		cpu_ack		:	 OUT STD_LOGIC;
		cpu_rw		:	 IN STD_LOGIC;
		cpu_rwl	: in std_logic;
		cpu_rwu : in std_logic;
		data_from_cpu		:	 IN STD_LOGIC_VECTOR(15 DOWNTO 0);
		data_to_cpu		:	 OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
		sdram_addr		:	 OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
		data_from_sdram		:	 IN STD_LOGIC_VECTOR(15 DOWNTO 0);
		data_to_sdram		:	 OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
		sdram_req		:	 OUT STD_LOGIC;
		sdram_fill		:	 IN STD_LOGIC;
		sdram_rw		:	 OUT STD_LOGIC
	);
END COMPONENT;


begin

Pins_clk.cke <= '1';
Pins_clk.clk <= sdram_clk;

	process(sysclk)
	begin
	
	port1_o.ack <= port1_dtack and writecache_dtack and not readcache_dtack;

-- Write cache implementation: (AMR)
-- states:
--    main:	wait for port1_i.req='1' and port1_i.wr='0'
--				Compare addrin(23 downto 3) with stored address, or stored address is FFFFFF
--					if equal, store data and DQM according to LSBs, assert dtack,
--				if stored address/=X"FFFFFF" assert req_sdram, set data/dqm for first word
--				if fill from SDRAM
--					write second word/dqm
--					goto state fill3
--		fill3
--			write third word / dqm
--			goto state fill4
--		fill4
--			write fourth word / dqm
--			goto state finish
--		finish
--			addr<=X"FFFFFF";
--			dqms<=X"11111111";
--			goto state main
	

	if reset='0' then
		writecache_req<='0';
		writecache_dirty<='0';
		writecache_dqm<="11111111";
		writecache_state<=waitwrite;
	elsif rising_edge(sysclk) then

		writecache_dtack<='1';
		case writecache_state is
			when waitwrite =>
				if port1_i.req='1' and port1_i.wr='0' then -- write request
					-- Need to be careful with write merges; if we byte-write to an address
					-- that already has a pending word write, we must be sure not to cancel
					-- the other half of the existing word write.
					if writecache_dirty='0' or port1_i.addr(31 downto 3)=writecache_addr(31 downto 3) then
						writecache_addr(31 downto 3)<=port1_i.addr(31 downto 3);
						case port1_i.addr(2 downto 1) is
							when "00" =>
								if port1_i.uds='0' then
									writecache_word0(15 downto 8)<=port1_i.data(15 downto 8);
									writecache_dqm(1)<='0';
								end if;
								if port1_i.lds='0' then
									writecache_word0(7 downto 0)<=port1_i.data(7 downto 0);
									writecache_dqm(0)<='0';
								end if;
							when "01" =>
								if port1_i.uds='0' then
									writecache_word1(15 downto 8)<=port1_i.data(15 downto 8);
									writecache_dqm(3)<='0';
								end if;
								if port1_i.lds='0' then
									writecache_word1(7 downto 0)<=port1_i.data(7 downto 0);
									writecache_dqm(2)<='0';
								end if;
							when "10" =>
								if port1_i.uds='0' then
									writecache_word2(15 downto 8)<=port1_i.data(15 downto 8);
									writecache_dqm(5)<='0';
								end if;
								if port1_i.lds='0' then
									writecache_word2(7 downto 0)<=port1_i.data(7 downto 0);
									writecache_dqm(4)<='0';
								end if;
							when "11" =>
								if port1_i.uds='0' then
									writecache_word3(15 downto 8)<=port1_i.data(15 downto 8);
									writecache_dqm(7)<='0';
								end if;
								if port1_i.lds='0' then
									writecache_word3(7 downto 0)<=port1_i.data(7 downto 0);
									writecache_dqm(6)<='0';
								end if;
--							when "00" =>
--								writecache_word0<=port1_i.data;
--								writecache_dqm(1 downto 0)<=port1_i.uds&port1_i.lds;
--							when "01" =>
--								writecache_word1<=port1_i.data;
--								writecache_dqm(3 downto 2)<=port1_i.uds&port1_i.lds;
--							when "10" =>
--								writecache_word2<=port1_i.data;
--								writecache_dqm(5 downto 4)<=port1_i.uds&port1_i.lds;
--							when "11" =>
--								writecache_word3<=port1_i.data;
--								writecache_dqm(7 downto 6)<=port1_i.uds&port1_i.lds;
						end case;
						writecache_req<='1';

						writecache_dtack<='0';
						writecache_dirty<='1';
					end if;
				end if;
				if writecache_burst='1' and writecache_dirty='1' then
					writecache_req<='0';
					writecache_state<=fill;
				end if;
			when fill =>
				if writecache_burst='0' then
					writecache_dirty<='0';
					writecache_dqm<="11111111";
					writecache_state<=waitwrite;
				end if;
			when others =>
				null;
		end case;
				
	end if;
end process;


mytwc : component TwoWayCache
	PORT map
	(
		clk => sysclk,
		reset => reset,
		ready => cache_ready,
		cpu_addr => port1_i.addr,
		cpu_req => port1_i.req,
		cpu_ack => readcache_dtack,
		cpu_rw => port1_i.wr,
		cpu_rwl => port1_i.lds,
		cpu_rwu => port1_i.uds,
		data_from_cpu => port1_i.data,
		data_to_cpu => port1_o.data,
		sdram_addr(31 downto 3) => readcache_addr(31 downto 3),
		sdram_addr(2 downto 0) => open,
		data_from_sdram => sdata_reg,
		data_to_sdram => open,
		sdram_req => readcache_req,
		sdram_fill => readcache_fill,
		sdram_rw => open
	);

	
-------------------------------------------------------------------------
-- SDRAM Basic
-------------------------------------------------------------------------
	reset_out <= init_done and cache_ready;
--	port1bank <= unsigned(port1_i.addr(4 downto 3));

	process (sysclk, reset, sdwrite, datain) begin
		IF sdwrite='1' THEN	-- Keep sdram data high impedence if not writing to it.
			Pins_io.data <= datain;
		ELSE
			Pins_io.data <= "ZZZZZZZZZZZZZZZZ";
		END IF;

		--   sample SDRAM data
		if rising_edge(sysclk) then
			sdata_reg <= Pins_io.data;
			vga_data <= Pins_io.data;
		END IF;	
		
		if reset = '0' then
			initstate <= (others => '0');
			init_done <= '0';
			sdram_state <= ph0;
			sdwrite <= '0';
		ELSIF rising_edge(sysclk) THEN
			sdwrite <= '0';

			if reinit='1' then
				init_done<='0';
				initstate<="1111";
			end if;			
			

--                          (sync)
-- Phase     :  0     1     2     3     4     5     6     7     8     9    10    11    12    13    14    15
-- sysclk    :/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__

-- _RAS      :            \_____/
-- _CAS      :           (\auto/)           \_____/

-- SDWrite   :________________________/                 \_________________________________________

			case sdram_state is	--LATENCY=3
				when ph0 =>	
					if sdram_slot2=writecache then -- port1 and sdram_slot2_readwrite='0' then
						sdwrite<='1';
					end if;
					sdram_state <= ph1;
				when ph1 =>	
					if sdram_slot2=port0 then
						vga_fill<='1';
					end if;
					sdram_state <= ph2;
				when ph2 =>
					sdram_state <= ph3;
--					enaRDreg <= '1';
				when ph3 =>
					sdram_state <= ph4;
				when ph4 =>	sdram_state <= ph5;
					sdwrite <= '1';
				when ph5 => sdram_state <= ph6;
					vga_fill<='0';
					sdwrite <= '1';
				when ph6 =>	sdram_state <= ph7;
					sdwrite <= '1';
--							enaWRreg <= '1';
--							ena7RDreg <= '1';
				when ph7 =>	sdram_state <= ph8;
					sdwrite <= '1';
				when ph8 =>	sdram_state <= ph9;
					if sdram_slot1=writecache then -- port1 and sdram_slot1_readwrite='0' then
						sdwrite<='1';
					end if;
					
				when ph9 =>	sdram_state <= ph10;
					if sdram_slot1=port0 then
						vga_fill<='1';
					end if;
				when ph10 => sdram_state <= ph11;
--					cachefill<='1';
--							enaRDreg <= '1';
				when ph11 => sdram_state <= ph12;
--					cachefill<='1';
				when ph12 => sdram_state <= ph13;
--					cachefill<='1';
					sdwrite<='1';
				when ph13 => sdram_state <= ph14;
					vga_fill<='0';
					sdwrite<='1';
				when ph14 =>
						sdwrite<='1';
						if initstate /= "1111" THEN -- 16 complete phase cycles before we allow the rest of the design to come out of reset.
							initstate <= initstate+1;
							sdram_state <= ph15;
						elsif init_done='1' then
							sdram_state <= ph15;
						elsif vga_refresh='1' then -- Delay here to establish phase relationship between SDRAM and VGA
							init_done <='1';
							sdram_state <= ph0;
						end if;
--							enaWRreg <= '1';
--							ena7WRreg <= '1';
				when ph15 => sdram_state <= ph0;
					sdwrite<='1';
				when others => sdram_state <= ph0;
			end case;	
		END IF;	
	end process;		


	
	process (sysclk, initstate, datain, init_done, casaddr, refreshcycle) begin


		if reset='0' then
			sdram_slot1<=refresh;
			sdram_slot2<=idle;
			slot1_bank<="00";
			slot2_bank<="11";
			writecache_burst<='0';
		elsif rising_edge(sysclk) THEN -- rising edge
	
			-- Attend to refresh counter:
			-- Refresh requirements depend upon sysclk.  Assume sysclk of 75Mhz.
			-- Entire SDRAM must be refreshed every 60ms, and SDRAM has 8192 rows.
			-- That means 16.6' complete refreshes per second,
			-- so (8192*16.6') refresh cycles per second, which at 75Mhz means
			-- at least one every 5493 clock cycles.  We'll go with a 12-bit counter,
			-- giving us a refresh period of 4096 clock cycles.
			refreshcounter<=refreshcounter+X"001";
			if sdram_slot1=refresh then
				refreshpending<='0';
			elsif refreshcounter=X"000" then
				refreshpending<='1';
--			elsif vga_refresh='1' then
--				refreshpending<='1';
			end if;

		--		ba <= Addr(22 downto 21);
			Pins_o.cs <='1';
			Pins_o.ras <= '1';
			Pins_o.cas <= '1';
			Pins_o.we <= '1';
			Pins_o.addr <= (others =>'X');
			Pins_o.ba <= "00";
			Pins_o.dqm <= "00";  -- safe defaults for everything...

			port1_dtack<='1';

			-- The following block only happens during reset.
			if init_done='0' then
				if sdram_state =ph2 then
					case initstate is
						when "0010" => --PRECHARGE
							Pins_o.addr(10) <= '1'; 	--all banks
							Pins_o.cs <='0';
							Pins_o.ras <= '0';
							Pins_o.cas <= '1';
							Pins_o.we <= '0';
						when "0011"|"0100"|"0101"|"0110"|"0111"|"1000"|"1001"|"1010"|"1011"|"1100" => --AUTOREFRESH
							Pins_o.cs <='0'; 
							Pins_o.ras <= '0';
							Pins_o.cas <= '0';
							Pins_o.we <= '1';
						when "1101" => --LOAD MODE REGISTER
							Pins_o.cs <='0';
							Pins_o.ras <= '0';
							Pins_o.cas <= '0';
							Pins_o.we <= '0';
--							ba <= "00";
	--						sdaddr <= "001000100010"; --BURST=4 LATENCY=2
--							sdaddr <= "001000110010"; --BURST=4 LATENCY=3
--							sdaddr <= "001000110000"; --noBURST LATENCY=3
							Pins_o.addr <= (others=>'0'); --BURST=4 LATENCY=3, BURST WRITES
							Pins_o.addr(11 downto 0) <= "000000110010"; --BURST=4 LATENCY=3, BURST WRITES
						when others =>	null;	--NOP
					end case;
				END IF;
			else		

			
-- We have 8 megabytes to play with, addressed with bits 22 downto 0
-- bits 22 and 21 are used as bank select
-- bits 20 downto 9 are the row address, set in phase 2.
-- bits 23, 8 downto 1

-- In the interests of interleaving bank access, rearrange this somewhat
-- We're transferring 4 word bursts, so 8 bytes at a time, so leave lower 3 bits
-- as they are, but try making the next two the bank select bits

-- Bank select will thus be addr(4 downto 3),
-- Column will be addr(10 downto 5) & addr(2 downto 1) instead of addr(8 downto 1)
-- Row will be addr(22 downto 11) instead of (20 downto 9)

--  ph0				(drive data)
--
--  ph1
--						Data word 1
--  ph2 Active first bank / Autorefresh (RAS)
--						Data word 2
--  ph3
--						Data word 3 -  Assert dtack, propagates next cycle by which time all data is valid.
--  ph4
--						Data word 4
--  ph5 ReadA (CAS) (drive data)

--  ph6 (drive data)

--  ph7 (drive data)

--  ph8 (drive data)
--  ph9 Data word 1

-- ph10 Data word 2
--						Active second bank

-- ph11 Data word 3  -  Assert dtack, propagates next cycle by which time all data is valid.

-- ph12 Data word 4

-- ph13
--						ReadA (CAS) (drive data)
-- ph14
--						(drive data)
-- ph15
--						(drive data)

-- Time slot control			

				readcache_fill<='0';
				vga_ack<='0';
				case sdram_state is

					when ph2 => -- ACTIVE for first access slot
						cas_sd_cs <= '0';  -- Only the lowest bit has any significance...
						cas_sd_ras <= '1';
						cas_sd_cas <= '1';
						cas_sd_we <= '1';

						cas_dqm <= "00";

						sdram_slot1<=idle;
						if refreshpending='1' and sdram_slot2=idle then	-- refreshcycle
							sdram_slot1<=refresh;
							Pins_o.cs <= '0'; --ACTIVE
							Pins_o.ras <= '0';
							Pins_o.cas <= '0'; --AUTOREFRESH
						elsif vga_req='1' then
							if vga_addr(4 downto 3)/=slot2_bank or sdram_slot2=idle then
								sdram_slot1<=port0;
								Pins_o.addr <= vga_addr(25 downto 13);
								Pins_o.ba <= vga_addr(4 downto 3);
								slot1_bank <= vga_addr(4 downto 3);
--								if vga_idle='0' then
--									vga_nextbank <= unsigned(vga_addr(4 downto 3))+"01";
--								end if;
								casaddr <= vga_addr(31 downto 3) & "000"; -- read whole cache line in burst mode.
	--							datain <= X"0000";
								cas_sd_cas <= '0';
								cas_sd_we <= '1';
								Pins_o.cs <= '0'; --ACTIVE
								Pins_o.ras <= '0';
								vga_ack<='1'; -- Signal to VGA controller that it can bump bankreserve
--							else
--								vga_nextbank <= unsigned(vga_addr(4 downto 3)); -- reserve bank for next access
							end if;
						elsif writecache_req='1'
								and sdram_slot2/=writecache
								and (writecache_addr(4 downto 3)/=slot2_bank or sdram_slot2=idle)
									then
							sdram_slot1<=writecache;
							Pins_o.addr <= writecache_addr(25 downto 13);
							Pins_o.ba <= writecache_addr(4 downto 3);
							slot1_bank <= writecache_addr(4 downto 3);
							cas_dqm <= port1_i.uds&port1_i.lds;
							casaddr <= writecache_addr&"000";
--							datain <= writecache_word0;
							cas_sd_cas <= '0';
							cas_sd_we <= '0';
							sdram_slot1_readwrite <= '0';
							Pins_o.cs <= '0'; --ACTIVE
							Pins_o.ras <= '0';
						elsif readcache_req='1' --port1_i.req='1' and port1_i.wr='1'
								and (port1_i.addr(4 downto 3)/=slot2_bank or sdram_slot2=idle) then
							sdram_slot1<=port1;
							Pins_o.addr <= port1_i.addr(25 downto 13);
							Pins_o.ba <= port1_i.addr(4 downto 3);
							slot1_bank <= port1_i.addr(4 downto 3); -- slot1 bank
							cas_dqm <= "00";
							casaddr <= port1_i.addr(31 downto 1) & "0";
--							datain <= port1_i.data;
							cas_sd_cas <= '0';
							cas_sd_we <= '1';
							sdram_slot1_readwrite <= '1';
							Pins_o.cs <= '0'; --ACTIVE
							Pins_o.ras <= '0';
						end if;

						if sdram_slot2=port1 then
							readcache_fill<='1';
						end if;


					when ph3 =>
						if sdram_slot2=port1 then
							readcache_fill<='1';
						end if;

						if sdram_slot1=writecache then
							writecache_burst<='1';	-- Close the door on new write data
						end if;

					when ph4 =>
						if sdram_slot2=port1 then
							readcache_fill<='1';
						end if;
						
					when ph5 => -- Read or Write command			
						Pins_o.addr <=  "001" & casaddr(12 downto 5) & casaddr(2 downto 1) ;--auto precharge
						Pins_o.ba <= casaddr(4 downto 3);
						Pins_o.cs <= cas_sd_cs; 

						Pins_o.dqm <= cas_dqm;

						Pins_o.ras <= cas_sd_ras;
						Pins_o.cas <= cas_sd_cas;
						Pins_o.we  <= cas_sd_we;
						if sdram_slot1=writecache then
							datain <= writecache_word0;
							Pins_o.dqm <= writecache_dqm(1 downto 0);
						end if;

					when ph6 => -- Next word of burst write
						if sdram_slot1=writecache then
							datain <= writecache_word1;
							Pins_o.dqm <= writecache_dqm(3 downto 2);
						end if;

					when ph7 => -- third word of burst write
						if sdram_slot1=writecache then
							datain <= writecache_word2;
							Pins_o.dqm <= writecache_dqm(5 downto 4);
						end if;
				
					when ph8 =>
						if sdram_slot1=writecache then
							datain <= writecache_word3;
							Pins_o.dqm <= writecache_dqm(7 downto 6);
							writecache_burst<='0';
						end if;

					when ph9 =>
						if sdram_slot1=port1 then
							readcache_fill<='1';
						end if;

					when ph10 => -- Second access slot...
						cas_sd_cs <= '0';  -- Only the lowest bit has any significance...
						cas_sd_ras <= '1';
						cas_sd_cas <= '1';
						cas_sd_we <= '1';
						
						cas_dqm <= "00";

						sdram_slot2<=idle;
						if refreshpending='1' or sdram_slot1=refresh then
							sdram_slot2<=idle;
						elsif writecache_req='1'
								and sdram_slot1/=writecache
								and (writecache_addr(4 downto 3)/=slot1_bank or sdram_slot1=idle)
								and (writecache_addr(4 downto 3)/=vga_reserveaddr(4 downto 3)
									or vga_reservebank='0') then  -- Safe to use this slot with this bank?
							sdram_slot2<=writecache;
							Pins_o.addr <= writecache_addr(25 downto 13);
							Pins_o.ba <= writecache_addr(4 downto 3);
							slot2_bank <= writecache_addr(4 downto 3);
							cas_dqm <= port1_i.uds&port1_i.lds;
							casaddr <= writecache_addr&"000";
--							datain <= writecache_word0;
							cas_sd_cas <= '0';
							cas_sd_we <= '0';
							sdram_slot2_readwrite <= '0';
							Pins_o.cs <= '0'; --ACTIVE
							Pins_o.ras <= '0';
						elsif readcache_req='1' -- port1_i.req='1' and port1_i.wr='1'
								and (port1_i.addr(4 downto 3)/=slot1_bank or sdram_slot1=idle)
								and (port1_i.addr(4 downto 3)/=vga_reserveaddr(4 downto 3)
									or vga_reservebank='0') then  -- Safe to use this slot with this bank?
							sdram_slot2<=port1;
							Pins_o.addr <= port1_i.addr(25 downto 13);
							Pins_o.ba <= port1_i.addr(4 downto 3);
							slot2_bank <= port1_i.addr(4 downto 3);
							cas_dqm <= "00";
							casaddr <= port1_i.addr(31 downto 1) & "0"; -- We no longer mask off LSBs for burst read
--							datain <= port1_i.data;
							cas_sd_cas <= '0';
							cas_sd_we <= '1';
							sdram_slot2_readwrite <= '1';
							Pins_o.cs <= '0'; --ACTIVE
							Pins_o.ras <= '0';
						end if;

						-- Fill - takes effect next cycle.
						if sdram_slot1=port1 then
							readcache_fill<='1';
						end if;
				
					when ph11 =>
						if sdram_slot1=port1 then
							readcache_fill<='1';
						end if;
						if sdram_slot2=writecache then
							writecache_burst<='1';  -- close the door on new write data
						end if;

					when ph12 =>
						if sdram_slot1=port1 then
							readcache_fill<='1';
						end if;
						
					-- Phase 13 - CAS for second window...
					when ph13 =>
						if sdram_slot2/=idle then
							Pins_o.addr <=  "001" & casaddr(12 downto 5) & casaddr(2 downto 1) ;--auto precharge
							Pins_o.ba <= casaddr(4 downto 3);
							Pins_o.cs <= cas_sd_cs; 

							Pins_o.dqm <= cas_dqm;

							Pins_o.ras <= cas_sd_ras;
							Pins_o.cas <= cas_sd_cas;
							Pins_o.we  <= cas_sd_we;
							if sdram_slot2=writecache then
								datain <= writecache_word0;
								Pins_o.dqm <= writecache_dqm(1 downto 0);
							end if;
						end if;

					when ph14 => -- Second word of burst write
						if sdram_slot2=writecache then
							datain <= writecache_word1;
							Pins_o.dqm <= writecache_dqm(3 downto 2);
						end if;

					when ph15 => -- Third word of burst write
						if sdram_slot2=writecache then
							datain <= writecache_word2;
							Pins_o.dqm <= writecache_dqm(5 downto 4);
						end if;

					when ph0 => -- Final word of burst write
						if sdram_slot2=writecache then
							datain <= writecache_word3;
							Pins_o.dqm <= writecache_dqm(7 downto 6);
							writecache_burst<='0';
						end if;

					when ph1 =>
						if sdram_slot2=port1 then
							readcache_fill<='1';
						end if;

					when others =>
						null;
						
				end case;

			END IF;
--			Pins_o.addr(7)<='0'; -- Simulate badly soldered pin...
		END IF;	
	END process;		
END;

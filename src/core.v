`timescale 1ns / 10ps

`include "memory.v"
`include "alu.v"
`include "regfile.v"
`include "instrmem.v"
`include "control.v"
`include "aluctrl.v"

`include "pipeline_regs/q1q2.v"
`include "pipeline_regs/q2q3.v"
`include "pipeline_regs/q3q4.v"
`include "pipeline_regs/q4q5.v"
`include "pipeline_regs/q5q6.v"

/*
	top level wrapper for a 5 stage RISC-V pipeline

	q1 (assumed)
	q2 instruction decode / register file
	q3 execute / ALU
	q4 memory access
	q5 write back
	q6 "the instruction that just completed"
*/

module core (
    input clk,
    input rst_n
);

  localparam CTRL_WIDTH = 16;
  localparam CTRL_ALUOP1 = 7;
  localparam CTRL_ALUOP0 = 6;
  localparam CTRL_ALUSRC = 5;
  localparam CTRL_IS_BRANCH = 4;
  localparam CTRL_MEM_RE = 3;
  localparam CTRL_MEM_WE = 2;
  localparam CTRL_REG_WR_EN = 1;
  localparam CTRL_IS_MEM_TO_REG = 0;

  localparam OP_RTYPE = 7'b0110011;
  localparam OP_ITYPE = 7'b0010011;
  localparam OP_LOAD = 7'b0000011;
  localparam OP_STORE = 7'b0100011;

  localparam FORWARD_Q2 = 2'b00; // use value read from regfile
  localparam FORWARD_Q4 = 2'b01; // use value from prev alu_out
  localparam FORWARD_Q5 = 2'b10; // use value from prev prev alu_out or mem_rdata
  localparam FORWARD_Q6 = 2'b11; // use value from prev prev prev alu_out

  /*
instruction fetch pipeline stage
*/

  wire [31:0] pc;
  reg [31:0] pc_incr;
  wire [31:0] instr_q1;

  wire [31:0] pc_incr_q2;
  wire [31:0] instr_q2;

  /* q1 out, q2 in */
  wire [4:0] rs1 = instr_q2[19:15];
  wire [4:0] rs2 = instr_q2[24:20];
  wire [4:0] rd = instr_q2[11:7];
  wire [2:0] funct3 = instr_q2[14:12];
  wire [6:0] funct7 = instr_q2[31:25];
  wire [6:0] opcode = instr_q2[6:0];
  wire [11:0] imm = instr_q2[31:20];
  wire [6:0] imm_upper = instr_q2[31:25];
  wire [4:0] imm_lower = instr_q2[11:7];
  wire [4:0] reg_rd_port1 = rs1;
  wire [4:0] reg_rd_port2 = rs2;
  wire [31:0] reg_rd_data1_q2;
  wire [31:0] reg_rd_data2_q2;
  wire [4:0] reg_wr_port_q2 = rd;

  /* q2 out, q3 in */
  wire [31:0] instr_q3;
  wire [6:0] opcode_q3 = instr_q3[6:0];
  wire [4:0] rd_q3 = instr_q3[11:7];
  wire [4:0] rs1_q3 = instr_q3[19:15];
  wire [4:0] rs2_q3 = instr_q3[24:20];  
  wire [3:0] funct_q2 = {funct7[5], funct3};  // this can be cleaned up (absorbed into instr_q3s)
  wire [31:0] imm_se_q2;
  wire [3:0] funct_q3;
  wire [31:0] alu_out_q3;
  wire [31:0] imm_se_q3;
  wire [31:0] pc_incr_q3;
  wire [31:0] reg_rd_data1_q3;
  wire [31:0] reg_rd_data2_q3;
  wire [4:0] reg_wr_port_q3;

  /* ALU and ALU control */
  wire [3:0] aluctrl_ctrl;
  reg [31:0] alu_in1_forwarded;
  reg [31:0] alu_in2_forwarded;
  wire [31:0] alu_in1 = reg_rd_data1_q3;
  wire [31:0] alu_in2 = ctrl_q3[CTRL_ALUSRC] ? reg_rd_data2_q3 : imm_se_q3;
  wire [1:0] ctrl_aluop = {ctrl_q3[CTRL_ALUOP1], ctrl_q3[CTRL_ALUOP0]};

  /* q3 out, q4 in */
  wire [31:0] mem_rdata_q4;
  wire [31:0] instr_q4;
  wire [6:0] opcode_q4 = instr_q4[6:0];
  wire [4:0] rd_q4 = instr_q4[11:7];
  wire [4:0] rs1_q4 = instr_q4[19:15];
  wire [4:0] rs2_q4 = instr_q4[24:20];
  wire [31:0] pc_next_q3 = (imm_se_q3 << 2) | pc_incr_q3;
  wire [31:0] pc_next_q4;
  wire [4:0] reg_wr_port_q4;
  wire [31:0] reg_rd_data2_q4;
  wire [31:0] alu_out_q4;

  /* q4 out, q5 in */
  wire [31:0] alu_out_q5;
  wire [31:0] instr_q5;
  wire [6:0] opcode_q5 = instr_q5[6:0];
  wire [4:0] rd_q5 = instr_q5[11:7];
  wire [4:0] rs1_q5 = instr_q5[19:15];
  wire [4:0] rs2_q5 = instr_q5[24:20];
  wire [31:0] mem_rdata_q5;
  wire [4:0] reg_wr_port_q5;
  wire [31:0] reg_wr_data_q5 = ctrl_q5[CTRL_IS_MEM_TO_REG] ? mem_rdata_q5 : alu_out_q5;

  /* data memory */
  reg [31:0] mem_wdata_forwarded;

  /* main control unit */
  wire [CTRL_WIDTH-1:0] ctrl_q2;
  wire [CTRL_WIDTH-1:0] ctrl_q3;
  wire [CTRL_WIDTH-1:0] ctrl_q4;
  wire [CTRL_WIDTH-1:0] ctrl_q5;
  wire [CTRL_WIDTH-1:0] ctrl_q6;

  /* forwarding unit */
  reg [1:0] forward_alu_in1;
  reg [1:0] forward_alu_in2;
  reg [1:0] forward_mem_wdata;

  /* q5 out, q6 in */
  // note: q6 isn't actually a named pipeline stage, it's really temporary stoarge for WB variables
  // due to my naming convention, q5 is the 5th pipeline stage (WB) but the pipeline reg values are from the prev. stage
  wire [31:0] instr_q6;
  wire [6:0] opcode_q6 = instr_q6[6:0];
  wire [4:0] rd_q6 = instr_q6[11:7];
  wire [4:0] rs1_q6 = instr_q6[19:15];
  wire [4:0] rs2_q6 = instr_q6[24:20]; 
  wire [31:0] alu_out_q6;

  instrmem #(
      .HARDCODED(1)
  ) instrmem_u (
      .clk    (clk),
      .rst_n  (rst_n),
      .pc_i   (pc),
      .instr_o(instr_q1)
  );

  alu alu_u (
      .alu_a_i       (alu_in1_forwarded),
      .alu_b_i       (alu_in2_forwarded),
      .aluctrl_ctrl_i(aluctrl_ctrl),
      .alu_out_o     (alu_out_q3)
  );

  regfile regfile_u (
      .clk             (clk),
      .rst_n           (rst_n),
      .rd_port1_i      (reg_rd_port1),
      .rd_port2_i      (reg_rd_port1),
      .rd_data1_o      (reg_rd_data1_q2),
      .rd_data2_o      (reg_rd_data2_q2),
      .wr_port_i       (reg_wr_port_q5),
      .wr_data_i       (reg_wr_data_q5),
      .ctrl_reg_wr_en_i(ctrl_q5[CTRL_REG_WR_EN])
  );

  control #(
      .CTRL_WIDTH(CTRL_WIDTH)
  ) control_u (
      .opcode_i(opcode),
      .ctrl_o  (ctrl_q2)
  );

  aluctrl alucontrol_u (
      .ctrl_aluop_i  (ctrl_aluop),
      .funct_i       (funct_q3),
      .aluctrl_ctrl_o(aluctrl_ctrl)
  );

  memory memory_u (
      .clk          (clk),
      .rst_n        (rst_n),
      .ctrl_mem_re_i(ctrl_q4[CTRL_MEM_RE]),
      .ctrl_mem_we_i(ctrl_q4[CTRL_MEM_WE]),
      .mem_addr_i   (alu_out_q4),
      .mem_wdata_i  (mem_wdata_forwarded),
      .mem_rdata_o  (mem_rdata_q4)
  );


  /*
pipeline registers
*/

  q1q2 q1q2_u (
      .clk      (clk),
      .rst_n    (rst_n),
      .pc_incr_i(pc_incr),
      .pc_incr_o(pc_incr_q2),
      .instr_i  (instr_q1),
      .instr_o  (instr_q2)
  );

  q2q3 #(
      .CTRL_WIDTH(CTRL_WIDTH)
  ) q2q3_u (
      .clk           (clk),
      .rst_n         (rst_n),
      .imm_se_i      (imm_se_q2),
      .imm_se_o      (imm_se_q3),
      .pc_incr_i     (pc_incr_q2),
      .pc_incr_o     (pc_incr_q3),
      .reg_rd_data1_i(reg_rd_data1_q2),
      .reg_rd_data1_o(reg_rd_data1_q3),
      .reg_rd_data2_i(reg_rd_data2_q2),
      .reg_rd_data2_o(reg_rd_data2_q3),
      .reg_wr_port_i (reg_wr_port_q2),
      .reg_wr_port_o (reg_wr_port_q3),
      .ctrl_q2_i     (ctrl_q2),
      .ctrl_q2_o     (ctrl_q3),
      .funct_i       (funct_q2),
      .funct_o       (funct_q3),
      .instr_i       (instr_q2),
      .instr_o       (instr_q3)
  );

  q3q4 #(
      .CTRL_WIDTH(CTRL_WIDTH)
  ) q3q4_u (
      .clk           (clk),
      .rst_n         (rst_n),
      .pc_next_i     (pc_next_q3),
      .pc_next_o     (pc_next_q4),
      .reg_wr_port_i (reg_wr_port_q3),
      .reg_wr_port_o (reg_wr_port_q4),
      .reg_rd_data2_i(reg_rd_data2_q3),
      .reg_rd_data2_o(reg_rd_data2_q4),
      .alu_out_i     (alu_out_q3),
      .alu_out_o     (alu_out_q4),
      .ctrl_q3_i     (ctrl_q3),
      .ctrl_q3_o     (ctrl_q4),
      .instr_i       (instr_q3),
      .instr_o       (instr_q4)
  );

  q4q5 #(
      .CTRL_WIDTH(CTRL_WIDTH)
  ) q4q5_u (
      .clk          (clk),
      .rst_n        (rst_n),
      .alu_out_i    (alu_out_q4),
      .alu_out_o    (alu_out_q5),
      .reg_wr_port_i(reg_wr_port_q4),
      .reg_wr_port_o(reg_wr_port_q5),
      .mem_rdata_i  (mem_rdata_q4),
      .mem_rdata_o  (mem_rdata_q5),
      .ctrl_q4_i    (ctrl_q4),
      .ctrl_q4_o    (ctrl_q5),
      .instr_i      (instr_q4),
      .instr_o      (instr_q5)
  );

  q5q6 #(
      .CTRL_WIDTH(CTRL_WIDTH)
  ) q5q6_u (
      .clk          (clk),
      .rst_n        (rst_n),
      .ctrl_q5_i    (ctrl_q5),
      .ctrl_q5_o    (ctrl_q6),
      .instr_i      (instr_q5),
      .instr_o      (instr_q6),
      .alu_out_i    (alu_out_q5),
      .alu_out_o    (alu_out_q6)
  );

  /*
sign extension
note to self: SRLI, SLLI, SRAI use a specialization of the I-format
but this does not affect our logic as a sign extension
does not affect the lower 5 bits of the immediate
which is what we actually care about
*/
  assign imm_se_q2 = {{20{imm[11]}}, imm};

  assign pc = ctrl_q4[CTRL_IS_BRANCH] ? pc_next_q4 : pc_incr;

  always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
      pc_incr <= 0;
    end else begin
      pc_incr <= pc_incr + 4;
    end
  end

  // simple forwarding logic (forwarding unit)
  // hazards a and b occur in the execution stage
  reg hazard_a_in1, hazard_b_in1, hazard_a_in2, hazard_b_in2;
  reg hazard_c, hazard_d;
  always @(*) begin
  	forward_alu_in1 = FORWARD_Q2;
  	forward_alu_in2 = FORWARD_Q2;
  	forward_mem_wdata = FORWARD_Q2;
  	/*
  		add x1, x2, x3
  		add x4, x1, x5 // hazard a)
  		add x6, x7, x1 // hazard b)

  		add x1, x1, x2
  		add x1, x1, x3 // hazard a)
  		add x1, x1, x4 // hazard b.2) requires values of x1 from 2nd instr
  	
		add x1, x2, x3
		sw x1, x3 // x3: hazard a, x1: hazard c, result required for MEM but not available until WB
		sw x1, x4 // x1: hazard d, result required for MEM but only available after WB

		lw x1, x2
		sw x1, x3 // hazard c: x1 forwarded from MEM/WB(q5) regs
  	*/
  	hazard_a_in1 = ctrl_q4[CTRL_REG_WR_EN] && rd_q4 === rs1_q3 && rd_q4 !== 5'b0; // EX/MEM hazard
  	hazard_b_in1 = ctrl_q5[CTRL_REG_WR_EN] && rd_q5 === rs1_q3 && rd_q5 !== 5'b0;  // MEM/WB hazard
  	hazard_a_in2 = ctrl_q4[CTRL_REG_WR_EN] && rd_q4 === rs2_q3 && rd_q4 !== 5'b0;
  	hazard_b_in2 = ctrl_q5[CTRL_REG_WR_EN] && rd_q5 === rs2_q3 && rd_q5 !== 5'b0;
  	hazard_c = ctrl_q5[CTRL_REG_WR_EN] && rd_q5 === rs2_q4 && rd_q5 !== 5'b0;
  	hazard_d = ctrl_q6[CTRL_REG_WR_EN] && rd_q6 === rs2_q4 && rd_q6 !== 5'b0;
  	if (hazard_a_in1) forward_alu_in1 = FORWARD_Q4;
  	if (hazard_b_in1 && !hazard_a_in1) forward_alu_in1 = FORWARD_Q5; // always forward most recent value
  	if (hazard_a_in2) forward_alu_in2 = FORWARD_Q4;
  	if (hazard_b_in2 && !hazard_a_in2) forward_alu_in2 = FORWARD_Q5;
  	if (hazard_c) forward_mem_wdata = FORWARD_Q5;
  	if (hazard_d) forward_mem_wdata = FORWARD_Q6;
  end

  always @(*) begin
    case (forward_alu_in1)
          FORWARD_Q2: alu_in1_forwarded = alu_in1;
          FORWARD_Q4: alu_in1_forwarded = alu_out_q4;
          FORWARD_Q5: alu_in1_forwarded = alu_out_q5;
    endcase
  end

  always @(*) begin
    case (forward_alu_in2)
          FORWARD_Q2: alu_in2_forwarded = alu_in2;
          FORWARD_Q4: alu_in2_forwarded = alu_out_q4;
          FORWARD_Q5: alu_in2_forwarded = alu_out_q5;
    endcase
  end

  always @(*) begin
    case (forward_mem_wdata)
          FORWARD_Q2: mem_wdata_forwarded = reg_rd_data2_q4;
          FORWARD_Q5: mem_wdata_forwarded = alu_out_q5;
          FORWARD_Q6: mem_wdata_forwarded = alu_out_q6;
    endcase
  end

  // hazard detection unit
endmodule

module booth_multiplier(
  input clk,
  input rst_n,

  input start_i,
  input [31:0] a_i,
  input [31:0] b_i,
  input signed_a_i,
  input signed_b_i,
  input high_half_i,

  output reg busy_o,
  output reg done_o,
  output reg [31:0] result_o
);

  // 將有號／無號輸入，統一表示成 33 位元有號數。
  wire signed [32:0] a_ext;
  wire signed [32:0] b_ext;

  assign a_ext = {signed_a_i & a_i[31], a_i};
  assign b_ext = {signed_b_i & b_i[31], b_i};

  // 運算狀態。
  reg signed [67:0] accum_q;
  reg signed [67:0] multiplicand_q;
  reg signed [33:0] multiplier_q;
  reg [4:0] count_q;
  reg high_half_q;

  // 本輪部分積，以及加入部分積後的新總和。
  reg signed [67:0] partial_product;
  reg signed [67:0] accum_next;

  // Radix-4 Booth 編碼。
  always @(*) begin
    partial_product = 68'sd0;

    case (multiplier_q[2:0])
      3'b000, 3'b111:
        partial_product = 68'sd0;

      3'b001, 3'b010:
        partial_product = multiplicand_q;

      3'b011:
        partial_product = multiplicand_q <<< 1;

      3'b100:
        partial_product = -(multiplicand_q <<< 1);

      3'b101, 3'b110:
        partial_product = -multiplicand_q;

      default:
        partial_product = 68'sd0;
    endcase

    accum_next = accum_q + partial_product;
  end

  // 啟動、逐輪運算，以及結果輸出。
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_o         <= 1'b0;
      done_o         <= 1'b0;
      result_o       <= 32'b0;
      accum_q        <= 68'sd0;
      multiplicand_q <= 68'sd0;
      multiplier_q   <= 34'sd0;
      count_q        <= 5'd0;
      high_half_q    <= 1'b0;
    end else begin
      // done_o 只在完成時維持一個 clock。
      done_o <= 1'b0;

      if (start_i && !busy_o) begin
        // 接受新運算並保存輸入。
        busy_o         <= 1'b1;
        accum_q        <= 68'sd0;
        multiplicand_q <= {{35{a_ext[32]}}, a_ext};
        multiplier_q   <= {b_ext, 1'b0};
        count_q        <= 5'd0;
        high_half_q    <= high_half_i;

      end else if (busy_o) begin
        accum_q <= accum_next;

        // 從 0 數到 16，共執行 17 輪。
        if (count_q == 5'd16) begin
          busy_o <= 1'b0;
          done_o <= 1'b1;

          // 使用包含最後一輪部分積的新總和。
          result_o <= high_half_q
                    ? accum_next[63:32]
                    : accum_next[31:0];
        end else begin
          // 每輪前進兩個位元。
          multiplicand_q <= multiplicand_q <<< 2;
          multiplier_q   <= multiplier_q >>> 2;
          count_q        <= count_q + 5'd1;
        end
      end
    end
  end

endmodule
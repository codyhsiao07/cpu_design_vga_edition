module i_cache
#(
    parameter ADDR_WIDTH  = 32,
    parameter CACHE_BYTES = 65536,// 64KB
    parameter LINE_BYTES  = 64,   // 64B
    parameter NUM_WAYS    = 2,
    parameter OFFSET_BITS = 6,      // log2(64B)
    parameter INDEX_BITS  = 9,      // 512 sets -> 9 bits
    parameter TAG_BITS    = (ADDR_WIDTH - OFFSET_BITS - INDEX_BITS),
    parameter L2_DATA_W   = 64,     // default: 64-bit beats
    parameter UNC_BASE    = 32'h0000_0000,
    parameter UNC_MASK    = 32'h0000_0000
)
(
    input                       clk,
    input                       rst_n,
    output                      perf_lookup_o,
    output                      perf_miss_o,

    input                       if_req_valid, //MEM request valid
    input  [ADDR_WIDTH-1:0]     if_req_addr, //request address pc
    output                      if_req_ready,   // 是否icache需要接收指令，如果valid=1 但 ready=0，一樣不接收新的request
    input                       if_req_kill,    //清除正在pipeline的指令只有2條或以上，非flush 全部

    output reg                  if_resp_valid,  //我要回傳指令給decoder
    input                       if_resp_ready,  //decoder 是否可以接收指令
    output reg [31:0]           if_resp_inst,   //回傳指令
    output reg [ADDR_WIDTH-1:0] if_resp_pc,     //回傳pc
    output reg                  if_resp_err,    //回傳錯誤

    input                       ic_flush_req,// flush cache中全部指令
    output reg                  ic_flush_ack,//flush 已完成
    input                       ic_inv_valid,//指定需要flush的部分，不是全部flush
    input                       ic_inv_all,// 1：代表 flush-all , 0: 單一目標
    input  [INDEX_BITS-1:0]     ic_inv_index,// 指定 index
    input                       ic_inv_way,//指定 way
    output reg                  ic_inv_ack,// flush 完成

    output reg                  l2_req_valid,//確認是否要傳送指令
    input                       l2_req_ready,//l2 是否可以接收指令
    output reg [ADDR_WIDTH-1:0] l2_req_addr,// 傳送地址
    output reg [1:0]            l2_req_cmd,// 00=LINE_FILL, 01=UC_READ 取一個指令 word（通常 4B）
    output reg [2:0]            l2_req_size,// log2(bytes/beat) 是指我需要的找的指令再l2的大小 
    //如果 L2_DATA_W = 64-bit → 一拍回 8 bytes→ bytes_per_beat = 8 → l2_req_size = log2(8) = 3（3'b011)    
    //如果 L2_DATA_W = 32-bit → 一拍回 4 bytes→ l2_req_size = 2（3'b010）
    output reg [7:0]            l2_req_len,// beats-1 是指我要回傳幾個beat才可以回傳完

    input                       l2_rsp_valid,// L2 表示「這一拍有回來一個 beat 的資料」
    output reg                  l2_rsp_ready,// 我這一拍是否準備好接 response beat
    input  [L2_DATA_W-1:0]      l2_rsp_data,// 回來的資料 beat，寬度 = L2_DATA_W 
    //如果是LINE_FILL : 不是一次回 64B，而是分 8 拍回完， 每拍8B
    //如果是UC_READ : 那一拍回來是 8 bytes，你會用其中的 4 bytes 當指令
    input                       l2_rsp_last,//表示 這個 beat 是該次 burst 的最後一拍。
    //LINE_FILL：第 8 個 beat（或第 16 個 beat）時 last=1
    //UC_READ：通常第一拍就 last=1
    input                       l2_rsp_err//表示這筆讀取有錯
);

    // ----------------------------
    // Derived constants
    // ----------------------------
    localparam LINE_BITS = LINE_BYTES * 8;
    localparam NUM_SETS  = (CACHE_BYTES / (LINE_BYTES * NUM_WAYS)); // 512
    localparam [31:0] INSTR_NOP = 32'h0000_0013;

    // ----------------------------
    // Cache arrays (simple reg arrays)
    // ----------------------------
    (* ram_style = "block" *) reg [LINE_BITS-1:0] data_way0 [0:NUM_SETS-1];
    (* ram_style = "block" *) reg [LINE_BITS-1:0] data_way1 [0:NUM_SETS-1];

    reg [TAG_BITS-1:0]  tag_way0  [0:NUM_SETS-1];
    reg [TAG_BITS-1:0]  tag_way1  [0:NUM_SETS-1];

    reg                 valid_way0[0:NUM_SETS-1];
    reg                 valid_way1[0:NUM_SETS-1];

    reg                 plru_bit  [0:NUM_SETS-1]; // 2-way pseudo LRU: 0/1 indicates victim

    // ----------------------------
    // Helper: uncacheable check
    // ----------------------------
    wire is_uncached_req;
    assign is_uncached_req = (((if_req_addr & UNC_MASK) == (UNC_BASE & UNC_MASK)) && (UNC_MASK != 0));
    // UNC_BASE & UNC_MASK 代表取出兩著相同的高位，因為只要高位相同，低位就一定落在此範圍內
    // 然後再和if_req_addr & UNC_MASK看看兩個相同的高位是否相同，如果相同代表落在MASK範圍內
    // Kill toggle (drop in-flight response but do NOT cancel refill)
    // ----------------------------
    reg kill_prev; //記住「上一拍的 if_req_kill 是 0 還是 1」
    reg [7:0] kill_toggle;//如果出現if_req_kill就會翻轉

    // ----------------------------
    // IF1/IF2 pipeline registers
    // ----------------------------
    reg                  s1_valid;
    reg [ADDR_WIDTH-1:0]  s1_pc;
    reg                  s1_uncached;
    reg [7:0]            s1_kill_tag;

    reg                  s2_valid;
    reg [ADDR_WIDTH-1:0]  s2_pc;
    reg                  s2_uncached;
    reg [7:0]            s2_kill_tag;

    reg [TAG_BITS-1:0]   s2_tag0, s2_tag1;
    reg                  s2_v0, s2_v1;
    reg [LINE_BITS-1:0]  s2_d0, s2_d1;

    wire [INDEX_BITS-1:0] s1_index;
    wire [TAG_BITS-1:0]   s2_req_tag;
    wire [INDEX_BITS-1:0] s2_index;
    wire [3:0]            s2_word_sel; // 16 words per 64B line (32-bit inst)

    // PC[31:15]    PC[14:6]     PC[5:0]
    //  TAG          INDEX        OFFSET
    assign s1_index   = s1_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
    assign s2_index   = s2_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
    assign s2_req_tag = s2_pc[ADDR_WIDTH-1:OFFSET_BITS+INDEX_BITS];
    assign s2_word_sel = s2_pc[OFFSET_BITS-1:2];  // [5:2]
    //PC[1:0]：byte in word（對 32-bit 指令通常固定為 00，代表 4-byte 對齊）
    //PC[5:2]：word index（0~15）
    // Word picker: 512b line -> 32b word (Verilog-2001 safe)
    // ----------------------------
    function [31:0] pick_word32;
        input [LINE_BITS-1:0] line;
        input [3:0] wsel;
        begin
            case (wsel)
                4'd0:  pick_word32 = line[31:0];
                4'd1:  pick_word32 = line[63:32];
                4'd2:  pick_word32 = line[95:64];
                4'd3:  pick_word32 = line[127:96];
                4'd4:  pick_word32 = line[159:128];
                4'd5:  pick_word32 = line[191:160];
                4'd6:  pick_word32 = line[223:192];
                4'd7:  pick_word32 = line[255:224];
                4'd8:  pick_word32 = line[287:256];
                4'd9:  pick_word32 = line[319:288];
                4'd10: pick_word32 = line[351:320];
                4'd11: pick_word32 = line[383:352];
                4'd12: pick_word32 = line[415:384];
                4'd13: pick_word32 = line[447:416];
                4'd14: pick_word32 = line[479:448];
                4'd15: pick_word32 = line[511:480];
                default: pick_word32 = INSTR_NOP; // NOP (ADDI x0,x0,0) as safe default
            endcase
        end
    endfunction

    function [31:0] pick_uc_word32;
        input [L2_DATA_W-1:0] beat;
        input [ADDR_WIDTH-1:0] pc;
        begin
            // L2 UC_READ returns the 8-byte beat containing PC. Select the
            // correct 32-bit instruction word inside that beat.
            pick_uc_word32 = pc[2] ? beat[63:32] : beat[31:0];
        end
    endfunction

    // ----------------------------
    // Tag compare in IF2
    // ----------------------------
    wire hit0, hit1, hit;
    assign hit0 = s2_valid && s2_v0 && (s2_tag0 == s2_req_tag);
    assign hit1 = s2_valid && s2_v1 && (s2_tag1 == s2_req_tag);
    assign hit  = hit0 || hit1;
    wire drop_resp;
    assign drop_resp = (s2_kill_tag != kill_toggle); // kill happened after accept 
   //這筆 S2 的 request 是在「舊 epoch」被接受的；若之後發生過 kill（epoch 改變），就把它的 response 丟掉，避免舊路徑指令送進 decode。
    // ----------------------------
    // Miss / refill state machine
    // ----------------------------
    localparam ST_IDLE       = 3'd0;
    localparam ST_MISS_REQ   = 3'd1;
    localparam ST_WAIT_RSP   = 3'd2;
    localparam ST_WRITE_LINE = 3'd3;
    localparam ST_REPLAY1    = 3'd4;
    localparam ST_REPLAY2    = 3'd5;
    localparam ST_FLUSH      = 3'd6;
    localparam ST_DRAIN_ERR  = 3'd7;

    reg [2:0] state;

    // Hold info for miss/refill
    reg [ADDR_WIDTH-1:0] miss_pc;
    reg                  miss_uncached;
    reg [7:0]            miss_kill_tag;

    reg [ADDR_WIDTH-1:0] refill_addr_aligned;
    reg [INDEX_BITS-1:0] refill_index;
    reg                  refill_victim_way; // 0=way0, 1=way1
    reg [TAG_BITS-1:0]   refill_tag;

    reg [LINE_BITS-1:0]  refill_buf;
    reg [3:0]            refill_beat_cnt;   // for 64-bit beats: 0..7
    reg                  refill_err_q;

    // flush control
    reg                  flush_pending;
    reg [INDEX_BITS-1:0] flush_idx;

    // invalidate pending
    reg                  inv_pending;
    reg                  inv_all_pending;
    reg [INDEX_BITS-1:0] inv_index_pending;
    reg                  inv_way_pending;

    // ----------------------------
    // if_req_ready policy:
    //  - accept requests in IDLE
    //  - stall when miss/refill/flush
    //  - stall if response is holding and CPU not ready
    // ----------------------------
    assign if_req_ready = (state == ST_IDLE) && !(if_resp_valid && !if_resp_ready);

    wire accept_req;
    // Count the original tag decision once; refill replay is not a new access.
    assign perf_lookup_o = (state == ST_IDLE) && !flush_pending && !inv_pending &&
                           !(if_resp_valid && !if_resp_ready) && s2_valid && !s2_uncached;
    assign perf_miss_o = perf_lookup_o && !hit;
    assign accept_req = if_req_valid && if_req_ready && !if_req_kill;

    // ----------------------------
    // Main sequential logic
    // ----------------------------
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            // reset
            state <= ST_IDLE;

            s1_valid <= 1'b0;
            s2_valid <= 1'b0;

            if_resp_valid <= 1'b0;
            if_resp_inst  <= 32'b0;
            if_resp_pc    <= {ADDR_WIDTH{1'b0}};
            if_resp_err   <= 1'b0;

            l2_req_valid <= 1'b0;
            l2_req_addr  <= {ADDR_WIDTH{1'b0}};
            l2_req_cmd   <= 2'b00;
            l2_req_size  <= 3'b000;
            l2_req_len   <= 8'b0;
            l2_rsp_ready <= 1'b0;

            ic_flush_ack <= 1'b0;
            ic_inv_ack   <= 1'b0;

            kill_prev   <= 1'b0;
            kill_toggle <= 8'd0;

            flush_pending <= 1'b0;
            flush_idx <= {INDEX_BITS{1'b0}};

            inv_pending <= 1'b0;
            inv_all_pending <= 1'b0;
            inv_index_pending <= {INDEX_BITS{1'b0}};
            inv_way_pending <= 1'b0;
            refill_err_q <= 1'b0;

            // clear valids
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                valid_way0[i] <= 1'b0;
                valid_way1[i] <= 1'b0;
                plru_bit[i]   <= 1'b0;
            end
        end else begin
            // default pulses
            ic_flush_ack <= 1'b0;
            ic_inv_ack   <= 1'b0;

            // kill toggle edge detect
            kill_prev <= if_req_kill;
            if (if_req_kill && !kill_prev) begin
                kill_toggle <= kill_toggle + 8'd1;
                if_resp_valid <= 1'b0;
                // Drop queued response from the old control-flow epoch.
            end // 紀錄是否需要翻轉
            // response handshake
            if (if_resp_valid && if_resp_ready) begin
                if_resp_valid <= 1'b0;
            end//表示回應已經接收所以需要進行處理，不能再接收

            // latch pending flush/invalidate requests
            if (ic_flush_req) begin
                flush_pending <= 1'b1;//我收到了 flush 指令，但還沒做（或尚未開始做）
            end
            if (ic_inv_valid) begin
                inv_pending <= 1'b1;
                inv_all_pending <= ic_inv_all;
                inv_index_pending <= ic_inv_index;
                inv_way_pending <= ic_inv_way;
            end

            // default: no L2 traffic unless FSM drives it
            if (!(state == ST_MISS_REQ)) begin
                // keep valid until handshake in MISS_REQ
                if (l2_req_valid && l2_req_ready) begin
                    l2_req_valid <= 1'b0;
                end
            end

            case (state)
                // =========================
                // IDLE: accept + pipeline hit path
                // =========================
                ST_IDLE: begin
                    l2_rsp_ready <= 1'b0;

                    // if pending invalidate/flush, service it with priority
                    if (flush_pending) begin
                        flush_pending <= 1'b0;
                        flush_idx <= {INDEX_BITS{1'b0}};
                        state <= ST_FLUSH;
                    end else if (inv_pending) begin
                        inv_pending <= 1'b0;
                        if (inv_all_pending) begin
                            flush_idx <= {INDEX_BITS{1'b0}};
                            state <= ST_FLUSH;
                        end else begin
                            // single index/way invalidate (1-cycle)
                            if (inv_way_pending == 1'b0) begin
                                valid_way0[inv_index_pending] <= 1'b0;
                            end else begin
                                valid_way1[inv_index_pending] <= 1'b0;
                            end
                            ic_inv_ack <= 1'b1;
                            state <= ST_IDLE;
                        end
                    end else begin
                        // Hold IF1/IF2 when response channel is back-pressured.
                        // Without this hold, a newer response can overwrite a pending one.
                        if (if_resp_valid && !if_resp_ready) begin
                            s1_valid <= s1_valid;
                            s2_valid <= s2_valid;
                        end else begin
                            // Accept new request into IF1
                            s1_valid <= accept_req;
                            if (accept_req) begin
                                s1_pc       <= if_req_addr;
                                s1_uncached <= is_uncached_req;
                                s1_kill_tag <= kill_toggle;
                            end else begin
                                s1_pc       <= s1_pc;
                                s1_uncached <= s1_uncached;
                                s1_kill_tag <= s1_kill_tag;
                            end

                            // IF2 registers load from arrays when s1_valid
                            s2_valid <= s1_valid;
                            if (s1_valid) begin
                                // synchronous "read": capture array contents
                                s2_pc       <= s1_pc;
                                s2_uncached <= s1_uncached;
                                s2_kill_tag <= s1_kill_tag;

                                s2_tag0 <= tag_way0[s1_index];
                                s2_tag1 <= tag_way1[s1_index];
                                s2_v0   <= valid_way0[s1_index];
                                s2_v1   <= valid_way1[s1_index];
                                s2_d0   <= data_way0[s1_index];
                                s2_d1   <= data_way1[s1_index];
                            end

                            // Produce response or start miss (one cycle after s2_valid is set)
                            // Note: this is a simplified timing model; you can refine for exact cycle alignment.
                            if (s2_valid) begin
                                if (s2_uncached) begin
                                    // start UC_READ via L2 (bypass path)
                                    miss_pc       <= s2_pc;
                                    miss_uncached <= 1'b1;
                                    miss_kill_tag <= s2_kill_tag;

                                    refill_addr_aligned <= s2_pc; // UC uses exact address
                                    refill_err_q <= 1'b0;
                                    state <= ST_MISS_REQ;
                                end else if (hit) begin
                                    // hit response
                                    if (!drop_resp) begin
                                        if_resp_valid <= 1'b1;
                                        if_resp_pc    <= s2_pc;
                                        if_resp_err   <= 1'b0;
                                        if (hit0) begin
                                            if_resp_inst <= pick_word32(s2_d0, s2_word_sel);
                                            plru_bit[s2_index] <= 1'b1; // next victim tends to be way1 (simple policy)
                                        end else begin
                                            if_resp_inst <= pick_word32(s2_d1, s2_word_sel);
                                            plru_bit[s2_index] <= 1'b0; // next victim tends to be way0
                                        end
                                    end
                                    // if dropped, just do nothing (squash)
                                end else begin
                                    // miss -> start LINE_FILL
                                    miss_pc       <= s2_pc;
                                    miss_uncached <= 1'b0;
                                    miss_kill_tag <= s2_kill_tag;

                                    refill_index <= s2_index;
                                    refill_tag   <= s2_req_tag;

                                    // line aligned address
                                    refill_addr_aligned <= { s2_pc[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}} };
                                    refill_err_q <= 1'b0;

                                    // choose victim
                                    if (!s2_v0) begin
                                        refill_victim_way <= 1'b0;
                                    end else if (!s2_v1) begin
                                        refill_victim_way <= 1'b1;
                                    end else begin
                                        refill_victim_way <= plru_bit[s2_index];
                                    end

                                    state <= ST_MISS_REQ;
                                end
                            end
                        end
                    end
                end

                // =========================
                // MISS_REQ: send one L2 request (LINE_FILL or UC_READ)
                // =========================
                ST_MISS_REQ: begin
                    // drive req until handshake
                    l2_req_valid <= 1'b1; //問L2我可以傳送資料嗎

                    if (miss_uncached) begin
                        l2_req_cmd  <= 2'b01; // UC_READ
                        l2_req_addr <= refill_addr_aligned;
                        l2_req_size <= 3'b010; // 4 bytes
                        l2_req_len  <= 8'd0;
                    end else begin
                        l2_req_cmd  <= 2'b00; // LINE_FILL
                        l2_req_addr <= refill_addr_aligned;
                        l2_req_size <= 3'b011; // 8 bytes/beat for 64-bit bus
                        l2_req_len  <= 8'd7;   // 8 beats - 1
                    end

                    l2_rsp_ready <= 1'b0; //告訴L2我可以接收資料嗎

                    if (l2_req_valid && l2_req_ready) begin
                        // request accepted
                        l2_req_valid <= 1'b0;
                        l2_rsp_ready <= 1'b1;
                        refill_buf <= {LINE_BITS{1'b0}};
                        refill_beat_cnt <= 4'd0;
                        refill_err_q <= 1'b0;
                        state <= ST_WAIT_RSP;
                    end
                end

                // =========================
                // WAIT_RSP: collect beats; on last -> write line or respond UC
                // =========================
                ST_WAIT_RSP: begin
                    l2_rsp_ready <= 1'b1;

                    if (l2_rsp_valid && l2_rsp_ready) begin
                        if (l2_rsp_err)
                            refill_err_q <= 1'b1;
                        if (miss_uncached) begin
                            // UC_READ: select the correct word in the returned 8B beat.
                            if (!((miss_kill_tag) != kill_toggle)) begin
                                if_resp_valid <= 1'b1;
                                if_resp_pc    <= miss_pc;
                                if_resp_inst  <= l2_rsp_err ? INSTR_NOP :
                                                 pick_uc_word32(l2_rsp_data, miss_pc);
                                if_resp_err   <= l2_rsp_err;
                            end
                            l2_rsp_ready <= 1'b0;
                            state <= ST_IDLE;
                        end else begin
                            // LINE_FILL (assume L2_DATA_W = 64 for this skeleton)
                            case (refill_beat_cnt)
                                4'd0: refill_buf[63:0]    <= l2_rsp_data;
                                4'd1: refill_buf[127:64]  <= l2_rsp_data;
                                4'd2: refill_buf[191:128] <= l2_rsp_data;
                                4'd3: refill_buf[255:192] <= l2_rsp_data;
                                4'd4: refill_buf[319:256] <= l2_rsp_data;
                                4'd5: refill_buf[383:320] <= l2_rsp_data;
                                4'd6: refill_buf[447:384] <= l2_rsp_data;
                                4'd7: refill_buf[511:448] <= l2_rsp_data;
                                default: refill_buf <= refill_buf;
                            endcase

                            if (l2_rsp_err) begin
                                // Do not install a failed or short line fill into I$.
                                // Return a safe instruction with if_resp_err asserted.
                                refill_err_q <= 1'b1;
                                if (!((miss_kill_tag) != kill_toggle)) begin
                                    if_resp_valid <= 1'b1;
                                    if_resp_pc    <= miss_pc;
                                    if_resp_inst  <= INSTR_NOP;
                                    if_resp_err   <= 1'b1;
                                end
                                if (l2_rsp_last) begin
                                    l2_rsp_ready <= 1'b0;
                                    state <= ST_IDLE;
                                end else begin
                                    l2_rsp_ready <= 1'b1;
                                    state <= ST_DRAIN_ERR;
                                end
                            end else if (l2_rsp_last && (refill_beat_cnt != 4'd7)) begin
                                // Do not install a failed or short line fill into I$.
                                // Return a safe instruction with if_resp_err asserted.
                                refill_err_q <= 1'b1;
                                if (!((miss_kill_tag) != kill_toggle)) begin
                                    if_resp_valid <= 1'b1;
                                    if_resp_pc    <= miss_pc;
                                    if_resp_inst  <= INSTR_NOP;
                                    if_resp_err   <= 1'b1;
                                end
                                l2_rsp_ready <= 1'b0;
                                state <= ST_IDLE;
                            end else if (l2_rsp_last) begin
                                l2_rsp_ready <= 1'b0;
                                state <= ST_WRITE_LINE;
                            end else begin
                                refill_beat_cnt <= refill_beat_cnt + 4'd1;
                            end
                        end
                    end
                end

                ST_DRAIN_ERR: begin
                    l2_rsp_ready <= 1'b1;
                    if (l2_rsp_valid && l2_rsp_ready && l2_rsp_last) begin
                        l2_rsp_ready <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                // =========================
                // WRITE_LINE: Data -> Tag -> Valid (atomic in this skeleton)
                // =========================
                ST_WRITE_LINE: begin
                    if (refill_victim_way == 1'b0) begin
                        data_way0[refill_index]  <= refill_buf;
                        tag_way0[refill_index]   <= refill_tag;
                        valid_way0[refill_index] <= 1'b1;
                        plru_bit[refill_index]   <= 1'b1;
                    end else begin
                        data_way1[refill_index]  <= refill_buf;
                        tag_way1[refill_index]   <= refill_tag;
                        valid_way1[refill_index] <= 1'b1;
                        plru_bit[refill_index]   <= 1'b0;
                    end
                    state <= ST_REPLAY1;
                end

                // =========================
                // REPLAY: do a normal lookup for miss_pc to produce response
                // =========================
                ST_REPLAY1: begin
                    // load s2 regs directly for replay (skip s1 for simplicity)
                    s2_valid <= 1'b1;
                    s2_pc <= miss_pc;
                    s2_uncached <= 1'b0;
                    s2_kill_tag <= miss_kill_tag;

                    s2_tag0 <= tag_way0[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_tag1 <= tag_way1[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_v0   <= valid_way0[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_v1   <= valid_way1[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_d0   <= data_way0[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_d1   <= data_way1[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];

                    state <= ST_REPLAY2;
                end

                ST_REPLAY2: begin
                    // should hit after refill
                    if (hit) begin
                        if (!((s2_kill_tag) != kill_toggle)) begin
                            if_resp_valid <= 1'b1;
                            if_resp_pc    <= s2_pc;
                            if_resp_err   <= refill_err_q;
                            if (hit0) begin
                                if_resp_inst <= pick_word32(s2_d0, s2_word_sel);
                                plru_bit[s2_index] <= 1'b1;
                            end else begin
                                if_resp_inst <= pick_word32(s2_d1, s2_word_sel);
                                plru_bit[s2_index] <= 1'b0;
                            end
                        end
                    end else begin
                        // unexpected: treat as error / or retry
                        if_resp_valid <= 1'b1;
                        if_resp_pc    <= s2_pc;
                        if_resp_inst  <= INSTR_NOP;
                        if_resp_err   <= 1'b1;
                    end
                    s2_valid <= 1'b0;
                    state <= ST_IDLE;
                end

                // =========================
                // FLUSH: clear all valid bits (one set per cycle)
                // =========================
                ST_FLUSH: begin
                    // stall fetch implicitly since state != IDLE
                    valid_way0[flush_idx] <= 1'b0;
                    valid_way1[flush_idx] <= 1'b0;

                    if (flush_idx == (NUM_SETS-1)) begin
                        ic_flush_ack <= 1'b1;
                        ic_inv_ack   <= 1'b1; // if it was inv_all, ok to also pulse
                        state <= ST_IDLE;
                    end else begin
                        flush_idx <= flush_idx + {{(INDEX_BITS-1){1'b0}}, 1'b1};
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
            // Redirect can coincide with the cycle that PRODUCES a response.
            // Epoch comparisons above see the old tag until this clock edge;
            // cancel that newly produced response as well as an already held one.
            if (if_req_kill) if_resp_valid <= 1'b0;
        end
    end

endmodule

// Three ordered fetch slots, independent lookup and line-fill work records.
// The legacy i_cache above remains the FETCH_OVERLAP_EN=0 implementation.
// Exactly one burst uses the ordinary L2 port. A separate read-only L2 hit
// probe permits hit-under-miss; probe misses queue for the ordinary port.
module i_cache_overlap #(
    parameter ADDR_WIDTH=32, CACHE_BYTES=8192, INDEX_BITS=6,
    parameter TAG_BITS=ADDR_WIDTH-6-INDEX_BITS,
    parameter UNC_BASE=32'h0, UNC_MASK=32'h0
) (
    input clk, rst_n,
    output perf_lookup_o, perf_miss_o,
    input if_req_valid, input [ADDR_WIDTH-1:0] if_req_addr,
    output if_req_ready, input if_req_kill,
    output if_resp_valid, input if_resp_ready,
    output [31:0] if_resp_inst, output [ADDR_WIDTH-1:0] if_resp_pc,
    output if_resp_err,
    output l2_req_valid, input l2_req_ready,
    output [ADDR_WIDTH-1:0] l2_req_addr,
    output [1:0] l2_req_cmd, output [2:0] l2_req_size, output [7:0] l2_req_len,
    input l2_rsp_valid, output l2_rsp_ready, input [63:0] l2_rsp_data,
    input l2_rsp_last, l2_rsp_err,
    output probe_valid, input probe_ready, output [31:0] probe_addr,
    input probe_rsp_valid, output probe_rsp_ready, input probe_rsp_hit,
    input [511:0] probe_rsp_line
);
    localparam SETS=CACHE_BYTES/128;
    localparam Q_NEW=0, Q_LOOKUP=1, Q_WAIT=2, Q_DONE=3;
    localparam M_FREE=0, M_PROBE=1, M_PROBING=2, M_LOWER=3,
               M_REQUEST=4, M_RECEIVE=5, M_FINISH=6;
    (* ram_style="block" *) reg [511:0] data0[0:SETS-1], data1[0:SETS-1];
    reg [TAG_BITS-1:0] tag0[0:SETS-1], tag1[0:SETS-1];
    reg v0[0:SETS-1], v1[0:SETS-1], lru[0:SETS-1];

    reg [2:0] q_valid;
    reg [1:0] q_state[0:2], q_miss[0:2];
    reg [31:0] q_pc[0:2], q_inst[0:2];
    reg [2:0] q_err;
    reg [1:0] head, tail, count;
    reg [2:0] m_state[0:2];
    reg [31:0] m_addr[0:2];
    reg [511:0] m_data[0:2];
    reg [2:0] m_err, m_uncached;
    reg [3:0] beat;
    reg main_busy, probe_busy;
    reg [1:0] main_id, probe_id, main_rr, probe_rr, finish_rr;
    reg lookup_valid;
    reg [1:0] lookup_slot;
    reg [31:0] lookup_pc;
    reg [TAG_BITS-1:0] lookup_tag0, lookup_tag1;
    reg lookup_v0, lookup_v1;
    reg [511:0] lookup_data0, lookup_data1;

    function [1:0] next_slot;
        input [1:0] n;
        begin next_slot=(n==2)?0:n+1'b1; end
    endfunction
    function [31:0] word_at;
        input [511:0] line;
        input [31:0] pc;
        begin word_at=line[{pc[5:2],5'b0} +: 32]; end
    endfunction
    wire lookup_uncached=(UNC_MASK!=0) && ((lookup_pc & UNC_MASK)==(UNC_BASE & UNC_MASK));
    wire [INDEX_BITS-1:0] lookup_index=lookup_pc[6 +: INDEX_BITS];
    wire [TAG_BITS-1:0] lookup_tag=lookup_pc[ADDR_WIDTH-1:6+INDEX_BITS];
    wire hit0=lookup_v0 && lookup_tag0==lookup_tag;
    wire hit1=lookup_v1 && lookup_tag1==lookup_tag;
    wire hit=hit0 || hit1;
    wire pop=if_resp_valid && if_resp_ready;
    assign if_resp_valid=q_valid[head] && q_state[head]==Q_DONE && !if_req_kill;
    assign if_resp_pc=q_pc[head];
    assign if_resp_inst=q_inst[head];
    assign if_resp_err=q_err[head];
    // Recycle the head slot on the very edge that delivers its response.
    assign if_req_ready=rst_n && !if_req_kill && (count<3 || pop);
    wire push=if_req_valid && if_req_ready;

    integer scan, ix;
    integer match_id, free_id, lookup_next, main_next, probe_next, finish_next;
    always @* begin
        match_id=-1; free_id=-1; lookup_next=-1;
        main_next=-1; probe_next=-1; finish_next=-1;
        for (scan=0; scan<3; scan=scan+1) begin
            if (m_state[scan]==M_FREE && free_id<0) free_id=scan;
            if (m_state[scan]!=M_FREE && !lookup_uncached && !m_uncached[scan] &&
                m_addr[scan][31:6]==lookup_pc[31:6]) match_id=scan;
            ix=head+scan; if(ix>=3) ix=ix-3;
            if(q_valid[ix] && q_state[ix]==Q_NEW && lookup_next<0) lookup_next=ix;
            ix=main_rr+scan; if(ix>=3) ix=ix-3;
            if(m_state[ix]==M_LOWER && main_next<0) main_next=ix;
            ix=probe_rr+scan; if(ix>=3) ix=ix-3;
            if(m_state[ix]==M_PROBE && probe_next<0) probe_next=ix;
            ix=finish_rr+scan; if(ix>=3) ix=ix-3;
            if(m_state[ix]==M_FINISH && finish_next<0) finish_next=ix;
        end
    end
    wire lookup_can_finish=hit && !lookup_uncached || match_id>=0 || free_id>=0;
    wire lookup_fire=lookup_valid && lookup_can_finish && !if_req_kill;
    assign perf_lookup_o=lookup_fire && !lookup_uncached;
    assign perf_miss_o=perf_lookup_o && !hit;

    assign l2_req_valid=main_busy && m_state[main_id]==M_REQUEST;
    assign l2_req_addr=m_addr[main_id];
    assign l2_req_cmd=m_uncached[main_id]?2'b01:2'b00;
    assign l2_req_size=m_uncached[main_id]?3'd2:3'd3;
    assign l2_req_len=m_uncached[main_id]?8'd0:8'd7;
    assign l2_rsp_ready=main_busy && m_state[main_id]==M_RECEIVE;
    assign probe_valid=probe_busy && m_state[probe_id]==M_PROBE;
    assign probe_addr=m_addr[probe_id];
    assign probe_rsp_ready=probe_busy && m_state[probe_id]==M_PROBING;

    integer n, f;
    reg victim;
    reg [INDEX_BITS-1:0] fi;
    always @(posedge clk) begin
        if(!rst_n) begin
            q_valid<=0; q_err<=0; head<=0; tail<=0; count<=0;
            lookup_valid<=0; main_busy<=0; probe_busy<=0;
            main_id<=0; probe_id<=0; main_rr<=0; probe_rr<=0; finish_rr<=0;
            m_err<=0; m_uncached<=0; beat<=0;
            for(n=0;n<3;n=n+1) begin
                q_state[n]<=Q_NEW; q_miss[n]<=0; q_pc[n]<=0; q_inst[n]<=0;
                m_state[n]<=M_FREE; m_addr[n]<=0; m_data[n]<=0;
            end
            for(n=0;n<SETS;n=n+1) begin v0[n]<=0; v1[n]<=0; lru[n]<=0; end
        end else begin
            if(pop) begin q_valid[head]<=0; head<=next_slot(head); end
            case({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: begin end
            endcase

            // Round-robin scheduling is independent of CPU head-of-line stalls.
            if(!main_busy && main_next>=0) begin
                main_busy<=1; main_id<=main_next; m_state[main_next]<=M_REQUEST;
                main_rr<=next_slot(main_next);
            end
            if(!probe_busy && probe_next>=0) begin
                probe_busy<=1; probe_id<=probe_next; probe_rr<=next_slot(probe_next);
            end
            if(probe_valid && probe_ready) m_state[probe_id]<=M_PROBING;
            if(probe_rsp_valid && probe_rsp_ready) begin
                probe_busy<=0;
                if(probe_rsp_hit) begin
                    m_data[probe_id]<=probe_rsp_line; m_state[probe_id]<=M_FINISH;
                end else m_state[probe_id]<=M_LOWER;
            end
            if(l2_req_valid && l2_req_ready) begin
                m_state[main_id]<=M_RECEIVE; beat<=0; m_data[main_id]<=0; m_err[main_id]<=0;
            end
            if(l2_rsp_valid && l2_rsp_ready) begin
                m_data[main_id][{beat[2:0],6'b0} +:64]<=l2_rsp_data;
                if(l2_rsp_err) m_err[main_id]<=1;
                if(l2_rsp_last) begin
                    if(!m_uncached[main_id] && beat!=7) m_err[main_id]<=1;
                    m_state[main_id]<=M_FINISH; main_busy<=0;
                end else if(beat==7) begin
                    // Overlong bursts are drained without wrapping the buffer.
                    m_err[main_id]<=1;
                end else beat<=beat+1'b1;
            end

            // One array write per cycle. Choose victim at INSTALL time, so
            // concurrent same-set fills never reserve/overwrite one another.
            if(finish_next>=0) begin
                f=finish_next; fi=m_addr[f][6 +: INDEX_BITS];
                victim=!v0[fi]?0:!v1[fi]?1:lru[fi];
                if(!m_err[f] && !m_uncached[f]) begin
                    if(!victim) begin
                        data0[fi]<=m_data[f]; tag0[fi]<=m_addr[f][ADDR_WIDTH-1:6+INDEX_BITS]; v0[fi]<=1; lru[fi]<=1;
                    end else begin
                        data1[fi]<=m_data[f]; tag1[fi]<=m_addr[f][ADDR_WIDTH-1:6+INDEX_BITS]; v1[fi]<=1; lru[fi]<=0;
                    end
                end
                for(n=0;n<3;n=n+1) if(q_valid[n] && q_state[n]==Q_WAIT && q_miss[n]==f) begin
                    q_inst[n]<=m_err[f]?32'h13:(m_uncached[f]?
                        (q_pc[n][2]?m_data[f][63:32]:m_data[f][31:0]):word_at(m_data[f],q_pc[n]));
                    q_err[n]<=m_err[f]; q_state[n]<=Q_DONE;
                end
                m_state[f]<=M_FREE; finish_rr<=next_slot(f);
            end

            if(lookup_fire) begin
                lookup_valid<=0;
                if(hit && !lookup_uncached) begin
                    q_inst[lookup_slot]<=word_at(hit0?lookup_data0:lookup_data1,lookup_pc);
                    q_state[lookup_slot]<=Q_DONE; q_err[lookup_slot]<=0;
                    if(finish_next<0) lru[lookup_index]<=hit0;
                end else if(match_id>=0) begin
                    if(m_state[match_id]==M_FINISH) begin
                        // A fill may complete on the same edge as a late join.
                        q_inst[lookup_slot]<=m_err[match_id]?32'h13:word_at(m_data[match_id],lookup_pc);
                        q_err[lookup_slot]<=m_err[match_id]; q_state[lookup_slot]<=Q_DONE;
                    end else begin
                        q_miss[lookup_slot]<=match_id; q_state[lookup_slot]<=Q_WAIT;
                    end
                end else begin
                    m_addr[free_id]<=lookup_uncached?lookup_pc:{lookup_pc[31:6],6'd0};
                    m_state[free_id]<=lookup_uncached?M_LOWER:M_PROBE;
                    m_uncached[free_id]<=lookup_uncached; m_err[free_id]<=0; m_data[free_id]<=0;
                    q_miss[lookup_slot]<=free_id; q_state[lookup_slot]<=Q_WAIT;
                end
            end

            // Synchronous RAM lookup. Pause reads during installation to avoid
            // depending on FPGA read-during-write collision semantics.
            if((!lookup_valid || lookup_fire) && lookup_next>=0 && finish_next<0 && !if_req_kill) begin
                lookup_valid<=1; lookup_slot<=lookup_next; lookup_pc<=q_pc[lookup_next];
                lookup_tag0<=tag0[q_pc[lookup_next][6 +:INDEX_BITS]];
                lookup_tag1<=tag1[q_pc[lookup_next][6 +:INDEX_BITS]];
                lookup_v0<=v0[q_pc[lookup_next][6 +:INDEX_BITS]];
                lookup_v1<=v1[q_pc[lookup_next][6 +:INDEX_BITS]];
                lookup_data0<=data0[q_pc[lookup_next][6 +:INDEX_BITS]];
                lookup_data1<=data1[q_pc[lookup_next][6 +:INDEX_BITS]];
                q_state[lookup_next]<=Q_LOOKUP;
            end
            if(push) begin
                q_valid[tail]<=1; q_pc[tail]<=if_req_addr; q_state[tail]<=Q_NEW;
                q_err[tail]<=0; tail<=next_slot(tail);
            end
            if(if_req_kill) begin
                // No epoch wrap hazard: fills never retain slot pointers. Only
                // currently valid Q_WAIT slots with a matching live MSHR join.
                // Accepted lower requests continue/drain even after cancellation.
                q_valid<=0; count<=0; head<=0; tail<=0; lookup_valid<=0;
            end
        end
    end
endmodule






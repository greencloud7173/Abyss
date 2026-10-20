`default_nettype none
`timescale 1ns/1ns

// INSTRUCTION FETCHER (with instruction cache)
// > Retrieves the instruction at the current PC
// > Each core has it's own fetcher, and therefore its own instruction cache
// >
// > Cache: direct-mapped, one 32-bit instruction per line, `CACHE_LINES` entries
// >   index = pc[INDEX_BITS-1:0]  tag = pc[ADDR_BITS-1:INDEX_BITS]
// >   hit  -> the instruction is served from the cache, program memory is not
// >           touched at all and the core goes straight on to DECODE
// >   miss -> one program-memory read; the returned word is installed in the line
// >
// > `flush` invalidates every line. `core.sv` drives it while the core sits in
// > IDLE, i.e. whenever the instruction stream is restarted (new kernel launch).
// > That is the "pipeline flush" point of this design: no fetched instruction may
// > survive it, because program memory may have been reloaded in between.
// >
// > `fetch_hit` is exported so the scheduler can skip the FETCH wait on a hit.
module fetcher #(
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 32,
    parameter CACHE_LINES = 128 // must be a power of two
) (
    input wire clk,
    input wire reset,
    input wire flush, // invalidate the whole cache
    // Execution State
    input wire [2:0] core_state,
    input wire [PROGRAM_MEM_ADDR_BITS - 1:0] current_pc,
    // Program Memory
    output reg mem_read_valid,
    output reg [PROGRAM_MEM_ADDR_BITS - 1:0] mem_read_address,
    input wire mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS - 1:0] mem_read_data,
    // Fetcher Output
    output reg [2:0] fetcher_state,
    output reg [PROGRAM_MEM_DATA_BITS - 1:0] instruction,
    output wire fetch_hit, // current_pc is already in the cache
    output reg [31:0] cache_hits, // debug counters (readable from cocotb)
    output reg [31:0] cache_misses
);
    localparam IDLE = 3'b000;
    localparam FETCHING = 3'b001;
    localparam FETCHED = 3'b010;
    localparam INDEX_BITS = $clog2(CACHE_LINES);
    localparam TAG_BITS = PROGRAM_MEM_ADDR_BITS - INDEX_BITS;
    // One line per indexed PC: data, tag, valid bit
    reg [PROGRAM_MEM_DATA_BITS - 1:0] cache_data [CACHE_LINES - 1:0];
    reg [TAG_BITS - 1:0] cache_tag [CACHE_LINES - 1:0];
    reg [CACHE_LINES - 1:0] cache_valid;
    // Lookup for the PC we are about to fetch
    wire [INDEX_BITS - 1:0] lookup_index = current_pc[INDEX_BITS - 1:0];
    wire [TAG_BITS - 1:0] lookup_tag = current_pc[PROGRAM_MEM_ADDR_BITS - 1:INDEX_BITS];
    assign fetch_hit = cache_valid[lookup_index] && (cache_tag[lookup_index] == lookup_tag);
    // Address of the request in flight, so the response lands in the right line
    // even if the PC has moved on by then
    reg [PROGRAM_MEM_ADDR_BITS - 1:0] request_pc;
    wire [INDEX_BITS - 1:0] fill_index = request_pc[INDEX_BITS - 1:0];
    wire [TAG_BITS - 1:0] fill_tag = request_pc[PROGRAM_MEM_ADDR_BITS - 1:INDEX_BITS];
    always @(posedge clk)
        if (reset) begin
            fetcher_state <= IDLE;
            mem_read_valid <= 0;
            mem_read_address <= 0;
            request_pc <= 0;
            instruction <= {PROGRAM_MEM_DATA_BITS {1'b0}};
            cache_valid <= {CACHE_LINES {1'b0}};
            cache_hits <= 0;
            cache_misses <= 0;
        end
        else begin
            case (fetcher_state)
                IDLE:
                    // Start fetching when core_state = FETCH
                    if (core_state == 3'b001) begin
                        if (fetch_hit) begin
                            // Cache hit: no program-memory round trip, the core can
                            // move on to DECODE on the next cycle
                            mem_read_valid <= 0;
                            instruction <= cache_data[lookup_index];
                            fetcher_state <= FETCHED;
                            cache_hits <= cache_hits + 1;
                        end
                        else begin
                            fetcher_state <= FETCHING;
                            mem_read_valid <= 1;
                            mem_read_address <= current_pc;
                            request_pc <= current_pc;
                            cache_misses <= cache_misses + 1;
                        end
                    end
                FETCHING:
                    // Wait for response from program memory
                    if (mem_read_ready) begin
                        fetcher_state <= FETCHED;
                        instruction <= mem_read_data; // Store the instruction when received
                        mem_read_valid <= 0;
                        // Install the line (direct-mapped: whatever was there is replaced)
                        cache_data[fill_index] <= mem_read_data;
                        cache_tag[fill_index] <= fill_tag;
                        cache_valid[fill_index] <= 1;
                    end
                FETCHED:
                    // Reset when core_state = DECODE
                    if (core_state == 3'b010)
                        fetcher_state <= IDLE;
            endcase
            // Flush has the last word: nothing fetched before it survives
            if (flush)
                cache_valid <= {CACHE_LINES {1'b0}};
        end
endmodule

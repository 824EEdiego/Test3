module RSA (
    input           clk,     //Positive edge-trigger clock
    input           rst_n,   //Asynchronous negative-edge reset
    input           i_valid, //High when the input data is valid
    output          ack,     // High if you acknowledge the input 
    input   [15:0]  Mi,      // Input message
    output          o_valid, //High when the output data is valid
    output  [15:0]  Mo       //Out put message
);
// DO NOT MODIFY THE CODE ABOVE!!


//MARCRO declaration for FSM
parameter IDLE = 3'd0;        // wait testbanch's new data(i_vaild=1)
parameter DECRYPT = 3'd1;    // Mi^kd % N, get decrypted_msg
parameter DECODE_OP = 3'd2;   // check (decrypted_msg[15:10] == 6'b100000) 
parameter EXEC_OP = 3'd3;     // add, substract...
parameter ENCRYPT = 3'd4;     // register^ke % N
parameter OUTPUT = 3'd5;      // set Mo, pull o_vaild to 1


//MARCRO declaration for const
parameter N  = 16'hCEF1;  // 52961 因為它代表一個「具體的二進位數值（位元結構）」，容易對齊位元，和硬體 bus/模乘直接相關
parameter kd = 4'd11;     // 因為它只是個「邏輯上的次方次數（數量）」，可讀性較重要，不關注二進位長相

//reg declaration   ;initializataion in always
reg [2:0] state, next_state;

//register and some intermdiate value 
reg [15:0] decrypted_msg, next_decrypted_msg;
reg [15:0] Mi_reg;
reg signed [11:0] register, next_register;
reg [7:0] ke, next_ke;                //ke = IMME[7:0]
reg signed [15:0] result, next_result;

wire o_valid_r = (state == OUTPUT);  //state == OUTPUT 的當下，o_valid 自動變成 1; 下一個 clock 進入 IDLE，o_valid 自然歸零（因為判斷式不成立）
reg ack_r;
reg [15:0] Mo_r;
assign ack = ack_r; //如果在 module內沒有特定義是reg 或是 wire ，則會根據你賦值的方式決定你是wire還是reg:if 用assign 那就是wire 如果是在 always內賦值那就是reg
assign o_valid = o_valid_r; //把o_valid接出來
assign Mo = Mo_r;  
reg wait_set_data, next_wait_set_data; //wait for next data's flag
wire [9:0] imme = decrypted_msg[9:0]; //wire要在always外宣告 //IMME is a 10-bit unsigned   這是指imme 會自動連接到 decrypted_msg[9:0]，它的值會隨著來源改變而即時變動（像電線一樣連接）

//------------------------------------------------------------------------ senquential variable
//Encrypt unit (modular exponential unit)
reg [7:0] cnt, next_cnt; //counter
reg [15:0] encrypt_result, next_encrypt_result;

//Decrypt unit 
reg [3:0] dec_cnt, next_dec_cnt; //couter
reg [15:0] decrypt_result, next_decrypt_result;
//------------------------------------------------------------------------


//FSM state transition
always @(*) begin
    case (state)
        IDLE: begin 
            next_state = (i_valid) ? DECRYPT : IDLE;
        end
        DECRYPT: begin
            next_state = (dec_cnt == 0) ? DECODE_OP : DECRYPT;   //用dec_cnt倒數，數到0時(表示modular exponential的操作結束)跳到DECODE_OP，否則就繼續停在DECRYPT解密
        end

        /*DECODE_OP: begin
            next_state = (decrypted_msg[15:10] == 6'b100000) ? ENCRYPT : EXEC_OP;
        end */

        DECODE_OP: begin
            case (decrypted_msg[15:10])
                6'b000001, 6'b000100, 6'b010000, 6'b001000: next_state = EXEC_OP;
                6'b000010: begin
                    next_wait_set_data = 1; //等待下一筆資料
                    next_state = IDLE;
                end
                6'b100000: next_state = ENCRYPT;
                default: next_state = IDLE;
            endcase
        end

        EXEC_OP: begin
            next_state = IDLE;
        end
        ENCRYPT: begin
            next_state = (cnt == 0) ? OUTPUT : ENCRYPT;
        end
        OUTPUT: begin
            next_state = IDLE;
        end
        default: 
            next_state = IDLE;
    endcase
end


//combination logic
always @(*) begin
    ack_r = (state == IDLE && i_valid && next_state == DECRYPT);
    //o_valid_r = 0;
    Mo_r = 0;
    next_decrypted_msg = decrypted_msg;
    next_register = register;
    next_result = result;
    next_ke = ke;
    next_cnt = cnt;
    next_encrypt_result = encrypt_result;
    next_decrypt_result = decrypt_result;
    next_dec_cnt = dec_cnt;
    next_wait_set_data = wait_set_data;               //initialize next flag

    //wire [9:0] imme = decrypted_msg[9:0];              

    case (state)
        DECRYPT: begin
            next_decrypt_result = (decrypt_result * Mi_reg) % N;
            next_dec_cnt = dec_cnt - 1;
            //若上一輪是set指令，則這筆為目標資料，將其寫進 register
            if (dec_cnt == 1 && wait_set_data) begin
                next_register = next_decrypt_result;         //(next_dec_result * Mi_reg) % N;解密結果直接存入register
                next_wait_set_data = 0;                  //清除flag
            end
        end

        EXEC_OP: begin //從DECODE_OP 中分離執行部分
            case (decrypted_msg[15:10])
                6'b000001: next_register = 12'sd0;   //reset                  
                6'b000100: begin //add
                    if (register + imme > 12'sd2047)   //飽和處裡要注意
                        next_register = 12'sd2047; 
                    else
                        next_register = register + imme;  //imme is unsigned, add it to signed register directly 
                end
                6'b001000: begin //sub
                    if (register - imme < -12'sd2048)
                        next_register = -12'sd2048;
                    else
                        next_register = register - imme;
                end 
                6'b010000: next_ke = decrypted_msg[7:0];  //set key


            endcase
        end

        /*ENCRYPT : begin 
            next_encrypt_result = (encrypt_result * register) % N;
            next_cnt = next_cnt - 1;
        end*/

        ENCRYPT: begin
            if (cnt == ke) begin   //如果目前 cnt 的值等於 ke（加密指令指定的次方次數），就表示我們剛「準備要進入」模乘流程，應該初始化加密結果
                next_encrypt_result = 16'd1;  //剛進來 ENCRYPT 狀態，還沒做第一次乘法，我們要初始化 encrypt_result = 1
            end else begin
                next_encrypt_result = (encrypt_result * register) % N;
            end
            next_cnt = cnt - 1;
        end

        OUTPUT: begin
            Mo_r = result;  // 將結果輸出
        end
    endcase
    //combinational 初始化 dec_cnt 的邏輯反覆執行，導致它一直被設回 b;每當 dec_cnt 回到 b（11）時，你又重設一次 → 卡死
    /*
    if(state == DECRYPT && dec_cnt == kd) begin
        next_decrypt_result = 1;
        next_dec_cnt = kd;
    end*/   
end

//----------------------------------------------------------sequential circuit

//FSM sequential logic
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state <= IDLE;
        decrypted_msg <= 0;
        register <= 0;
        result <= 0;
        ke <= 0;
        Mi_reg <= 0;
        wait_set_data <= 0;
        //dec_cnt <= 0; //給初始值
        //decrypt_result <= 1; //給初始值
    end else begin
        state <= next_state;
        decrypted_msg <= next_decrypted_msg;
        register <= next_register;
        result <= next_result;
        ke <= next_ke;
        wait_set_data <= next_wait_set_data;
        if (i_valid && state == IDLE)
            Mi_reg <= Mi;

        //初始化 dec_cnt 和 decrypt_result
        if(state == IDLE && i_valid) begin
            dec_cnt <= kd;//這代表 第 1 拍剛進入 DECRYPT 時：dec_cnt = 11decrypt_result = 1這拍還沒做乘法，僅初始化而已！
            //decrypt_result <= 1; //雖然重複對decrypt_result 賦值1但因為作用不同所以沒關系
        end /*else if (state == DECRYPT) begin
            dec_cnt <= next_dec_cnt;
            decrypt_result <= next_decrypt_result;

            if (dec_cnt == 1)
                decrypted_msg <= next_decrypt_result;
        end*/
    end
end



//Encrypt unit (modular exponential unit)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt <= 0;
        encrypt_result <= 1; //multiply from 1
    end else if (state == ENCRYPT) begin
        cnt <= next_cnt;
        encrypt_result <= next_encrypt_result;
        if (cnt == 1)
            result <= next_encrypt_result;
    end
end

//Decrypt unit
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dec_cnt <= 0;
        decrypt_result <= 1; //multiply from 1
    end else if (state == DECRYPT) begin
        if (dec_cnt == kd) begin
            decrypt_result <= 1;
        end else begin
            decrypt_result <= next_decrypt_result; //下一個 clock 將 decrypt_result 更新為這一拍預先計算好的乘法結果
            //這是整個 RSA 解密模組的「乘法累積器」，也就是用來計算decrypt_result = M^kd mod N
            //這邊的 next_decrypt_result 是在 combinational 區中算出來的，也就是：next_decrypt_result = (decrypt_result * Mi_reg) % N;
        end

        dec_cnt <= next_dec_cnt; 

        if (dec_cnt == 1) //此時已在計算next_dec_cnt = dec_cnt - 1 算出答案是0，在等待下個posedge來，posedge來之後瞬間跳state
        //到了 if (dec_cnt == 1) 的那一拍時，你已經做了 10 次乘法，這是第 11 次，剛好要乘完最後一輪，產生Mi^11 mod N
        //dec_cnt == kd ➜ 初始化;dec_cnt == 1 ➜ 這次是「最後一次乘法」;一共乘了 kd 次
            decrypted_msg <= next_decrypt_result; //next_decrypt_result = (decrypt_result * Mi_reg) % N;
    end
end


/*
//Decrypt unit 
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dec_cnt <= 0;
        decrypt_result <= 1; //multiply from 1
    end else if (state == DECRYPT) begin
        dec_cnt <= next_dec_cnt;
        decrypt_result <= next_decrypt_result;
        if (dec_cnt == 1)
            decrypted_msg <= next_decrypt_result;
    end
end
*/


endmodule
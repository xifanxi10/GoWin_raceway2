package link_pkg;
    function automatic [15:0] crc_byte(input [15:0] crc, input [7:0] data);
        reg [15:0] c;
        integer i;
        begin
            c = crc ^ {data, 8'h00};
            for (i=0; i<8; i=i+1)
                c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
            crc_byte = c;
        end
    endfunction
    function automatic [7:0] default_note(input integer key_index);
        case (key_index)
            0: default_note=60; 1: default_note=62;
            2: default_note=64; 3: default_note=65;
            4: default_note=67; 5: default_note=69;
            6: default_note=71; default: default_note=72;
        endcase
    endfunction
endpackage

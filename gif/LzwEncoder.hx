 package gif;

/*
 * No copyright asserted on the source code of this class. May be used
 * for any purpose, however, refer to the Unisys LZW patent for restrictions
 * on use of the associated LZWEncoder class :
 *
 * The Unisys patent expired on 20 June 2003 in the USA, in Europe it expired
 * on 18 June 2004, in Japan the patent expired on 20 June 2004 and in Canada
 * it expired on 7 July 2004. The U.S. IBM patent expired 11 August 2006, The
 * Software Freedom Law Center says that after 1 October 2006, there will be
 * no significant patent claims interfering with employment of the GIF format.
 *
 * Original code by Kevin Weiner, FM Software.
 * Adapted from Jef Poskanzer's Java port by way of J. M. G. Elliott.
 * Ported to Haxe by Tilman Schmidt and Sven Bergström
 *
 */

import haxe.io.Int32Array;
import haxe.io.UInt8Array;

class LzwEncoder {
    static var EOF(default, never):Int = -1;

    var pixAry:UInt8Array;
    var initCodeSize:Int;
    var curPixel:Int;

    // GIFCOMPR.C       - GIF Image compression routines
    //
    // Lempel-Ziv compression based on 'compress'.  GIF modifications by
    // David Rowley (mgardi@watdcsu.waterloo.edu)

    // General DEFINEs

    static var BITS(default, never):Int = 12;

    static var HSIZE(default, never):Int = 5003; // 80% occupancy

    // GIF Image compression - modified 'compress'
    //
    // Based on: compress.c - File compression ala IEEE Computer, June 1984.
    //
    // By Authors:  Spencer W. Thomas      (decvax!harpo!utah-cs!utah-gr!thomas)
    //              Jim McKie              (decvax!mcvax!jim)
    //              Steve Davies           (decvax!vax135!petsd!peora!srd)
    //              Ken Turkowski          (decvax!decwrl!turtlevax!ken)
    //              James A. Woods         (decvax!ihnp4!ames!jaw)
    //              Joe Orost              (decvax!vax135!petsd!joe)

    var n_bits:Int; // number of bits/code
    var maxbits:Int = BITS; // user settable max # bits/code
    var maxcode:Int; // maximum code, given n_bits
    var maxmaxcode:Int = 1 << BITS; // should NEVER generate this code

    var htab:Int32Array;
    var codetab:Int32Array;

    var hsize:Int = HSIZE; // for dynamic table sizing

    var free_ent:Int = 0; // first unused entry

    // block compression parameters -- after all codes are used up,
    // and compression rate changes, start over.
    var clear_flg:Bool = false;

    // Algorithm:  use open addressing double hashing (no chaining) on the
    // prefix code / next character combination.  We do a variant of Knuth's
    // algorithm D (vol. 3, sec. 6.4) along with G. Knott's relatively-prime
    // secondary probe.  Here, the modular division first probe is gives way
    // to a faster exclusive-or manipulation.  Also do block compression with
    // an adaptive reset, whereby the code table is cleared when the compression
    // ratio decreases, but after the table fills.  The variable-length output
    // codes are re-sized at this point, and a special CLEAR code is generated
    // for the decompressor.  Late addition:  construct the table according to
    // file size for noticeable speed improvement on small files.  Please direct
    // questions about this implementation to ames!jaw.

    var g_init_bits:Int;

    var ClearCode:Int;
    var EOFCode:Int;

    // output
    //
    // output the given code.
    // Inputs:
    //      code:   A n_bits-bit integer.  If == -1, then EOF.  This assumes
    //              that n_bits =< wordsize - 1.
    // outputs:
    //      outputs code to the file.
    // Assumptions:
    //      Chars are 8 bits long.
    // Algorithm:
    //      Maintain a BITS character long buffer (so that 8 codes will
    // fit in it exactly).  Use the VAX insv instruction to insert each
    // code in turn.  When the buffer fills up empty it and start over.

    var cur_accum:Int = 0;
    var cur_bits:Int = 0;

    var masks:Array<Int> =
    [
        0x0000,
        0x0001,
        0x0003,
        0x0007,
        0x000F,
        0x001F,
        0x003F,
        0x007F,
        0x00FF,
        0x01FF,
        0x03FF,
        0x07FF,
        0x0FFF,
        0x1FFF,
        0x3FFF,
        0x7FFF,
        0xFFFF ];

    // Number of characters so far in this 'packet'
    var a_count:Int;

    // Define the storage for the packet accumulator
    var accum:UInt8Array;

    //----------------------------------------------------------------------------
    public function new()
    {
        htab = new Int32Array(HSIZE);
        codetab = new Int32Array(HSIZE);
        accum = new UInt8Array(256);
    }

    //Reset the encoder to new pixel data and default values
    public function reset(pixels:UInt8Array, color_depth:Int) { //width and height used to be passed in though they were never used
        pixAry = pixels;
        initCodeSize = Std.int(Math.max(2, color_depth));

        maxbits = BITS;
        maxmaxcode = 1 << BITS;
        hsize = HSIZE;
        free_ent = 0;
        clear_flg = false;
        cur_accum = 0;
        cur_bits = 0;
    }

    // add a character to the end of the current packet, and if it is 254
    // characters, flush the packet to disk.
    function add(c:UInt, out:haxe.io.Output):Void
    {
        accum[a_count++] = c;
        if (a_count >= 254)
            flush(out);
    }

    // Clear out the hash table

    // table clear for block compress
    function clearTable(out:haxe.io.Output):Void
    {
        resetCodeTable(hsize);
        free_ent = ClearCode + 2;
        clear_flg = true;

        output(ClearCode, out);
    }

    // reset code table
    function resetCodeTable(hsize:Int):Void
    {
        for (i in 0...hsize)
            htab[i] = -1;
    }

    function compress(init_bits:Int, out:haxe.io.Output):Void
    {
        var fcode:Int;
        var i:Int /* = 0 */;
        var c:Int;
        var ent:Int;
        var disp:Int;
        var hsize_reg:Int;
        var hshift:Int;

        // Set up the globals:  g_init_bits - initial number of bits
        g_init_bits = init_bits;

        // Set up the necessary values
        clear_flg = false;
        n_bits = g_init_bits;
        maxcode = maxCode(n_bits);

        ClearCode = 1 << (init_bits - 1);
        EOFCode = ClearCode + 1;
        free_ent = ClearCode + 2;

        a_count = 0; // clear packet

        ent = nextPixel();

        hshift = 0;
        fcode = hsize;
        while (fcode < 65536) {
            ++hshift;
            fcode *= 2;
        }

        hshift = 8 - hshift; // set hash code range bound

        hsize_reg = hsize;
        resetCodeTable(hsize_reg); // clear hash table

        output(ClearCode, out);

        while ((c = nextPixel()) != EOF)
        {
            fcode = (c << maxbits) + ent;
            i = (c << hshift) ^ ent; // xor hashing

            if (htab[i] == fcode)
            {
                ent = codetab[i];
                continue;
            }
            else if (htab[i] >= 0) // non-empty slot
            {
                disp = hsize_reg - i; // secondary hash (after G. Knott)
                if (i == 0)
                    disp = 1;
                do
                {
                    if ((i -= disp) < 0)
                        i += hsize_reg;

                    if (htab[i] == fcode)
                    {
                        ent = codetab[i];
                        break;
                    }
                } while (htab[i] >= 0);
                if (htab[i] == fcode) continue;
            }
            output(ent, out);
            ent = c;
            if (free_ent < maxmaxcode)
            {
                codetab[i] = free_ent++; // code -> hashtable
                htab[i] = fcode;
            }
            else
                clearTable(out);
        }
        // Put out the final code.
        output(ent, out);
        output(EOFCode, out);
    }

    //----------------------------------------------------------------------------
    public function encode(os:haxe.io.Output):Void
    {
        os.writeByte( initCodeSize ); // write "initial code size" byte
        curPixel = 0;
        compress(initCodeSize + 1, os); // compress and write the pixel data
        os.writeByte(0); // write block terminator
    }

    // flush the packet to disk, and reset the accumulator
    function flush(out:haxe.io.Output):Void
    {
        if (a_count > 0)
        {
            out.writeByte(a_count);
            out.writeBytes(accum.view.buffer, 0, a_count);
            a_count = 0;
        }
    }

    inline function maxCode(n_bits:Int):Int
    {
        return (1 << n_bits) - 1;
    }

    //----------------------------------------------------------------------------
    // Return the next pixel from the image
    //----------------------------------------------------------------------------
    function nextPixel():Int
    {
        if (curPixel == pixAry.length)
            return EOF;

        curPixel++;
        return pixAry[curPixel - 1] & 0xff;
    }

    function output(code:Int, out:haxe.io.Output):Void
    {
        cur_accum &= masks[cur_bits];

        if (cur_bits > 0)
            cur_accum |= (code << cur_bits);
        else
            cur_accum = code;

        cur_bits += n_bits;

        while (cur_bits >= 8)
        {
            add(cur_accum & 0xff, out);
            cur_accum >>= 8;
            cur_bits -= 8;
        }

        // If the next entry is going to be too big for the code size,
        // then increase it, if possible.
        if (free_ent > maxcode || clear_flg)
        {
            if (clear_flg)
            {
                maxcode = maxCode(n_bits = g_init_bits);
                clear_flg = false;
            }
            else
            {
                ++n_bits;
                if (n_bits == maxbits)
                    maxcode = maxmaxcode;
                else
                    maxcode = maxCode(n_bits);
            }
        }

        if (code == EOFCode)
        {
            // At EOF, write the rest of the buffer.
            while (cur_bits > 0)
            {
                add(cur_accum & 0xff, out);
                cur_accum >>= 8;
                cur_bits -= 8;
            }

            flush(out);
        }
    }

}

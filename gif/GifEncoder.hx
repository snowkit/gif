package gif;

/*
 * No copyright asserted on the source code of this class. May be used
 * for any purpose.
 *
 * Original code by Kevin Weiner, FM Software.
 * Adapted by Thomas Hourdel (https://github.com/Chman/Moments)
 * Ported to Haxe by Tilman Schmidt and Sven Bergström
 */

import haxe.io.UInt8Array;
import haxe.io.BytesOutput;

@:enum abstract GifRepeat(Int)
  from Int to Int {
    var None = 0;
    var Infinite = -1;
}

@:enum abstract GifQuality(Int)
  from Int to Int {
    var Best = 1;
    var VeryHigh = 10;
    var QuiteHigh = 20;
    var High = 35;
    var Mid = 50;
    var Low = 65;
    var QuiteLow = 80;
    var VeryLow = 90;
    var Worst = 100;
}

class GifEncoder {

    var width: Int;
    var height: Int;
    var framerate: Float = 24;                 // used if frame.delay < 0
    var repeat: Int = -1;                    // -1: infinite, 0: none, >0: repeat count

    var colorDepth: Int = 8;                 // Number of bit planes
    var paletteSize: Int = 7;                // Color table size (bits-1)
    var sampleInterval: Int = 10;            // Default sample interval for quantizer

        //caches
    var pixels: UInt8Array;
    var indexedPixels: UInt8Array;           // Converted frame indexed to palette
    var colorTab: UInt8Array;                // RGB palette
    var usedEntry: Array<Bool>;              // Active palette entries
        //        
    var nq: NeuQuant;
    var lzwEncoder: LzwEncoder;
        //internal
    var started: Bool = false;
    var first_frame: Bool = true;

        //:todo: error handling could be better - but throw inside of another thread on cpp is too quiet
        
        /** Allows a custom print handler for error messages.
            Defaults to Sys.println on sys targets, and trace otherwise. */
    public var print: Dynamic->Void;

// Public API

    /** Construct a gif encoder with options:

        frame width/height:
            Default is 0, required

        framerate:
            This is used if an added frame has a delay that is negative.

        repeat:
            Default is 0 (no repeat); -1 means play indefinitely.
            Use GifRepeat for clarity

        quality:
            Sets quality of color quantization (conversion of images to
            the maximum 256 colors allowed by the GIF specification). Lower values (minimum = 1)
            produce better colors, but slow processing significantly. Higher values will speed
            up the quantization pass at the cost of lower image quality (maximum = 100). */
    public function new(
        _frame_width:Int,
        _frame_height:Int,
        _framerate:Float,
        _repeat:Int = GifRepeat.Infinite,
        _quality:Int = 10
    ) {
        
        #if sys 
            print = Sys.println;
        #else 
            print = function(v) { trace(v); } 
        #end

        width = _frame_width;
        height = _frame_height;
        framerate = _framerate;
        repeat = _repeat;

        sampleInterval = Std.int(clamp(_quality, 1, 100));
        usedEntry = [for (i in 0...256) false];

        pixels = new UInt8Array(width * height * 3);
        indexedPixels = new UInt8Array(width * height);

        nq = new NeuQuant();
        lzwEncoder = new LzwEncoder();

    } //new

    public function start(output:BytesOutput) : Void {

        if(output == null) {
            print("gif: start() output must not be null.");
            return;
        }

        output.writeString("GIF89a");

        write_LSD(output);

        started = true;

    } //start

    public function add(output:BytesOutput, frame:GifFrame) : Void {

        if(output == null) {
            print("gif: add() output must not be null.");
            return;
        }

        if(!started) {
            print("gif: add() requires start to be called before adding frames.");
            return;
        }

        var pixels = get_pixels(frame);
        analyze(pixels);

        if(first_frame) {
            
            write_palette(output);
            
            if(repeat != GifRepeat.None) {
                write_NetscapeExt(output);
            }

            first_frame = false;

        } //first_frame

        var delay = if(frame.delay < 0) {
            1.0/framerate;
        } else {
            frame.delay;
        }

        write_GraphicControlExt(output, delay);
        write_image_desc(output, first_frame);

        if(!first_frame) {
            write_palette(output);
        }

        write_pixels(output);

    } //add

    public function commit(output:BytesOutput) : Void {

        if(output == null) {
            print("gif: commit() output must be not null.");
            return;
        }

        if(!started) {
            print("gif: commit() called without start() being called first.");
            return;
        }

        output.writeByte(0x3b); // Gif trailer
        output.flush();
        output.close();

        started = false;
        first_frame = true;

    } //commit

    //helpers

        function get_pixels(frame:GifFrame):UInt8Array {

            //if not flipped we can use the data as is
            if (!frame.flippedY) return frame.data;

                //otherwise flip it, and return the cached array
            var stride = width * 3;
            for(y in 0...height) {
                var begin = (height - 1 - y) * stride;
                pixels.view.buffer.blit(y * stride, frame.data.view.buffer, begin, stride);
            }

            return pixels;

        } //get_pixels

        function analyze(pixels:UInt8Array) {

            // Create reduced palette
            nq.reset(pixels, pixels.length, sampleInterval);
            colorTab = nq.process();

                // Map image pixels to new palette
            var k:Int = 0;
            for (i in 0...(width * height)) {
                var r = pixels[k++] & 0xff;
                var g = pixels[k++] & 0xff;
                var b = pixels[k++] & 0xff;
                var index = nq.map(r, g,b);
                usedEntry[index] = true;
                indexedPixels[i] = index;
            }

        } //analyze

    //writers
        //

            /** Writes Logical Screen Descriptor. */
        function write_LSD(output:BytesOutput) {
            //
            
                // Logical screen size
            output.writeInt16(width);
            output.writeInt16(height);

                // Packed fields
            output.writeByte(0x80 |         // 1   : global color table flag = 1 (gct used)
                             0x70 |         // 2-4 : color resolution = 7
                             0x00 |         // 5   : gct sort flag = 0
                             paletteSize);  // 6-8 : gct size

            output.writeByte(0);            // Background color index
            output.writeByte(0);            // Pixel aspect ratio - assume 1:1

        } //write_LSD

            /** Writes Netscape application extension to define repeat count. */
        function write_NetscapeExt(output:BytesOutput):Void {

            var repeats = repeat;
            if(repeats == GifRepeat.Infinite || repeats < 0) repeats = 0;
            if(repeats == GifRepeat.None) repeats = -1;

            output.writeByte(0x21);                     // Extension introducer
            output.writeByte(0xff);                     // App extension label
            output.writeByte(11);                       // Block size
            output.writeString("NETSCAPE" + "2.0");     // App id + auth code
            output.writeByte(3);                        // Sub-block size
            output.writeByte(1);                        // Loop sub-block id
            output.writeInt16(repeats);                 // Loop count (extra iterations, 0=repeat forever)
            output.writeByte(0);                        // Block terminator

        } //write_NetscapeExt

            /** Write color table. */
        function write_palette(output:BytesOutput):Void {
            
            output.write(colorTab.view.buffer);

            var n:Int = (3 * 256) - colorTab.length;

            for (i in 0...n) {
                output.writeByte(0);
            }

        } //write_palette

            /** Encodes and writes pixel data. */
        function write_pixels(output:BytesOutput):Void {
        
            lzwEncoder.reset(indexedPixels, colorDepth);
            lzwEncoder.encode(output);
        
        } //write_pixels

            /** Writes Image Descriptor. */
        function write_image_desc(output:BytesOutput, first:Bool):Void {

            output.writeByte(0x2c);         // Image separator
            output.writeInt16(0);           // Image position x = 0
            output.writeInt16(0);           // Image position y = 0
            output.writeInt16(width);       // Image width
            output.writeInt16(height);      // Image height

                //Write LCT, or GCT

            if(first) {

                output.writeByte(0);                // No LCT  - GCT is used for first (or only) frame

            } else {
                    
                output.writeByte(0x80 |             // 1 local color table  1=yes
                                    0 |             // 2 interlace - 0=no
                                    0 |             // 3 sorted - 0=no
                                    0 |             // 4-5 reserved
                                    paletteSize);   // 6-8 size of color table
            
            } //else

        } //write_image_desc

            /** Writes Graphic Control Extension. Delay is in seconds, floored and converted to 1/100 of a second */
        function write_GraphicControlExt(output:BytesOutput, delay:Float):Void {

            output.writeByte(0x21);         // Extension introducer
            output.writeByte(0xf9);         // GCE label
            output.writeByte(4);            // data block size

            // Packed fields
            output.writeByte(0 |            // 1:3 reserved
                             0 |            // 4:6 disposal
                             0 |            // 7   user input - 0 = none
                             0 );           // 8   transparency flag

                //convert to 1/100 sec
            var delay_val = Math.floor(delay * 100);

            output.writeInt16(delay_val);   // Delay x 1/100 sec
            output.writeByte(0);            // Transparent color index
            output.writeByte(0);            // Block terminator

        } //write_GraphicControlExt

    /** Clamp a value between a and b and return the clamped version */
    static inline public function clamp(value:Float, a:Float, b:Float):Float
    {
        return ( value < a ) ? a : ( ( value > b ) ? b : value );
    }

} //GifEncoder


typedef GifFrame = {

        /** Delay of the frame in seconds. This value gets floored
            when encoded due to gif format requirements. If this value is negative,
            the default encoder frame rate will be used. */
    var delay: Float;
        /** Whether or not this frame should be flipped on the Y axis */
    var flippedY: Bool;
        /** Pixels data in unsigned bytes, rgb format */
    var data: UInt8Array;

}

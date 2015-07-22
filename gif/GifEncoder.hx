package gif;

/*
 * No copyright asserted on the source code of this class. May be used
 * for any purpose.
 *
 * Original code by Kevin Weiner, FM Software.
 * Adapted by Thomas Hourdel (https://github.com/Chman/Moments)
 * Ported to Haxe by Tilman Schmidt and Sven Bergström
 */

import sys.io.File;
import sys.io.FileOutput;
import haxe.io.UInt8Array;

class GifEncoder {

    var width:Int;
    var height:Int;
    var repeat:Int = -1;                    // -1: no repeat, 0: infinite, >0: repeat count
    var frameDelay:Int = 0;                 // Frame delay (milliseconds)
    var hasStarted:Bool = false;            // Ready to output frames
    var fileStream:FileOutput;

    var currentFrame:GifFrame;
    var pixels:UInt8Array;
    var flippedY:Bool = false;
    var indexedPixels:UInt8Array;           // Converted frame indexed to palette
    var colorDepth:Int;                     // Number of bit planes
    var colorTab:UInt8Array;                // RGB palette
    var usedEntry:Array<Bool>;              // Active palette entries
    var paletteSize:Int = 7;                // Color table size (bits-1)
    var disposalCode:Int = -1;              // Disposal code (-1 = use default)
    var shouldCloseStream:Bool = false;     // Close stream when finished
    var isFirstFrame:Bool = true;
    var isSizeSet:Bool = false;             // If false, get size from first frame
    var sampleInterval:Int = 10;            // Default sample interval for quantizer

    var nq:NeuQuant;
    var lzwEncoder:LzwEncoder;

// Public API

    /** Construct a gif encoder with options:

        repeat:
            Default is -1 (no repeat); 0 means play indefinitely.

        quality:
            Sets quality of color quantization (conversion of images to
            the maximum 256 colors allowed by the GIF specification). Lower values (minimum = 1)
            produce better colors, but slow processing significantly. Higher values will speed
            up the quantization pass at the cost of lower image quality (maximum = 100).

        flippedY:
            If the frame is expected to be flipped during encoding for alternative coordinate systems */
    public function new(_repeat:Int = -1, _quality:Int = 10, _flippedY:Bool = false)
    {
        repeat = _repeat;

        sampleInterval = Std.int(clamp(_quality, 1, 100));
        usedEntry = [for (i in 0...256) false];
        flippedY = _flippedY;

        nq = new NeuQuant();
        lzwEncoder = new LzwEncoder();
    }

    /** Sets the delay time between each frame,
        or changes it for subsequent frames.
        Applies to the last frame added.
        Time in microseconds. */
    public function setDelay(microseconds:Int):Void
    {
        frameDelay = Math.round(microseconds / 10);
    }

    /** Sets frame rate in frames per second.
        Equivalent to setDelay(1000/fps)
        Applies to the last frame added. */
    public function setFramerate(fps:Float):Void
    {
        if (fps > 0) {
            frameDelay = Math.round(100 / fps);
        }
    }

    /** Adds next GIF frame. The frame is not written immediately, but is actually deferred
        until the next frame is received so that timing data can be inserted. Invoking
        Finish() flushes all frames. */
    public function addFrame(frame:GifFrame):Void
    {
        if (frame == null)
        {
            throw "Can't add a null frame to the gif.";
        }

        if (!hasStarted)
        {
            throw "Call Start() before adding frames to the gif.";
        }

        // Use first frame's size
        if (!isSizeSet)
        {
            setSize(frame.width, frame.height);
        }

        currentFrame = frame;
        getImagepixels();
        analyzepixels();

        if (isFirstFrame)
        {
            writeLSD();
            writePalette();

            if (repeat >= 0)
            {
                writeNetscapeExt();
            }
        }

        writeGraphicCtrlExt();
        writeImageDesc();

        if (!isFirstFrame)
        {
            writePalette();
        }

        writePixels();
        isFirstFrame = false;
    }

    /** Initiates GIF file creation on the given stream.
        The stream is not closed automatically.
        The FileOutput on which GIF images are written,
        should to binary and little endian. */
    public function startOutput(out:FileOutput):Void
    {
        if (out == null) {
            throw "File output is null.";
        }

        shouldCloseStream = false;
        fileStream = out;

        try {
            fileStream.writeString("GIF89a"); // header
        }
        catch (e:Dynamic) {
            throw e;
        }

        hasStarted = true;
    }

    /** Initiates writing of a GIF file with the specified name.
        The stream will be handled for you. */
    public function startFile(path:String):Void
    {
        try {
            fileStream = File.write(path);
            startOutput(fileStream);
            shouldCloseStream = true;
        }
        catch (e:Dynamic) {
            throw e;
        }
    }

    /** Flushes any pending data and closes output file.
        If writing to a FileOutput, the stream is not closed. */
    public function finish():Void
    {
        if (!hasStarted)
        {
            throw "Can't finish a non-started gif.";
        }

        hasStarted = false;

        try
        {
            fileStream.writeByte(0x3b); // Gif trailer
            fileStream.flush();

            if (shouldCloseStream) {
                fileStream.close();
            }
        }
        catch (e:Dynamic)
        {
            throw e;
        }

        // Reset for subsequent use
        fileStream = null;
        currentFrame = null;
        indexedPixels = null;
        colorTab = null;
        shouldCloseStream = false;
        isFirstFrame = true;
    }

//Internal

    /** Sets the GIF frame size. */
    function setSize(w:Int, h:Int):Void
    {
        width = w;
        height = h;
        //Now that the size is set, we can allocate frame data arrays;
        pixels = new UInt8Array(w * h * 3);
        indexedPixels = new UInt8Array(w * h);
        isSizeSet = true;
    }

    /** Get the current frame pixel data, will be flipped if the flag is enabled */
    function getImagepixels():Void {
        if (!flippedY) {
            pixels = currentFrame.data;
        }
        else {
            var stride = currentFrame.width * 3;
            for(y in 0...currentFrame.height) {
                var begin = (currentFrame.height - 1 - y) * stride;
                pixels.view.buffer.blit(y * stride, currentFrame.data.view.buffer, begin, stride);
            }
        }
    }

    /** Analyzes image colors and creates color map. */
    function analyzepixels():Void
    {
        nq.reset(pixels, pixels.length, sampleInterval);
        colorTab = nq.process(); // Create reduced palette

        // Map image pixels to new palette
        var k:Int = 0;
        for (i in 0...(currentFrame.width * currentFrame.height))
        {
            var index = nq.map(pixels[k++] & 0xff, pixels[k++] & 0xff, pixels[k++] & 0xff);
            usedEntry[index] = true;
            indexedPixels[i] = index;
        }
        colorDepth = 8;
        paletteSize = 7;
    }

//Stream Encoding

    /** Writes Graphic Control Extension. */
    function writeGraphicCtrlExt():Void
    {
        fileStream.writeByte(0x21);         // Extension introducer
        fileStream.writeByte(0xf9);         // GCE label
        fileStream.writeByte(4);            // data block size

        // Packed fields
        fileStream.writeByte(0 |            // 1:3 reserved
                             0 |            // 4:6 disposal
                             0 |            // 7   user input - 0 = none
                             0 );           // 8   transparency flag

        fileStream.writeInt16(frameDelay);  // Delay x 1/100 sec
        fileStream.writeByte(0);            // Transparent color index
        fileStream.writeByte(0);            // Block terminator
    }

    /** Writes Image Descriptor. */
    function writeImageDesc():Void
    {
        fileStream.writeByte(0x2c);         // Image separator
        fileStream.writeInt16(0);           // Image position x,y = 0,0
        fileStream.writeInt16(0);
        fileStream.writeInt16(width);       // image size
        fileStream.writeInt16(height);

        // Packed fields
        if (isFirstFrame)
        {
            fileStream.writeByte(0);                // No LCT  - GCT is used for first (or only) frame
        }
        else
        {
            // Specify normal LCT
            fileStream.writeByte(0x80 |             // 1 local color table  1=yes
                                    0 |             // 2 interlace - 0=no
                                    0 |             // 3 sorted - 0=no
                                    0 |             // 4-5 reserved
                                    paletteSize);   // 6-8 size of color table
        }
    }

    /** Writes Logical Screen Descriptor. */
    function writeLSD():Void
    {
        // Logical screen size
        fileStream.writeInt16(width);
        fileStream.writeInt16(height);

        // Packed fields
        fileStream.writeByte(0x80 |         // 1   : global color table flag = 1 (gct used)
                             0x70 |         // 2-4 : color resolution = 7
                             0x00 |         // 5   : gct sort flag = 0
                             paletteSize);  // 6-8 : gct size

        fileStream.writeByte(0);            // Background color index
        fileStream.writeByte(0);            // Pixel aspect ratio - assume 1:1
    }

    /** Writes Netscape application extension to define repeat count. */
    function writeNetscapeExt():Void
    {
        fileStream.writeByte(0x21);    // Extension introducer
        fileStream.writeByte(0xff);    // App extension label
        fileStream.writeByte(11);      // Block size
        fileStream.writeString("NETSCAPE" + "2.0"); // App id + auth code
        fileStream.writeByte(3);       // Sub-block size
        fileStream.writeByte(1);       // Loop sub-block id
        fileStream.writeInt16(repeat); // Loop count (extra iterations, 0=repeat forever)
        fileStream.writeByte(0);       // Block terminator
    }

    /** Write color table. */
    function writePalette():Void
    {
        fileStream.write(colorTab.view.buffer);
        var n:Int = (3 * 256) - colorTab.length;

        for (i in 0...n)
            fileStream.writeByte(0);
    }

    /** Encodes and writes pixel data. */
    function writePixels():Void
    {
        lzwEncoder.reset(indexedPixels, colorDepth);
        lzwEncoder.encode(fileStream);
    }

    /** Clamp a value between a and b and return the clamped version */
    static inline public function clamp(value:Float, a:Float, b:Float):Float
    {
        return ( value < a ) ? a : ( ( value > b ) ? b : value );
    }

}


typedef GifFrame = {

        /** Width of the frame */
    var width:Int;
        /** Height of the frame */
    var height:Int;
        /** Pixels data in unsigned bytes, rgb format */
    var data:UInt8Array;

}

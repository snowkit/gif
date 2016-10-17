
import gif.GifEncoder;

class Test {

    static var width = 32;
    static var height = 32;
    static var delay = 1;
    
    static function main() {

        trace("creating test.gif ...");

        var output = new haxe.io.BytesOutput();
        var encoder = new gif.GifEncoder(width, height, 1, GifRepeat.Infinite, GifQuality.High);

        encoder.start(output);

            //add 4 frames of random colors
        encoder.add(output, make_frame());
        encoder.add(output, make_frame());
        encoder.add(output, make_frame());
        encoder.add(output, make_frame());

        encoder.commit(output);

        var bytes = output.getBytes();

    #if sys
        sys.io.File.saveBytes("test.gif", bytes);
    #elseif js
        var imageElement :js.html.ImageElement = cast js.Browser.document.createElement("img");
        js.Browser.document.body.appendChild(imageElement);
        imageElement.src = 'data:image/gif;base64,' + haxe.crypto.Base64.encode(bytes);
    #else
        throw 'Unsupported platform!';
    #end

        trace("done.");

    } //main

    static function make_frame() {

        var red = Std.random(255);
        var blue = Std.random(255);
        var green = Std.random(255);

        var pixels = new haxe.io.UInt8Array(width * height * 3);
        for(i in 0 ... width * height) {
            pixels[i * 3 + 0] = red;
            pixels[i * 3 + 1] = green;
            pixels[i * 3 + 2] = blue;
        }

        var frame: GifFrame = {
            width: width, 
            height: height,
            delay: delay,
            flippedY: false,
            data: pixels
        }

        return frame;

    } //make_frame

} //Test

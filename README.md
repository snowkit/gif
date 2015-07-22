# gif

**A gif format encoder.**   
This only deals with the encoding (writing) and not reading of gif files (see [format](https://github.com/haxefoundation/format)).   

Ported from [https://github.com/Chman/Moments](https://github.com/Chman/Moments)

Haxe port by [KeyMaster-](https://github.com/KeyMaster-)   
with contributions by [underscorediscovery](https://github.com/underscorediscovery)

**LICENSE**: The individual files are licensed accordingly.

---

### Simple usage

##### NOTE

Please note the code is currently being made more flexible and will change slightly.
See https://github.com/snowkit/gif/issues/1

Specifically - instead of this code handling the file IO,
it would defer the work to the using code to allow the encoding
to remain adaptible to various frameworks, platforms and data transports.

---

**Create an instance of the GifEncoder class**

```haxe
var encoder = new GifEncoder(repeat, quality, true);
```

**Start encoding**

```haxe
//see also startOutput
encoder.startFile(filePath);
```

**Add frames to the gif**

```haxe

//RGB information is in UInt8Array format,
//Which can be created with UInt8Array.fromBytes/fromArray
//for haxe.io.Bytes or Array types

var frame = {
    width: frameWidth,
    height: frameHeight,
    data: new haxe.io.UInt8Array(frameWidth * frameHeight * 3)
}

encoder.addFrame(frame);

//Configure the last added frame
//see also setFramerate
encoder.setDelay( microseconds );
```

**End encoding**

```haxe
encoder.finish();
```



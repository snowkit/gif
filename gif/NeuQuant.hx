package gif;

/*
 * Copyright (c) 1994 Anthony Dekker
 * Ported to Java by Kevin Weiner, FM Software
 * Ported to Haxe by Tilman Schmidt and Sven Bergström
 *
 * NEUQUANT Neural-Net quantization algorithm by Anthony Dekker, 1994.
 * See "Kohonen neural networks for optimal colour quantization"
 * in "Network: Computation in Neural Systems" Vol. 5 (1994) pp 351-367.
 * for a discussion of the algorithm.
 *
 * Any party obtaining a copy of these files from the author, directly or
 * indirectly, is granted, free of charge, a full and unrestricted irrevocable,
 * world-wide, paid up, royalty-free, nonexclusive right and license to deal
 * in this software and documentation files (the "Software"), including without
 * limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons who receive
 * copies from any such party to do so, with the only requirement being
 * that this copyright notice remain intact.
 *
 */

import haxe.io.Int32Array;
import haxe.io.UInt8Array;

class NeuQuant {
	static var netsize(default, never):Int = 256; // Number of colours used

    // Four primes near 500 - assume no image has a length so large that it is divisible by all four primes
    static var prime1(default, never):Int = 499;
    static var prime2(default, never):Int = 491;
    static var prime3(default, never):Int = 487;
    static var prime4(default, never):Int = 503;

    static var minpicturebytes(default, never):Int = (3 * prime4); // Minimum size for input image

    // Network Definitions
    static var maxnetpos(default, never):Int = (netsize - 1);
    static var netbiasshift(default, never):Int = 4; // Bias for colour values
    static var ncycles(default, never):Int = 100; // No. of learning cycles

    // Defs for freq and bias
    static var intbiasshift(default, never):Int = 16; // Bias for fractions
    static var intbias(default, never):Int = (1 << intbiasshift);
    static var gammashift(default, never):Int = 10; // Gamma = 1024
    static var gamma(default, never):Int = (1 << gammashift);
    static var betashift(default, never):Int = 10;
    static var beta(default, never):Int = (intbias >> betashift); // Beta = 1/1024
    static var betagamma(default, never):Int = (intbias << (gammashift - betashift));

    // Defs for decreasing radius factor
    static var initrad(default, never):Int = (netsize >> 3); // For 256 cols, radius starts
    static var radiusbiasshift(default, never):Int = 6; // At 32.0 biased by 6 bits
    static var radiusbias(default, never):Int = (1 << radiusbiasshift);
    static var initradius(default, never):Int = (initrad * radiusbias); // And decreases by a
    static var radiusdec(default, never):Int = 30; // Factor of 1/30 each cycle

    // Defs for decreasing alpha factor
    static var alphabiasshift(default, never):Int = 10; /* alpha starts at 1.0 */
    static var initalpha(default, never):Int = (1 << alphabiasshift);

    var alphadec:Int; // Biased by 10 bits

    // Radbias and alpharadbias used for radpower calculation
    static var radbiasshift(default, never):Int = 8;
    static var radbias(default, never):Int = (1 << radbiasshift);
    static var alpharadbshift(default, never):Int = (alphabiasshift + radbiasshift);
    static var alpharadbias(default, never):Int = (1 << alpharadbshift);

    // Types and Global Variables
    var thepicture:UInt8Array; // The input image itself
    var lengthcount:Int; // Lengthcount = H*W*3
    var samplefac:Int; // Sampling factor 1..30
    var network:Int32Array; // The network itself - [netsize][4]
    var netindex:Int32Array; // For network lookup - really 256
    var bias:Int32Array; // Bias and freq arrays for learning
    var freq:Int32Array;
    var radpower:Int32Array; // Radpower for precomputation

    public function new()
    {
        netindex = new Int32Array(256);
        bias = new Int32Array(netsize);
        freq = new Int32Array(netsize);
        radpower = new Int32Array(initrad);
        network = new Int32Array(netsize * 4);
    }

    // Reset network in range (0,0,0) to (255,255,255) and set parameters
    public function reset(thepic:UInt8Array, len:Int, sample:Int):Void {
        thepicture = thepic;
        lengthcount = len;
        samplefac = sample;

        var p:Int32Array;
        for (i in 0...netsize) {
            p = network.subarray(i * 4, i * 4 + 4);
            p[0] = p[1] = p[2] = Std.int((i << (netbiasshift + 8)) / netsize);
            freq[i] = Std.int(intbias / netsize); // 1 / netsize
            bias[i] = 0; // allocated to zero?
        }
    }

    public function colormap():UInt8Array
    {
        var map = new UInt8Array(3 * netsize);
        var index = new Int32Array(netsize);

        for (i in 0...netsize)
            index[network[i * 4 + 3]] = i;

        var k:Int = 0;
        for (i in 0...netsize)
        {
            var j = index[i];
            map[k++] = network[j * 4];
            map[k++] = network[j * 4 + 1];
            map[k++] = network[j * 4 + 2];
        }

        return map;
    }

    // Insertion sort of network and building of netindex[0..255] (to do after unbias)
    public function inxbuild():Void
    {
        var i:Int;
        var j:Int;
        var smallpos:Int;
        var smallval:Int;
        var p:Int32Array;
        var q:Int32Array;
        var previouscol:Int;
        var startpos:Int;

        previouscol = 0;
        startpos = 0;

        for (i in 0...netsize)
        {
            p = network.subarray(i * 4, i * 4 + 4);
            smallpos = i;
            smallval = p[1]; // Index on g

            // Find smallest in i..netsize-1
            for (j in (i + 1)...netsize)
            {
                q = network.subarray(j * 4, j * 4 + 4);
                if (q[1] < smallval)
                {
                    smallpos = j;
                    smallval = q[1]; // Index on g
                }
            }

            q = network.subarray(smallpos * 4, smallpos * 4 + 4);

            // Swap p (i) and q (smallpos) entries
            if (i != smallpos)
            {
                j = q[0];
                q[0] = p[0];
                p[0] = j;
                j = q[1];
                q[1] = p[1];
                p[1] = j;
                j = q[2];
                q[2] = p[2];
                p[2] = j;
                j = q[3];
                q[3] = p[3];
                p[3] = j;
            }

            // Smallval entry is now in position i
            if (smallval != previouscol)
            {
                netindex[previouscol] = (startpos + i) >> 1;

                for (j in (previouscol + 1)...smallval)
                    netindex[j] = i;

                previouscol = smallval;
                startpos = i;
            }
        }

        netindex[previouscol] = (startpos + maxnetpos) >> 1;

        for (j in (previouscol + 1)...256)
            netindex[j] = maxnetpos;
    }

    // Main learning Loop
    public function learn():Void
    {
        var i:Int;
        var j:Int;
        var b:Int;
        var g:Int;
        var r:Int;
        var radius:Int;
        var rad:Int;
        var alpha:Int;
        var step:Int;
        var delta:Int;
        var samplepixels:Int;

        var p:UInt8Array;
        var pix:Int;
        var lim:Int;

        if (lengthcount < minpicturebytes)
            samplefac = 1;

        alphadec = 30 + Std.int((samplefac - 1) / 3);
        p = thepicture;
        pix = 0;
        lim = lengthcount;
        samplepixels = Std.int(lengthcount / (3 * samplefac));
        delta = Std.int(samplepixels / ncycles);
        alpha = initalpha;
        radius = initradius;

        rad = radius >> radiusbiasshift;

        if (rad <= 1)
            rad = 0;

        for (i in 0...rad)
            radpower[i] = Std.int(alpha * (((rad * rad - i * i) * radbias) / (rad * rad)));

        if (lengthcount < minpicturebytes)
        {
            step = 3;
        }
        else if ((lengthcount % prime1) != 0)
        {
            step = 3 * prime1;
        }
        else
        {
            if ((lengthcount % prime2) != 0)
            {
                step = 3 * prime2;
            }
            else
            {
                if ((lengthcount % prime3) != 0)
                    step = 3 * prime3;
                else
                    step = 3 * prime4;
            }
        }

        i = 0;
        while (i < samplepixels)
        {
            b = (p[pix + 0] & 0xff) << netbiasshift;
            g = (p[pix + 1] & 0xff) << netbiasshift;
            r = (p[pix + 2] & 0xff) << netbiasshift;
            j = contest(b, g, r);

            altersingle(alpha, j, b, g, r);

            if (rad != 0)
                alterneigh(rad, j, b, g, r); // Alter neighbours

            pix += step;

            if (pix >= lim)
                pix -= lengthcount;

            i++;

            if (delta == 0)
                delta = 1;

            if (i % delta == 0)
            {
                alpha -= Std.int(alpha / alphadec);
                radius -= Std.int(radius / radiusdec);
                rad = radius >> radiusbiasshift;

                if (rad <= 1)
                    rad = 0;

                for (j in 0...rad)
                    radpower[j] = Std.int(alpha * (((rad * rad - j * j) * radbias) / (rad * rad)));
            }
        }
    }

    // Search for BGR values 0..255 (after net is unbiased) and return colour index
    public function map(b:Int, g:Int, r:Int):Int
    {
        var i:Int;
        var j:Int;
        var dist:Int;
        var a:Int;
        var bestd:Int;
        var p:Int32Array;
        var best:Int;

        bestd = 1000; // Biggest possible dist is 256*3
        best = -1;
        i = netindex[g]; // Index on g
        j = i - 1; // Start at netindex[g] and work outwards

        while ((i < netsize) || (j >= 0))
        {
            if (i < netsize)
            {
                p = network.subarray(i * 4, i * 4 + 4);
                dist = p[1] - g; // Inx key

                if (dist >= bestd)
                {
                    i = netsize; // Stop iter
                }
                else
                {
                    i++;

                    if (dist < 0)
                        dist = -dist;

                    a = p[0] - b;

                    if (a < 0)
                        a = -a;

                    dist += a;

                    if (dist < bestd)
                    {
                        a = p[2] - r;

                        if (a < 0)
                            a = -a;

                        dist += a;

                        if (dist < bestd)
                        {
                            bestd = dist;
                            best = p[3];
                        }
                    }
                }
            }

            if (j >= 0)
            {
                p = network.subarray(j * 4, j * 4 + 4);
                dist = g - p[1]; // Inx key - reverse dif

                if (dist >= bestd)
                {
                    j = -1; // Stop iter
                }
                else
                {
                    j--;

                    if (dist < 0)
                        dist = -dist;

                    a = p[0] - b;

                    if (a < 0)
                        a = -a;

                    dist += a;

                    if (dist < bestd)
                    {
                        a = p[2] - r;

                        if (a < 0)
                            a = -a;

                        dist += a;

                        if (dist < bestd)
                        {
                            bestd = dist;
                            best = p[3];
                        }
                    }
                }
            }
        }

        return best;
    }

    public function process():UInt8Array
    {
        learn();
        unbiasnet();
        inxbuild();
        return colormap();
    }

    // Unbias network to give byte values 0..255 and record position i to prepare for sort
    public function unbiasnet():Void
    {
        for (i in 0...netsize)
        {
            network[i * 4] >>= netbiasshift;
            network[i * 4 + 1] >>= netbiasshift;
            network[i * 4 + 2] >>= netbiasshift;
            network[i * 4 + 3] = i; // Record colour no
        }
    }

    // Move adjacent neurons by precomputed alpha*(1-((i-j)^2/[r]^2)) in radpower[|i-j|]
    function alterneigh(rad:Int, i:Int, b:Int, g:Int, r:Int):Void
    {
        var j:Int;
        var k:Int;
        var lo:Int;
        var hi:Int;
        var a:Int;
        var m:Int;

        var p:Int32Array;

        lo = i - rad;

        if (lo < -1)
            lo = -1;

        hi = i + rad;

        if (hi > netsize)
            hi = netsize;

        j = i + 1;
        k = i - 1;
        m = 1;

        while ((j < hi) || (k > lo))
        {
            a = radpower[m++];

            if (j < hi)
            {
                p = network.subarray(j * 4, j * 4 + 4);
                j++;
                p[0] -= Std.int((a * (p[0] - b)) / alpharadbias);
                p[1] -= Std.int((a * (p[1] - g)) / alpharadbias);
                p[2] -= Std.int((a * (p[2] - r)) / alpharadbias);
            }

            if (k > lo)
            {
                p = network.subarray(k * 4, k * 4 + 4);
                k--;
                p[0] -= Std.int((a * (p[0] - b)) / alpharadbias);
                p[1] -= Std.int((a * (p[1] - g)) / alpharadbias);
                p[2] -= Std.int((a * (p[2] - r)) / alpharadbias);
            }
        }
    }

    // Move neuron i towards biased (b,g,r) by factor alpha
    function altersingle(alpha:Int, i:Int, b:Int, g:Int, r:Int):Void
    {
        /* Alter hit neuron */
        var n:Int32Array = network.subarray(i * 4, i * 4 + 4);
        n[0] -= Std.int((alpha * (n[0] - b)) / initalpha);
        n[1] -= Std.int((alpha * (n[1] - g)) / initalpha);
        n[2] -= Std.int((alpha * (n[2] - r)) / initalpha);
    }

    // Search for biased BGR values
    function contest(b:Int, g:Int, r:Int):Int
    {
        // Finds closest neuron (min dist) and updates freq
        // Finds best neuron (min dist-bias) and returns position
        // For frequently chosen neurons, freq[i] is high and bias[i] is negative
        // bias[i] = gamma*((1/netsize)-freq[i])

        var i:Int;
        var dist:Int;
        var a:Int;
        var biasdist:Int;
        var betafreq:Int;
        var bestpos:Int;
        var bestbiaspos:Int;
        var bestd:Int;
        var bestbiasd:Int;
        var n:Int32Array;

        bestd = ~(1 << 31);
        bestbiasd = bestd;
        bestpos = -1;
        bestbiaspos = bestpos;

        for (i in 0...netsize)
        {
            n = network.subarray(i * 4, i * 4 + 4);
            dist = n[0] - b;

            if (dist < 0)
                dist = -dist;

            a = n[1] - g;

            if (a < 0)
                a = -a;

            dist += a;
            a = n[2] - r;

            if (a < 0)
                a = -a;

            dist += a;

            if (dist < bestd)
            {
                bestd = dist;
                bestpos = i;
            }

            biasdist = dist - ((bias[i]) >> (intbiasshift - netbiasshift));

            if (biasdist < bestbiasd)
            {
                bestbiasd = biasdist;
                bestbiaspos = i;
            }

            betafreq = (freq[i] >> betashift);
            freq[i] -= betafreq;
            bias[i] += (betafreq << gammashift);
        }

        freq[bestpos] += beta;
        bias[bestpos] -= betagamma;
        return bestbiaspos;
    }

}

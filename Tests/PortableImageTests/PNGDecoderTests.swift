// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import PortableImage
import Testing

/// The PNG decoder by images written independently of it, by Python's zlib
/// and a hand-made encoder: every colour type at every bit depth, each row
/// with the next of the five filters, the data split over two IDAT chunks
/// and an ancillary chunk among them. The pixels each should read as were
/// worked out by the same script.
struct PNGDecoderTests {
    private static let width = 7
    private static let height = 5

    /// The name, the PNG and the RGBA pixels, all in base 64.
    private static let cases: [(String, String, String)] = [
        ("type0depth1", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFAQAAAACh4ct1AAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAAAJSURBVHjaY1jEyMMkwp8ShHkAAAAJSURBVFzGMgcACJoB35EhIo8AAAAASUVORK5CYII=",
         "/////wAAAP//////AAAA/wAAAP8AAAD//////wAAAP8AAAD/AAAA/wAAAP///////////wAAAP8AAAD/AAAA//////8AAAD/AAAA/wAAAP8AAAD//////wAAAP8AAAD/AAAA/wAAAP///////////wAAAP8AAAD//////wAAAP8AAAD/AAAA//////8="),
        ("type0depth2", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFAgAAAADmQbGlAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAAALSURBVHjaY2D8wfgrismkhMK0EQAAAAxJREFUh1n+I8uVNgAnNAWCwLCrRQAAAABJRU5ErkJggg==",
         "AAAA/wAAAP8AAAD/VVVV////////////qqqq////////////qqqq/6qqqv9VVVX/VVVV/1VVVf8AAAD/qqqq//////+qqqr//////6qqqv8AAAD/AAAA//////9VVVX/qqqq/1VVVf///////////wAAAP8AAAD/qqqq/6qqqv+qqqr///////////8="),
        ("type0depth4", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFBAAAAABpAUQFAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAAARSURBVHjaY1DqV5zA+PKR8yKmLLXoDzSyXwAAABFJREFUCczBkp3rWHzqMi4AAHDsCT0N2qtTAAAAAElFTkSuQmCC",
         "IiIi/yIiIv+IiIj//////yIiIv8RERH/mZmZ/+7u7v+ZmZn/zMzM/7u7u/8AAAD/7u7u/7u7u/9VVVX/MzMz//////8RERH/ZmZm/5mZmf9ERET/d3d3/8zMzP/MzMz//////yIiIv9VVVX/7u7u/8zMzP+IiIj/RERE/93d3f+IiIj/3d3d/7u7u/8="),
        ("type0depth8", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFCAAAAACs8akEAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAAAZSURBVHjaASgA1/8AwnZNKlpNdgF3j/JlKQpyAtP5+dRtAAAAGklEQVTQxUa6i+cDo/wIErHO3gRXQsFIrF3lWqoSWUb6SLIAAAAASUVORK5CYII=",
         "wsLC/3Z2dv9NTU3/Kioq/1paWv9NTU3/dnZ2/3d3d/8GBgb/+Pj4/11dXf+Ghob/kJCQ/wICAv9KSkr/1tbW/729vf+jo6P/QEBA/xsbG//p6en/yMjI/8vLy//MzMz/ycnJ/zU1Nf/29vb/zc3N/x8fH/9hYWH/IiIi/2pqav/h4eH/U1NT/zg4OP8="),
        ("type0depth16", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFEAAAAAD8YXVHAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAAArSURBVHjaAUsAtP8Arhsa6zRrAB5NcjPzuisBDQ4X8kZ4VimMbTUZMLYCrWXOw9SzndeEAAAAK0lEQVRte26t1m1vRBkDmoCr7b0xFkWTex76td0E/lSzm+DaPkhwJpK+wslhACF7m4ojkAAAAABJRU5ErkJggg==",
         "ra2t/xsbG/80NDT/AAAA/01NTf80NDT/ubm5/w0NDf8kJCT/ampq/8DAwP9MTEz/gYGB/7Gxsf+6urr/8vLy/z8/P/87Ozv/+fn5/+7u7v/19fX/9/f3/5+fn/8sLCz/SUlJ/zQ0NP+vr6//h4eH//T09P9SUlL/DAwM/2lpaf+4uLj/S0tL/w4ODv8="),
        ("type2depth8", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFCAIAAAAG+GGPAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAAA8SURBVHjaAW4Akf8AmC6Fu1W2cqhyY3rNdGb8tg4Oj/GEAWOw5E8KRb56S4AwOHiTVI25K0gWOwKRq/r4cqF9meNE/X8AAAA9SURBVLdh85WmVu5VQogSfaQDjQfYhjPkKeghZhBQM3J5uNFvoMbTBAKtFiRr7EaP5Yq0ixdH2UJwK1ul+SbsM7orE+s/AAAAAElFTkSuQmCC",
         "mC6F/7tVtv9yqHL/Y3rN/3Rm/P+2Dg7/j/GE/2Ow5P+yuin/cDR0//BkrP9o9wD/9bAr/z3GZv/0W97/qizK/+3NK/9RV0H/Dk3u/0rys/9PQwr/BzRH/95jbP8OgGz/lXum/4TWQ/8fter/10JN/wnhXf8CTFj/SPI9/x+m9/82HX//YY0V/zLnDv8="),
        ("type2depth16", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFEAIAAABWaL3MAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAABxSURBVHjaAdcAKP8AIHHi8aa2ZhiN6+eZ9MF+zITpZ7nlIkY21VE+Rcjj4l2hyCUkezXbTyVwAWzlmwU+pOMuIHcLkDKEi8qmR+/W6uvcbYkNIyinolkxiZdcNlv1+8GWeAJKsQgQ8ZBsS059ZNdpP5s9GsdUauYtJQAAAHFJREFUW3mJzF0ncOZuA3vj+k8auTjemT2T+LwDLyzxS8EX4v6qMYpbRp7PxQNwrl913vtWgt76diA+geoFSv2T4XVRkbJvBP3v/PcQJIGD3s2JawU7m7dBO/EzG+H1iq0D4cHTFl83evJAwgLJ9ZbCFQXGbecjwzcSAAAAAElFTkSuQmCC",
         "IOKm/2aN5//0foT/Z+RG/9Q+yP/hoSX/e9ol/2yaPv9Pu0n/gUbv/3Awy//5U3L/UtzO/63XZP+2oi//uwqs/+rhCf/EqZf/ITp1/zUrh/+LFF3/ikLX/4TPTP/8py7/jh1e/9klif8JLYX/K3Ei/4c+5/8GrdX/iUIW/3o4Uv+GGlz/Z5+c/2mU4/8="),
        ("type3depth1", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFAQMAAACzVGSbAAAABlBMVEVbirEJgBJaXRK7AAAAAXRSTlMH3oJNxQAAABF0RVh0Q29tbWVudABhbmNpbGxhcnkbZifnAAAACUlEQVR42mPQYnzCVMNZfIJgAAAACUlEQVQ8jaUHAAyiArdehKz0AAAAAElFTkSuQmCC",
         "W4qxB1uKsQcJgBL/W4qxBwmAEv9birEHCYAS/wmAEv8JgBL/CYAS/1uKsQdbirEHCYAS/1uKsQdbirEHCYAS/wmAEv9birEHW4qxB1uKsQdbirEHCYAS/wmAEv9birEHW4qxB1uKsQcJgBL/CYAS/1uKsQcJgBL/W4qxBwmAEv9birEHW4qxBwmAEv8="),
        ("type3depth2", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFAgMAAAD09B5LAAAADFBMVEXkAYa6qKV9EZ5vtl22832kAAAAAnRSTlMAqzeXt1gAAAARdEVYdENvbW1lbnQAYW5jaWxsYXJ5G2Yn5wAAAAtJREFUeNpjOBfAqLiaiSPAnwZdAAAADElEQVSAedFjlr4DACK6BSDh849UAAAAAElFTkSuQmCC",
         "b7Zd/+QBhgBvtl3/fRGe/7qopau6qKWr5AGGAOQBhgB9EZ7/5AGGALqopatvtl3/5AGGAG+2Xf/kAYYAfRGe/30Rnv+6qKWr5AGGALqopatvtl3/fRGe/2+2Xf+6qKWrfRGe/7qopavkAYYAb7Zd/7qopavkAYYAuqilq+QBhgDkAYYA5AGGALqopas="),
        ("type3depth4", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFBAMAAAB7tOvrAAAAMFBMVEW4NcDnGQl9+ocB6SMvIfKBJod4aXbr/MMn9ZMXZSdLqYKbRAb2H/iJMm/6lJLt7u7K7gQIAAAACHRSTlM8Zp8r8giU6qBMHCMAAAARdEVYdENvbW1lbnQAYW5jaWxsYXJ5G2Yn5wAAABFJREFUeNpj0OtJU2BUSd/7gmlySYXtu47VAAAAEUlEQVQC85bUfXEsa7fzXAAAbU0Jj9n5rhQAAAAASUVORK5CYII=",
         "ffqHn/qUkv8n9ZP/9h/4/3hpdpR4aXaUffqHn336h58vIfLyJ/WT/5tEBv8vIfLyJ/WT/wHpIyubRAb/6/zD6u3u7v/t7u7/9h/4/7g1wDyBJocIuDXAPO3u7v/6lJL/9h/4/xdlJ/8vIfLyiTJv/5tEBv/2H/j/S6mC/wHpIytLqYL/uDXAPEupgv8="),
        ("type3depth8", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFCAMAAAC+RAbqAAADAFBMVEWtyz1kBpSBviHJxye424wYjzQakkx/iN+hYb/bDsxoKRnS5kaS+BlBV/HUr5CYgoXPepr3yT1VUiZq/nDnqubaR2J8LlmvLqN6vIRnCtPE02vAiq0f/464QG4vin/EzOTdnwtBENny+gAlyO/lfzdyT0036isUAEB3E5tBgN85MiSZYsaFcgAFmuuOoXzzeH4O0p0cC2P/1ymDdNm9dPwRrde5ymUDlSJp/WafY3bucYeXN/1fcvjVHErJG20MSNQaHl7J5qA5KFSoYV7vEJ/Bv6niVjcBKI8ps9c/asK2nt0sGfJkvuRipbryD9J+zxTAEe0gH4NjIK25i6sWhqKNmAEhDHc28+7FgNz8Q/5dBJtNeKej67koZchRftAhEfamUto1JIcrajHX/+RYd0TV63g+lpaPib6ChWXgfl99eE6QYKchyoB9djPtEjQC83blvxSWdz0ZYWMmvlvlhQM2s28TvK5IFmiCE2gFp9G+Xp8naBD99yDQM8pPLlPLitGRndUan7bU1Qm6ZMjPaAPeUNg6Ls+661NCBxpIyy29V0qykVJXIjfE+2WaQBb3oRvGLFJxz2TyXW8VzFDEtz9MfmIVE6U8x+mc151/2ce85OBbCwH67njk6lvyzDYiQbfcuy7iFBRCKqAoG8FFDSE4Y0P7k1RxIbOBUaWM6UmC9WqGeaO+EmVdzlKOp8BWhzoYuOc1gcm+h8C8SripKeJ1WhiXgZ6gABFxTJTd1boYQ/p0FwsbAbWbNrZy05pEaLvzUUQHfEzmMSBKis2HBRyz4/x/VAAWHwzPX3lRHTUGZEjTZtRZniCZGPQDwN/uKedZczWFdhM/q4YaiN+Hl28rB1aFeGdRp2LHqHrC8PEDDd93nWzIJ1dKEA05NlKwSA4PFUYVIhchumYhxDZ+aWg5EREsk/QzQzJolqOs2IUKs4OQGLyk85MP0w/fMrHwGG4uk1ffAGeTGwKy+zD7Xv2xhVGRbXb/VDgp+zWntjDNyizYDL5pm4bbV8J360ARsqfbcEcwAAAAgHRSTlNP5qVW7eCDdkCr7HliiJpPT36nslJ4p2CENFQ0ZMRNS5qY3oxkNzaPacbtEQbM33GX7QtIg88CfNzXdXVcP+jdoIUy1nzMUIDY9+kK0V2nBcf6NhOAb1JmsjPpaPMIva/S6WteyD62HIGMw8wfBibW17SHN3KbzXDI7GxUQiNi8Gn1OhIAAAARdEVYdENvbW1lbnQAYW5jaWxsYXJ5G2Yn5wAAABhJREFUeNpjKPbacvn9NAfGD0cPCFscjGTKd+xhUxSGWQAAABlJREFU//7nAHOpRq1EUupSlu8XIviq+zIBe3ISIeJM5EIAAAAASUVORK5CYII=",
         "Jr5bN7ae3empKeL/Gojf//AYbv8VE6X/Gh5eoC6TV/91Whj/NrNvm0IHGv/zUUT/Gp+2/wMN3/8hEfavkW12/2QGlOb3oRv/oAAR/9AzyiO85OD/RQ0h/7GFUf8p+zX/d51s/5lixhHd1br/8g/Sp1sLAf+z4/z/uEBuxJlixhH7k1T/ASiPgBi45/8="),
        ("type4depth8", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFCAQAAAAjkz5TAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAAArSURBVHjaAUsAtP8ABwVrJJaAM0l3X+exTmoBzlVgQzdlCCtzE1xMmvACeZ3OhZIW0vSHAAAAK0lEQVTy3NOexBh8fC0DzIWiYfjsUjyyJrat51IEQfnIWxkkwxpReF+kN72ajyFXZwpJ+gAAAABJRU5ErkJggg==",
         "BwcHBWtraySWlpaAMzMzSXd3d1/n5+exTk5Oas7OzlUuLi6YZWVl/W1tbSjg4OA7PDw8h9bW1ndHR0fy/Pz8Hff39+9JSUn7fn5+/1RUVANSUlKk7+/v/peXl+6/v7/a1tbWJlxcXLgODg4KFxcXqTAwMPf4+PhJERERbdTU1ECtra0wu7u7rvLy8ms="),
        ("type4depth16", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFEAQAAABzA+IQAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAABOSURBVHjaAZEAbv8AkXze0a8U2EOAzhr+lAuV9LXZ/MrOtardixuwigFoNfwA1CytayYV+e83vZ/2k6PTMaBju2JNOf0iAjGZO43HzW5W/8lR4EBNePMAAABOSURBVIWYfzgfdBb+oJNFUtH9jQQD535Bjfdlng767CFWlDbkUBvPTNcVDhJ1FWq2NgRwKq6dOXK/hiJaDjM+/ZCTk8wNAVMII6EskkhGkx9F1ByQSiMAAAAASUVORK5CYII=",
         "kZGR3q6urteAgIAbk5OTlbW1tfzOzs6qi4uLsGhoaPs8PDypYmJiopmZmUEtLS0Uy8vLzxkZGcuZmZk3AwMDGGFhYfIfHx/AS0tLKmxsbBTq6upZNDQ0XBMTE9czMzMHvLy8R56enoSamppe19fXEaKiogrc3Nwc/v7+FD09PdfOzs7kIiIiB8XFxU8="),
        ("type6depth8", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFCAYAAACJmvbYAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAABOSURBVHjaAZEAbv8A89M0KvFsTQfaAgQ+LW8+QvEJjXzmXxm7SiuW/wHrghoQGp3tGMKAmCwyfwJo59K0jlvJ/ou5DJS2Ar8TdQ+l6EZ2FN8hcgeS+SYAAABOSURBVMdZRtUgtDE/nZfCvlSGpXQDXOGxtLle/G0qdLoRPxNDo7Nsv3G+bK64+vWifASracH0crjg+S7RzTzpamQfIpBAPyFhdO49dC3iDlxF5FseL/IAAAAASUVORK5CYII=",
         "89M0KvFsTQfaAgQ+LW8+QvEJjXzmXxm7SiuW/+uCGhAFHwcox5+fVPkeobzg8FVKO7lT1fTF54uqlY8fqgdNntt+wMbAd+eRAKSGidhQFZNIS4z/sSv4w2Z3nh3K7mmCBMXrLLUgd8uEpPRnYGxiL1yUubfOTH4W/L82vu0pT6EPsI8KMBFo+G2Fj9o="),
        ("type6depth16", "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFEAYAAADZCiqbAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAACUSURBVHjaAR0B4v4AMbjky0MFggsTY618ZuhcicGjKtUOFxocEdK9QOqj+UIg3Mt3PWUuDoOuoy53Zy34yUZdhuWNUccBveh4YnGFWCBW3wueQ7XGOftylRXQ0dkqDlQbqMYXqyTmaDIfTtk/SDMEjCYN3d1eTp3Wspq3AbACOYZK/uXKid1nUMZKUjvRN1Wr+lvMUXlpC0bVIRCxAAAAlElEQVSMSf1sQlYvs2BNcyVFi7KfvPUAT7lycel0fXzZihsDLsIQTPLk7MpWku20z4CnEePmqOM6RyCi+BpD7f4d5ixrlezTO/+dvm6AIelUQz5vpb7gAUufzBAES3whESD7J7VzIElr/XYC6RPOo2xfvkLbRcrH4CIXVpnrGXX/tSlL93edpeddnR775C4YnZvN3t2JH4vwe9DFUwAAAABJRU5ErkJggg==",
         "MuRDghOtZ1zBKw4aEr3q+CHLPS6Do3cuyF3lUb14cVgUgrQeDhiE9xw0SqIDZZjhNvClvoPHP7/1wlbhekkG72QSUHAovkfkMcQLJuetpXf0O7tJqXEdXOZK4EyI1dJ+Tw2Kl6tWhfo4oun2Ok4dbPSSPYNnutyFenkyx5TUUx2WSgjhrkfiAZJfuN4="),
    ]

    @Test(arguments: cases.map(\.0))
    func everyColourTypeAndDepthReads(_ name: String) throws {
        let entry = try #require(Self.cases.first { $0.0 == name })
        let image = try PNGDecoder.decode(try #require(Data(base64Encoded: entry.1)))
        #expect(image.width == Self.width)
        #expect(image.height == Self.height)
        #expect(image.pixels == [UInt8](try #require(Data(base64Encoded: entry.2))))
    }

    @Test func damagedFilesAreRefused() throws {
        let valid = try #require(Data(base64Encoded: Self.cases[6].1))
        #expect(throws: PNGDecoder.Failure.notPNG) { try PNGDecoder.decode(Data("GIF89a".utf8)) }
        #expect(throws: PNGDecoder.Failure.truncated) { try PNGDecoder.decode(valid.prefix(valid.count - 20)) }
        var flipped = valid
        flipped[40] ^= 0x01
        #expect(throws: (any Error).self) { try PNGDecoder.decode(flipped) }
        #expect(throws: PNGDecoder.Failure.unsupported("an interlaced image")) {
            try PNGDecoder.decode(try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFEAIAAAEhb41aAAAAEXRFWHRDb21tZW50AGFuY2lsbGFyeRtmJ+cAAABxSURBVHjaAdcAKP8AIHHi8aa2ZhiN6+eZ9MF+zITpZ7nlIkY21VE+Rcjj4l2hyCUkezXbTyVwAWzlmwU+pOMuIHcLkDKEi8qmR+/W6uvcbYkNIyinolkxiZdcNlv1+8GWeAJKsQgQ8ZBsS059ZNdpP5s9GsdUauYtJQAAAHFJREFUW3mJzF0ncOZuA3vj+k8auTjemT2T+LwDLyzxS8EX4v6qMYpbRp7PxQNwrl913vtWgt76diA+geoFSv2T4XVRkbJvBP3v/PcQJIGD3s2JawU7m7dBO/EzG+H1iq0D4cHTFl83evJAwgLJ9ZbCFQXGbecjwzcSAAAAAElFTkSuQmCC")))
        }
    }
}

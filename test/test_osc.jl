using Test
using Ressac

@testset "osc" begin
    @testset "OSC-string: null-terminated, padded to 4 bytes" begin
        @test Ressac._osc_string("hi")    == UInt8[0x68, 0x69, 0x00, 0x00]
        @test Ressac._osc_string("test")  == UInt8[0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00, 0x00]
        @test Ressac._osc_string("/foo")  == UInt8[0x2f, 0x66, 0x6f, 0x6f, 0x00, 0x00, 0x00, 0x00]
        @test Ressac._osc_string("")      == UInt8[0x00, 0x00, 0x00, 0x00]
    end

    @testset "encode message with single Int32" begin
        # /foo + ,i + Int32(42) big-endian
        bytes = encode(OSCMessage("/foo", Any[Int32(42)]))
        @test bytes == vcat(
            UInt8[0x2f, 0x66, 0x6f, 0x6f, 0x00, 0x00, 0x00, 0x00],
            UInt8[0x2c, 0x69, 0x00, 0x00],
            UInt8[0x00, 0x00, 0x00, 0x2a],
        )
    end

    @testset "encode message with single Float32" begin
        # 1.0f0 in IEEE 754 = 0x3F800000
        bytes = encode(OSCMessage("/foo", Any[Float32(1.0)]))
        @test bytes == vcat(
            UInt8[0x2f, 0x66, 0x6f, 0x6f, 0x00, 0x00, 0x00, 0x00],
            UInt8[0x2c, 0x66, 0x00, 0x00],
            UInt8[0x3f, 0x80, 0x00, 0x00],
        )
    end

    @testset "encode message with single String" begin
        bytes = encode(OSCMessage("/dirt/play", Any["bd"]))
        @test bytes == vcat(
            # "/dirt/play" = 10 chars, +null +padding(1) = 12 bytes
            UInt8[0x2f, 0x64, 0x69, 0x72, 0x74, 0x2f, 0x70, 0x6c, 0x61, 0x79, 0x00, 0x00],
            UInt8[0x2c, 0x73, 0x00, 0x00],
            UInt8[0x62, 0x64, 0x00, 0x00],
        )
    end

    @testset "encode mixed-args message" begin
        # Args: Int32(1), "bar", Float32(2.5)
        # Typetag: ",isf" → 4 chars + null + 3 padding = 8 bytes
        bytes = encode(OSCMessage("/foo", Any[Int32(1), "bar", Float32(2.5)]))
        @test length(bytes) == 8 + 8 + 4 + 4 + 4  # addr + tt + i + s + f
        @test bytes[1:8]   == UInt8[0x2f, 0x66, 0x6f, 0x6f, 0x00, 0x00, 0x00, 0x00]
        @test bytes[9:16]  == UInt8[0x2c, 0x69, 0x73, 0x66, 0x00, 0x00, 0x00, 0x00]
        @test bytes[17:20] == UInt8[0x00, 0x00, 0x00, 0x01]
        @test bytes[21:24] == UInt8[0x62, 0x61, 0x72, 0x00]
        @test bytes[25:28] == UInt8[0x40, 0x20, 0x00, 0x00]  # 2.5f0
    end

    @testset "bundle header + NTP time tag at unix_time=0" begin
        # NTP epoch starts 1900-01-01; unix epoch is 2_208_988_800 seconds later.
        # So unix_time=0 → NTP seconds = 2_208_988_800 = 0x83AA7E80.
        msg = OSCMessage("/foo", Any[Int32(1)])
        bytes = encode(OSCBundle(0.0, [msg]))
        @test bytes[1:8]  == UInt8[0x23, 0x62, 0x75, 0x6e, 0x64, 0x6c, 0x65, 0x00]  # "#bundle\0"
        @test bytes[9:16] == UInt8[0x83, 0xaa, 0x7e, 0x80, 0x00, 0x00, 0x00, 0x00]
        # Followed by Int32(size) + the inner message.
        inner = encode(msg)
        @test bytes[17:20] == reinterpret(UInt8, [hton(Int32(length(inner)))])
        @test bytes[21:end] == inner
    end

    @testset "round-trip: decode_message ∘ encode = id" begin
        original = OSCMessage("/dirt/play", Any[Int32(1), "bar", Float32(2.5)])
        decoded = Ressac.decode_message(encode(original))
        @test decoded.address == "/dirt/play"
        @test decoded.args[1] === Int32(1)
        @test decoded.args[2] == "bar"
        @test decoded.args[3] === Float32(2.5)
    end

    @testset "round-trip preserves empty arg list" begin
        original = OSCMessage("/heartbeat", Any[])
        decoded = Ressac.decode_message(encode(original))
        @test decoded.address == "/heartbeat"
        @test decoded.args == Any[]
    end
end

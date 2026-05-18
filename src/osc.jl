using Sockets

# OSC 1.0 — minimal encoder/decoder + UDP client.
# Spec: https://opensoundcontrol.stanford.edu/spec-1_0.html
#
# Supported argument types: Int32 ('i'), Float32 ('f'), String ('s'), Blob ('b').
# Everything is big-endian; every field is padded to a multiple of 4 bytes.

# NTP epoch (1900-01-01) is 2_208_988_800 seconds before the Unix epoch.
const NTP_UNIX_OFFSET = UInt64(2_208_988_800)
const _BUNDLE_HEADER = UInt8[0x23, 0x62, 0x75, 0x6e, 0x64, 0x6c, 0x65, 0x00]  # "#bundle\0"

"""
    OSCMessage(address, args)

An OSC message: an address pattern (e.g. `"/dirt/play"`) and a heterogeneous
argument vector. Supported argument element types are `Int32`, `Float32`,
`String`, and `Vector{UInt8}` (blob).
"""
struct OSCMessage
    address::String
    args::Vector{Any}
end

"""
    OSCBundle(time, messages)

An OSC bundle: a Unix timestamp (in seconds, with fractional part) and a
vector of `OSCMessage`s. The Unix time is converted to NTP at encoding.
"""
struct OSCBundle
    time::Float64
    messages::Vector{OSCMessage}
end

# ---------------------------------------------------------------------------
# Encoding helpers
# ---------------------------------------------------------------------------

"""
    _osc_string(s) -> Vector{UInt8}

Encode a string as an OSC-string: append a null terminator, then pad the
total length up to the next multiple of 4 bytes.
"""
function _osc_string(s::AbstractString)
    bytes = Vector{UInt8}(codeunits(s))
    push!(bytes, 0x00)
    pad = (4 - (length(bytes) % 4)) % 4
    for _ in 1:pad
        push!(bytes, 0x00)
    end
    return bytes
end

function _osc_blob(b::Vector{UInt8})
    io = IOBuffer()
    write(io, hton(Int32(length(b))))
    write(io, b)
    pad = (4 - (length(b) % 4)) % 4
    for _ in 1:pad
        write(io, UInt8(0))
    end
    return take!(io)
end

function _typetag(args::Vector{Any})
    io = IOBuffer()
    write(io, UInt8(','))
    for a in args
        write(io, _typecode(a))
    end
    return String(take!(io))
end

_typecode(::Int32)        = UInt8('i')
_typecode(::Float32)      = UInt8('f')
_typecode(::AbstractString) = UInt8('s')
_typecode(::Vector{UInt8})  = UInt8('b')
_typecode(x) = throw(ArgumentError("Unsupported OSC argument type: $(typeof(x))"))

function _write_arg!(io::IO, x::Int32)
    write(io, hton(x))
end
function _write_arg!(io::IO, x::Float32)
    write(io, hton(x))
end
function _write_arg!(io::IO, s::AbstractString)
    write(io, _osc_string(s))
end
function _write_arg!(io::IO, b::Vector{UInt8})
    write(io, _osc_blob(b))
end

# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------

"""
    encode(msg::OSCMessage) -> Vector{UInt8}

Serialise an OSC message to bytes.
"""
function encode(msg::OSCMessage)
    io = IOBuffer()
    write(io, _osc_string(msg.address))
    write(io, _osc_string(_typetag(msg.args)))
    for a in msg.args
        _write_arg!(io, a)
    end
    return take!(io)
end

"""
    encode(bundle::OSCBundle) -> Vector{UInt8}

Serialise an OSC bundle to bytes. The Unix `bundle.time` is converted to an
NTP 64-bit timestamp (32-bit seconds + 32-bit fraction).
"""
function encode(bundle::OSCBundle)
    io = IOBuffer()
    write(io, _BUNDLE_HEADER)
    write(io, hton(_ntp_timestamp(bundle.time)))
    for msg in bundle.messages
        msg_bytes = encode(msg)
        write(io, hton(Int32(length(msg_bytes))))
        write(io, msg_bytes)
    end
    return take!(io)
end

function _ntp_timestamp(unix_time::Float64)
    sec_part   = floor(unix_time)
    frac_part  = unix_time - sec_part
    ntp_sec    = UInt32(UInt64(sec_part) + NTP_UNIX_OFFSET)
    # 2^32 fractional units per second.
    ntp_frac   = UInt32(round(frac_part * 4_294_967_296.0))
    return (UInt64(ntp_sec) << 32) | UInt64(ntp_frac)
end

# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------

"""
    decode_message(bytes) -> OSCMessage

Parse a single OSC message from its byte representation. Does not handle
bundles; pass each inner message individually if you need bundle decoding.
"""
function decode_message(bytes::Vector{UInt8})
    io = IOBuffer(bytes)
    address = _read_osc_string!(io)
    typetag = _read_osc_string!(io)
    startswith(typetag, ",") || throw(ArgumentError("OSC typetag must start with ','"))
    args = Any[]
    for c in typetag[2:end]
        push!(args, _read_arg!(io, c))
    end
    return OSCMessage(address, args)
end

function _read_osc_string!(io::IO)
    bytes = UInt8[]
    while !eof(io)
        b = read(io, UInt8)
        b == 0x00 && break
        push!(bytes, b)
    end
    # Skip remaining padding bytes (string + null was padded to a 4-byte multiple).
    consumed = length(bytes) + 1
    pad = (4 - (consumed % 4)) % 4
    for _ in 1:pad
        eof(io) && break
        read(io, UInt8)
    end
    return String(bytes)
end

function _read_arg!(io::IO, code::Char)
    if code == 'i'
        return ntoh(read(io, Int32))
    elseif code == 'f'
        return ntoh(read(io, Float32))
    elseif code == 's'
        return _read_osc_string!(io)
    elseif code == 'b'
        size = Int(ntoh(read(io, Int32)))
        data = read(io, size)
        pad = (4 - (size % 4)) % 4
        for _ in 1:pad
            eof(io) && break
            read(io, UInt8)
        end
        return data
    else
        throw(ArgumentError("Unknown OSC typetag code '$code'"))
    end
end

# ---------------------------------------------------------------------------
# UDP client
# ---------------------------------------------------------------------------

"""
    OSCClient(host, port)

UDP client for sending OSC messages and bundles. `host` is an `IPv4` (e.g.
`Sockets.IPv4("127.0.0.1")`) and `port` is a `UInt16` like `0x0000_DF7B`
(57211) or just `UInt16(57120)`.
"""
struct OSCClient
    host::IPv4
    port::UInt16
    socket::UDPSocket
    OSCClient(host::IPv4, port::Integer) = new(host, UInt16(port), UDPSocket())
end

OSCClient(host::AbstractString, port::Integer) = OSCClient(IPv4(host), port)

"""
    send_osc(client, payload)

Send raw OSC bytes (already encoded) over UDP. `payload` may also be an
`OSCMessage` or `OSCBundle`, in which case it is encoded first.
"""
send_osc(c::OSCClient, bytes::Vector{UInt8}) = Sockets.send(c.socket, c.host, c.port, bytes)
send_osc(c::OSCClient, msg::OSCMessage)      = send_osc(c, encode(msg))
send_osc(c::OSCClient, bundle::OSCBundle)    = send_osc(c, encode(bundle))

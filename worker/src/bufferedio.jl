# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

const OUTPUT_BUFFER_THRESHOLD = 8192

mutable struct BufferedOutput{S <: IO} <: IO
    const sink::S
    const buf::(@static if VERSION >= v"1.11-" Memory{UInt8} else Vector{UInt8} end)
    pos::Int
end

BufferedOutput(sink::IO) = BufferedOutput(sink, fieldtype(BufferedOutput, :buf)(undef, OUTPUT_BUFFER_THRESHOLD), 0)

function Base.flush(o::BufferedOutput)
    if o.pos > 0
        GC.@preserve o unsafe_write(o.sink, pointer(o.buf), UInt(o.pos))
        o.pos = 0
    end
    flush(o.sink)
end

function Base.unsafe_write(o::BufferedOutput, p::Ptr{UInt8}, n::UInt)
    ni = Int(n)
    if o.pos + ni > OUTPUT_BUFFER_THRESHOLD
        flush(o)
        if ni >= OUTPUT_BUFFER_THRESHOLD
            unsafe_write(o.sink, p, n)
            flush(o.sink)
            return ni
        end
    end
    GC.@preserve o unsafe_copyto!(pointer(o.buf, o.pos + 1), p, ni)
    o.pos += ni
    ni
end

function Base.write(o::BufferedOutput, b::UInt8)
    o.pos == OUTPUT_BUFFER_THRESHOLD && flush(o)
    @inbounds o.buf[o.pos + 1] = b
    o.pos += 1
    1
end

Base.close(o::BufferedOutput) = (flush(o); close(o.sink); nothing)
Base.isopen(o::BufferedOutput) = isopen(o.sink)
Base.displaysize(o::BufferedOutput) = displaysize(o.sink)
Base.get(o::BufferedOutput, key::Symbol, default) = get(o.sink, key, default)

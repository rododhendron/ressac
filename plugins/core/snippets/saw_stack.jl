var saws = Mix.ar(Array.fill(5, { |i|
    Saw.ar(freq * (1 + ((i - 2) * 0.012)))
})) * 0.2;

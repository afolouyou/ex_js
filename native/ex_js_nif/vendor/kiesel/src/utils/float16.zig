//! Adapted from https://github.com/apple/swift/blob/main/stdlib/public/runtime/Float16Support.cpp
//!
//! This is necessary because we cannot do f64 to f16 conversion in Zig using the roundTiesToEven
//! mode with builtins. See https://github.com/tc39/proposal-float16array/issues/12.
//!
//! Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
//! Licensed under Apache License v2.0 with Runtime Library Exception
//!
//! See https://swift.org/LICENSE.txt for license information
//! See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

pub fn __truncdfhf2(d: f64) f16 {
    var f: f32 = @floatCast(d);
    var e: u32 = @bitCast(f);
    const exact_halfway = (e & 0x1fff) == 0x1000;
    const fabs = @abs(f);
    if (exact_halfway or fabs < 0x1.0p-14) {
        const dabs = @abs(d);
        if (fabs > dabs) e -= ~e & 1;
        if (fabs < dabs) e |= 1;
        f = @bitCast(e);
    }
    return @bitCast(__gnu_f2h_ieee(f));
}

fn __gnu_f2h_ieee(f_: f32) u16 {
    var f: f32 = f_;
    const signbit = @as(u32, @bitCast(f)) & 0x80000000;
    var exponent = @as(u32, @bitCast(f)) & 0x7f800000;
    if (exponent < 0x38800000) exponent = 0x38800000;
    const magic: f32 = @bitCast(
        if (exponent > 0x47000000) signbit else signbit | exponent + 0x06800000,
    );
    f = 0x1.0p112 * f;
    f = 0x1.0p-112 * f + magic;
    f -= magic;
    f *= 0x1.0p-112;
    const magnitude = @as(u32, @bitCast(f)) >> 13 & 0x7fff;
    return @intCast(signbit >> 16 | magnitude);
}

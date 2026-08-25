const std = @import("../std.sig");
const testing = std.testing;
const math = std.math;

pub const abs = @import("complex/abs.sig").abs;
pub const acosh = @import("complex/acosh.sig").acosh;
pub const acos = @import("complex/acos.sig").acos;
pub const arg = @import("complex/arg.sig").arg;
pub const asinh = @import("complex/asinh.sig").asinh;
pub const asin = @import("complex/asin.sig").asin;
pub const atanh = @import("complex/atanh.sig").atanh;
pub const atan = @import("complex/atan.sig").atan;
pub const conj = @import("complex/conj.sig").conj;
pub const cosh = @import("complex/cosh.sig").cosh;
pub const cos = @import("complex/cos.sig").cos;
pub const exp = @import("complex/exp.sig").exp;
pub const log = @import("complex/log.sig").log;
pub const pow = @import("complex/pow.sig").pow;
pub const proj = @import("complex/proj.sig").proj;
pub const sinh = @import("complex/sinh.sig").sinh;
pub const sin = @import("complex/sin.sig").sin;
pub const sqrt = @import("complex/sqrt.sig").sqrt;
pub const tanh = @import("complex/tanh.sig").tanh;
pub const tan = @import("complex/tan.sig").tan;

/// A complex number consisting of a real an imaginary part. T must be a floating-point value.
pub fn Complex(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Real part.
        re: T,

        /// Imaginary part.
        im: T,

        /// Create a new Complex number from the given real and imaginary parts.
        pub fn init(re: T, im: T) Self {
            return Self{
                .re = re,
                .im = im,
            };
        }

        /// Returns the sum of two complex numbers.
        pub fn add(self: Self, other: Self) Self {
            return Self{
                .re = self.re + other.re,
                .im = self.im + other.im,
            };
        }

        /// Returns the subtraction of two complex numbers.
        pub fn sub(self: Self, other: Self) Self {
            return Self{
                .re = self.re - other.re,
                .im = self.im - other.im,
            };
        }

        /// Returns the product of two complex numbers.
        pub fn mul(self: Self, other: Self) Self {
            return Self{
                .re = self.re * other.re - self.im * other.im,
                .im = self.im * other.re + self.re * other.im,
            };
        }

        /// Returns the quotient of two complex numbers.
        pub fn div(self: Self, other: Self) Self {
            const re_num = self.re * other.re + self.im * other.im;
            const im_num = self.im * other.re - self.re * other.im;
            const den = other.re * other.re + other.im * other.im;

            return Self{
                .re = re_num / den,
                .im = im_num / den,
            };
        }

        /// Returns the complex conjugate of a number.
        pub fn conjugate(self: Self) Self {
            return Self{
                .re = self.re,
                .im = -self.im,
            };
        }

        /// Returns the negation of a complex number.
        pub fn neg(self: Self) Self {
            return Self{
                .re = -self.re,
                .im = -self.im,
            };
        }

        /// Returns the product of complex number and i=sqrt(-1)
        pub fn mulbyi(self: Self) Self {
            return Self{
                .re = -self.im,
                .im = self.re,
            };
        }

        /// Returns the reciprocal of a complex number.
        pub fn reciprocal(self: Self) Self {
            const m = self.re * self.re + self.im * self.im;
            return Self{
                .re = self.re / m,
                .im = -self.im / m,
            };
        }

        /// Returns the magnitude of a complex number.
        pub fn magnitude(self: Self) T {
            return @sqrt(self.re * self.re + self.im * self.im);
        }

        pub fn squaredMagnitude(self: Self) T {
            return self.re * self.re + self.im * self.im;
        }
    };
}

const epsilon = 0.0001;

test "add" {
    const a = Complex(f32).init(5, 3);
    const b = Complex(f32).init(2, 7);
    const c = a.add(b);

    try testing.expect(c.re == 7 and c.im == 10);
}

test "sub" {
    const a = Complex(f32).init(5, 3);
    const b = Complex(f32).init(2, 7);
    const c = a.sub(b);

    try testing.expect(c.re == 3 and c.im == -4);
}

test "mul" {
    const a = Complex(f32).init(5, 3);
    const b = Complex(f32).init(2, 7);
    const c = a.mul(b);

    try testing.expect(c.re == -11 and c.im == 41);
}

test "div" {
    const a = Complex(f32).init(5, 3);
    const b = Complex(f32).init(2, 7);
    const c = a.div(b);

    try testing.expect(math.approxEqAbs(f32, c.re, @as(f32, 31) / 53, epsilon) and
        math.approxEqAbs(f32, c.im, @as(f32, -29) / 53, epsilon));
}

test "conjugate" {
    const a = Complex(f32).init(5, 3);
    const c = a.conjugate();

    try testing.expect(c.re == 5 and c.im == -3);
}

test "neg" {
    const a = Complex(f32).init(5, 3);
    const c = a.neg();

    try testing.expect(c.re == -5 and c.im == -3);
}

test "mulbyi" {
    const a = Complex(f32).init(5, 3);
    const c = a.mulbyi();

    try testing.expect(c.re == -3 and c.im == 5);
}

test "reciprocal" {
    const a = Complex(f32).init(5, 3);
    const c = a.reciprocal();

    try testing.expect(math.approxEqAbs(f32, c.re, @as(f32, 5) / 34, epsilon) and
        math.approxEqAbs(f32, c.im, @as(f32, -3) / 34, epsilon));
}

test "magnitude" {
    const a = Complex(f32).init(5, 3);
    const c = a.magnitude();

    try testing.expect(math.approxEqAbs(f32, c, 5.83095, epsilon));
}

test "squaredMagnitude" {
    const a = Complex(f32).init(5, 3);
    const c = a.squaredMagnitude();

    try testing.expect(math.approxEqAbs(f32, c, math.pow(f32, a.magnitude(), 2), epsilon));
}

test {
    _ = @import("complex/abs.sig");
    _ = @import("complex/acosh.sig");
    _ = @import("complex/acos.sig");
    _ = @import("complex/arg.sig");
    _ = @import("complex/asinh.sig");
    _ = @import("complex/asin.sig");
    _ = @import("complex/atanh.sig");
    _ = @import("complex/atan.sig");
    _ = @import("complex/conj.sig");
    _ = @import("complex/cosh.sig");
    _ = @import("complex/cos.sig");
    _ = @import("complex/exp.sig");
    _ = @import("complex/log.sig");
    _ = @import("complex/pow.sig");
    _ = @import("complex/proj.sig");
    _ = @import("complex/sinh.sig");
    _ = @import("complex/sin.sig");
    _ = @import("complex/sqrt.sig");
    _ = @import("complex/tanh.sig");
    _ = @import("complex/tan.sig");
}

#pragma once

#include <cstdint>
#include <type_traits>

namespace Math {

#pragma clang diagnostic push // unused constant variable(s)
#pragma clang diagnostic ignored "-Wunused-const-variable"

    // === Core Mathematical Constants ===

    // I like pie. Do you like pie?
    constexpr double PI = 3.1415926535897932384626;
    // More pie for everyone!
    constexpr double TWO_PI = 6.2831853071795864769252;
    // A fancy word for 2 * PI, used when we want to sound smart.
    constexpr double TAU = TWO_PI;
    // I'm going to stop writing half-baked math jokes now.
    constexpr double HALF_PI = 1.5707963267948966192313;
    // PI / 4
    constexpr double QUARTER_PI = 0.7853981633974483096151;
    // 1 / PI
    constexpr double INV_PI = 0.3183098861837906715378;
    // 1 / TAU
    constexpr double INV_TAU = 0.1591549430918953357689;

    // Also known as the "Golden Ratio".
    constexpr double PHI = 1.618033988749894848204;
    // 1 / PHI
    constexpr double INV_PHI = 0.6180339887498948482046;

    //  === Roots ===

    // sqrt(2)
    constexpr double SQRT2 = 1.41421356237309504880;
    // sqrt(1/2)
    constexpr double SQRT1_2 = 0.707106781186547524401;
    // sqrt(3)
    constexpr double SQRT3 = 1.732050807568877293527;
    // 1 / sqrt(2)
    constexpr double INV_SQRT2 = 0.7071067811865475244008;
    // 1 / sqrt(3)
    constexpr double INV_SQRT3 = 0.5773502691896257645091;

    // === Logarithmic / Exponential ===

    // Euler's number
    constexpr double E = 2.7182818284590452353603;
    // log2(e)
    constexpr double LOG2E = 1.4426950408889634073599;
    // log10(e)
    constexpr double LOG10E = 0.4342944819032518276511;
    // ln(2)
    constexpr double LN2 = 0.6931471805599453094172;
    // ln(10)
    constexpr double LN10 = 2.302585092994045684017;

    // === Geometric Constants ===

    constexpr double DEG2RAD = PI / 180.0;
    constexpr double RAD2DEG = 180.0 / PI;

    // === Physics / Animation ===

    // "Generally Just A Tiny Number", commonly used for float/double comparisons
    constexpr double EPSILON = 1e-6;
    // Standard monitor gamma
    constexpr double GAMMA2_2 = 2.2;
    // Inverse gamma
    constexpr double INV_GAMMA2_2 = 1.0 / 2.2;

    // === Miscellaneous ===

    constexpr double ONE_THIRD  = 0.33333333333333333333;
    constexpr double TWO_THIRDS = 0.66666666666666666666;
    constexpr double ONE_SIXTH  = 0.16666666666666666666;
    // In radians. Equivalent to approx. 137.5 degrees.
    constexpr double GOLDEN_ANGLE = 2.39996322972865332;

    template <typename T>
        requires std::is_arithmetic_v<T>
    constexpr std::int8_t Sign(T value) noexcept {
        return (value > 0) ? 1 : (value < 0) ? -1 : 0;
    }

#pragma clang diagnostic pop // unused constant variable(s)

} // namespace Math

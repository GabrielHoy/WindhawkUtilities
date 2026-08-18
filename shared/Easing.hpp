/**
 * @file Easing.hpp
 * @brief Various easing functions.
 */
#pragma once

#include "MathUtil.hpp"
#include <cmath>
#include <map>

namespace Easing {

    enum class EasingFunction {
        SineIn,
        SineOut,
        SineInOut,
        QuadIn,
        QuadOut,
        QuadInOut,
        CubicIn,
        CubicOut,
        CubicInOut,
        QuartIn,
        QuartOut,
        QuartInOut,
        QuintIn,
        QuintOut,
        QuintInOut,
        ExpoIn,
        ExpoOut,
        ExpoInOut,
        CircIn,
        CircOut,
        CircInOut,
        BackIn,
        BackOut,
        BackInOut,
        ElasticIn,
        ElasticOut,
        ElasticInOut,
        BounceIn,
        BounceOut,
        BounceInOut
    };

    typedef double (*easingFunc_t)(double);

    constexpr double SineIn(double t) noexcept {
        return std::sin(1.5707963 * t);
    }

    constexpr double SineOut(double t) noexcept {
        return 1 + std::sin(1.5707963 * (t - 1));
    }

    constexpr double SineInOut(double t) noexcept {
        return 0.5 * (1 + std::sin(3.1415926 * (t - 0.5)));
    }

    constexpr double QuadIn(double t) noexcept {
        return t * t;
    }

    constexpr double QuadOut(double t) noexcept {
        return t * (2 - t);
    }

    constexpr double QuadInOut(double t) noexcept {
        return t < 0.5 ? 2 * t * t : t * (4 - 2 * t) - 1;
    }

    constexpr double CubicIn(double t) noexcept {
        return t * t * t;
    }

    constexpr double CubicOut(double t) noexcept {
        double u = t - 1;
        return 1 + u * u * u;
    }

    constexpr double CubicInOut(double t) noexcept {
        if (t < 0.5) {
            return 4 * t * t * t;
        }
        double u = t - 1;
        return 1 + 4 * u * u * u;
    }

    constexpr double QuartIn(double t) noexcept {
        t *= t;
        return t * t;
    }

    constexpr double QuartOut(double t) noexcept {
        double u = t - 1;
        u *= u;
        return 1 - u * u;
    }

    constexpr double QuartInOut(double t) noexcept {
        if (t < 0.5) {
            t *= t;
            return 8 * t * t;
        }
        double u = t - 1;
        u *= u;
        return 1 - 8 * u * u;
    }

    constexpr double QuintIn(double t) noexcept {
        double t2 = t * t;
        return t * t2 * t2;
    }

    constexpr double QuintOut(double t) noexcept {
        double u  = t - 1;
        double u2 = u * u;
        return 1 + u * u2 * u2;
    }

    constexpr double QuintInOut(double t) noexcept {
        if (t < 0.5) {
            double t2 = t * t;
            return 16 * t * t2 * t2;
        }
        double u  = t - 1;
        double u2 = u * u;
        return 1 + 16 * u * u2 * u2;
    }

    inline double ExpoIn(double t) noexcept {
        return (std::pow(2, 8 * t) - 1) / 255;
    }

    inline double ExpoOut(double t) noexcept {
        return 1 - std::pow(2, -8 * t);
    }

    inline double ExpoInOut(double t) noexcept {
        if (t < 0.5) {
            return (std::pow(2, 16 * t) - 1) / 510;
        } else {
            return 1 - 0.5 * std::pow(2, -16 * (t - 0.5));
        }
    }

    inline double CircIn(double t) noexcept {
        return 1 - std::sqrt(1 - t);
    }

    inline double CircOut(double t) noexcept {
        return std::sqrt(t);
    }

    inline double CircInOut(double t) noexcept {
        if (t < 0.5) {
            return (1 - std::sqrt(1 - 2 * t)) * 0.5;
        } else {
            return (1 + std::sqrt(2 * t - 1)) * 0.5;
        }
    }

    constexpr double BackIn(double t) noexcept {
        return t * t * (2.70158 * t - 1.70158);
    }

    constexpr double BackOut(double t) noexcept {
        double u = t - 1;
        return 1 + u * u * (2.70158 * u + 1.70158);
    }

    constexpr double BackInOut(double t) noexcept {
        if (t < 0.5) {
            return t * t * (7 * t - 2.5) * 2;
        }
        double u = t - 1;
        return 1 + u * u * 2 * (7 * u + 2.5);
    }

    inline double ElasticIn(double t) noexcept {
        double t2 = t * t;
        return t2 * t2 * std::sin(t * Math::PI * 4.5);
    }

    inline double ElasticOut(double t) noexcept {
        double t2 = (t - 1) * (t - 1);
        return 1 - t2 * t2 * std::cos(t * Math::PI * 4.5);
    }

    inline double ElasticInOut(double t) noexcept {
        double t2;
        if (t < 0.45) {
            t2 = t * t;
            return 8 * t2 * t2 * std::sin(t * Math::PI * 9);
        } else if (t < 0.55) {
            return 0.5 + 0.75 * std::sin(t * Math::PI * 4);
        } else {
            t2 = (t - 1) * (t - 1);
            return 1 - 8 * t2 * t2 * std::sin(t * Math::PI * 9);
        }
    }

    inline double BounceIn(double t) noexcept {
        return std::pow(2, 6 * (t - 1)) * std::abs(std::sin(t * Math::PI * 3.5));
    }

    inline double BounceOut(double t) noexcept {
        return 1 - std::pow(2, -6 * t) * std::abs(std::cos(t * Math::PI * 3.5));
    }

    inline double BounceInOut(double t) noexcept {
        if (t < 0.5) {
            return 8 * std::pow(2, 8 * (t - 1)) * std::abs(std::sin(t * Math::PI * 7));
        } else {
            return 1 - 8 * std::pow(2, -8 * t) * std::abs(std::sin(t * Math::PI * 7));
        }
    }

    inline easingFunc_t GetEasingFunction(EasingFunction function) {
        static std::map<EasingFunction, easingFunc_t> easingFunctions;
        if (easingFunctions.empty()) {
            easingFunctions.insert(std::make_pair(EasingFunction::SineIn, SineIn));
            easingFunctions.insert(std::make_pair(EasingFunction::SineOut, SineOut));
            easingFunctions.insert(std::make_pair(EasingFunction::SineInOut, SineInOut));
            easingFunctions.insert(std::make_pair(EasingFunction::QuadIn, QuadIn));
            easingFunctions.insert(std::make_pair(EasingFunction::QuadOut, QuadOut));
            easingFunctions.insert(std::make_pair(EasingFunction::QuadInOut, QuadInOut));
            easingFunctions.insert(std::make_pair(EasingFunction::CubicIn, CubicIn));
            easingFunctions.insert(std::make_pair(EasingFunction::CubicOut, CubicOut));
            easingFunctions.insert(std::make_pair(EasingFunction::CubicInOut, CubicInOut));
            easingFunctions.insert(std::make_pair(EasingFunction::QuartIn, QuartIn));
            easingFunctions.insert(std::make_pair(EasingFunction::QuartOut, QuartOut));
            easingFunctions.insert(std::make_pair(EasingFunction::QuartInOut, QuartInOut));
            easingFunctions.insert(std::make_pair(EasingFunction::QuintIn, QuintIn));
            easingFunctions.insert(std::make_pair(EasingFunction::QuintOut, QuintOut));
            easingFunctions.insert(std::make_pair(EasingFunction::QuintInOut, QuintInOut));
            easingFunctions.insert(std::make_pair(EasingFunction::ExpoIn, ExpoIn));
            easingFunctions.insert(std::make_pair(EasingFunction::ExpoOut, ExpoOut));
            easingFunctions.insert(std::make_pair(EasingFunction::ExpoInOut, ExpoInOut));
            easingFunctions.insert(std::make_pair(EasingFunction::CircIn, CircIn));
            easingFunctions.insert(std::make_pair(EasingFunction::CircOut, CircOut));
            easingFunctions.insert(std::make_pair(EasingFunction::CircInOut, CircInOut));
            easingFunctions.insert(std::make_pair(EasingFunction::BackIn, BackIn));
            easingFunctions.insert(std::make_pair(EasingFunction::BackOut, BackOut));
            easingFunctions.insert(std::make_pair(EasingFunction::BackInOut, BackInOut));
            easingFunctions.insert(std::make_pair(EasingFunction::ElasticIn, ElasticIn));
            easingFunctions.insert(std::make_pair(EasingFunction::ElasticOut, ElasticOut));
            easingFunctions.insert(std::make_pair(EasingFunction::ElasticInOut, ElasticInOut));
            easingFunctions.insert(std::make_pair(EasingFunction::BounceIn, BounceIn));
            easingFunctions.insert(std::make_pair(EasingFunction::BounceOut, BounceOut));
            easingFunctions.insert(std::make_pair(EasingFunction::BounceInOut, BounceInOut));
        }

        auto it = easingFunctions.find(function);
        return it == easingFunctions.end() ? nullptr : it->second;
    }

} // namespace Easing

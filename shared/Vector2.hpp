#pragma once

#include <cmath>
#include <ostream>
#include <stdexcept>

template <typename T = float>
    requires std::is_floating_point_v<T>
class Vector2 {
  public:
    T x;
    T y;

    // Constructors
    constexpr Vector2()
        : x(0)
        , y(0) {
    }

    constexpr Vector2(T x, T y)
        : x(x)
        , y(y) {
    }

    // Copy constructor
    constexpr Vector2(const Vector2& other)
        : x(other.x)
        , y(other.y) {
    }

    // Assignment operator
    constexpr Vector2& operator=(const Vector2& other) {
        if (this != &other) {
            x = other.x;
            y = other.y;
        }
        return *this;
    }

    // Addition
    constexpr Vector2 operator+(const Vector2& other) const {
        return Vector2(x + other.x, y + other.y);
    }

    constexpr Vector2& operator+=(const Vector2& other) {
        x += other.x;
        y += other.y;
        return *this;
    }

    // Subtraction
    constexpr Vector2 operator-(const Vector2& other) const {
        return Vector2(x - other.x, y - other.y);
    }

    constexpr Vector2& operator-=(const Vector2& other) {
        x -= other.x;
        y -= other.y;
        return *this;
    }

    // Scalar multiplication
    constexpr Vector2 operator*(T scalar) const {
        return Vector2(x * scalar, y * scalar);
    }

    constexpr Vector2& operator*=(T scalar) {
        x *= scalar;
        y *= scalar;
        return *this;
    }

    // Vector multiplication (component-wise)
    constexpr Vector2 operator*(const Vector2& other) const {
        return Vector2(x * other.x, y * other.y);
    }

    constexpr Vector2& operator*=(const Vector2& other) {
        x *= other.x;
        y *= other.y;
        return *this;
    }

    // Scalar division
    constexpr Vector2 operator/(T scalar) const {
        if (scalar == 0) {
            throw std::invalid_argument("Division by zero");
        }
        return Vector2(x / scalar, y / scalar);
    }

    constexpr Vector2& operator/=(T scalar) {
        if (scalar == 0) {
            throw std::invalid_argument("Division by zero");
        }
        x /= scalar;
        y /= scalar;
        return *this;
    }

    // Vector division (component-wise)
    constexpr Vector2 operator/(const Vector2& other) const {
        if (other.x == 0 || other.y == 0) {
            throw std::invalid_argument("Division by zero");
        }
        return Vector2(x / other.x, y / other.y);
    }

    constexpr Vector2& operator/=(const Vector2& other) {
        if (other.x == 0 || other.y == 0) {
            throw std::invalid_argument("Division by zero");
        }
        x /= other.x;
        y /= other.y;
        return *this;
    }

    // Dot product
    constexpr T Dot(const Vector2& other) const {
        return x * other.x + y * other.y;
    }

    // Length (magnitude)
    constexpr T Magnitude() const {
        return static_cast<T>(std::sqrt(x * x + y * y));
    }

    // Linear interpolation between two vectors
    static constexpr Vector2 Lerp(const Vector2& a, const Vector2& b, T t) {
        // Clamp t to range [0, 1] for safer interpolation
        T clampedT = (t < 0) ? 0 : ((t > 1) ? 1 : t);
        return a + (b - a) * clampedT;
    }

    // Squared length (faster when only comparing lengths)
    constexpr T LengthSquared() const {
        return x * x + y * y;
    }

    // Normalize the vector (make it unit length)
    constexpr Vector2 Normalized() const {
        T len = Magnitude();
        if (len == 0) {
            return *this;
        }
        return Vector2(x / len, y / len);
    }

    constexpr void Normalize() {
        T len = Magnitude();
        if (len == 0) {
            return;
        }
        x /= len;
        y /= len;
    }

    // Equality operators
    constexpr bool operator==(const Vector2& other) const {
        return x == other.x && y == other.y;
    }

    constexpr bool operator!=(const Vector2& other) const {
        return !(*this == other);
    }

    // Stream output
    constexpr friend std::ostream& operator<<(std::ostream& os, const Vector2& v) {
        os << "(" << v.x << ", " << v.y << ")";
        return os;
    }
};

// Scalar multiplication (scalar * vector)
template <typename T>
constexpr Vector2<T> operator*(T scalar, const Vector2<T>& v) {
    return v * scalar;
}

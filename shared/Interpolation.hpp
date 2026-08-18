#pragma once

#include <type_traits>

template <typename T1, typename T2, typename T3>
  requires(std::is_arithmetic_v<std::common_type_t<T1, T2, T3>>)
inline std::common_type_t<T1, T2, T3> Lerp(T1 a, T2 b, T3 t) noexcept {
  return a + (b - a) * t;
}
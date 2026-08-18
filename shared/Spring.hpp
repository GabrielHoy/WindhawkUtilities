/**
 * @file Spring.hpp
 * @brief Damped spring implementation.
 */
#pragma once

#include <algorithm>
#include <cmath>

class Spring {
  private:
    float value;
    float velocity;
    float target;
    float stiffness;
    float damping;

  public:
    Spring(float initialValue = 0.0f, float stiffness = 180.0f, float damping = 14.0f)
        : value(initialValue)
        , velocity(0.0f)
        , target(initialValue)
        , stiffness(stiffness)
        , damping(damping) {
    }

    float Value() const {
        return value;
    }

    float Velocity() const {
        return velocity;
    }

    float Target() const {
        return target;
    }

    float Stiffness() const {
        return stiffness;
    }

    float Damping() const {
        return damping;
    }

    void SetTarget(float newTarget) {
        target = newTarget;
    }

    void SetStiffness(float newStiffness) {
        stiffness = newStiffness;
    }

    void SetDamping(float newDamping) {
        damping = newDamping;
    }

    void Reset(float resetValueTo, float resetVelocityTo = 0.0f) {
        value    = resetValueTo;
        velocity = resetVelocityTo;
        target   = value;
    }

    void SnapTo(float valueSnapTo) {
        value    = valueSnapTo;
        velocity = 0.0f;
        target   = value;
    }

    bool IsSettled(float positionThreshold = 1.0e-4f, float velocityThreshold = 1.0e-4f) const {
        return std::abs(value - target) <= positionThreshold && std::abs(velocity) <= velocityThreshold;
    }

    /**
     * Advances the spring by `deltaTime` seconds; returns the new value.
     */
    float Update(float deltaTime) {
        if (deltaTime <= 0.0f) {
            return value;
        }

        // (Large dT steps destabilize explicit integration)
        deltaTime = std::min(deltaTime, 0.064f);

        const float displacement = target - value;
        velocity += (stiffness * displacement - damping * velocity) * deltaTime;
        value += velocity * deltaTime;

        return value;
    }

    static Spring SnappyPreset(float initialValue = 0.0f) {
        return Spring(initialValue, 320.0f, 18.0f);
    }

    static Spring GentlePreset(float initialValue = 0.0f) {
        return Spring(initialValue, 120.0f, 10.0f);
    }

    static Spring BouncyPreset(float initialValue = 0.0f) {
        return Spring(initialValue, 200.0f, 8.0f);
    }
};
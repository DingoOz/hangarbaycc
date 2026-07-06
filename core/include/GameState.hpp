#pragma once

#include <cstdint>
#include <cmath>

namespace hangarbay {

constexpr float SCREEN_WIDTH = 640.f;
constexpr float SCREEN_HEIGHT = 480.f;

struct Input {
    bool up{false};
    bool down{false};
    bool left{false};
    bool right{false};
    // additional inputs for shooting, weapon expansion etc. omitted
};

struct GameState {
    float playerX{SCREEN_WIDTH / 2.f};
    float playerY{SCREEN_HEIGHT - 50.f}; // start near bottom
    float scrollOffset{0.f};

    static constexpr float PLAYER_SPEED = 200.f; // units per second
    static constexpr float SCROLL_SPEED = 100.f; // units per second

    void update(float dt, const Input& input) {
        // apply scrolling
        scrollOffset += SCROLL_SPEED * dt;

        // movement vector
        float vx{0.f}, vy{0.f};
        if (input.up)   vy -= 1.f;
        if (input.down) vy += 1.f;
        if (input.left) vx -= 1.f;
        if (input.right)vx += 1.f;

        // normalize for diagonal movement
        if (vx != 0.f && vy != 0.f) {
            float norm = std::sqrt(vx*vx + vy*vy);
            vx /= norm;
            vy /= norm;
        }

        playerX += vx * PLAYER_SPEED * dt;
        playerY += vy * PLAYER_SPEED * dt;

        // clamp to screen bounds
        if (playerX < 0.f) playerX = 0.f;
        if (playerX > SCREEN_WIDTH - 32.f) playerX = SCREEN_WIDTH - 32.f; // assume sprite width 32
        if (playerY < 0.f) playerY = 0.f;
        if (playerY > SCREEN_HEIGHT - 32.f) playerY = SCREEN_HEIGHT - 32.f;
    }
};

} // namespace hangarbay

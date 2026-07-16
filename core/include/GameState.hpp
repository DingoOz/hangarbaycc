#pragma once

#include <cstdint>
#include <cmath>
#include <vector>
#include <cstdlib>
#include <algorithm>

namespace hangarbay {

constexpr float SCREEN_WIDTH = 640.f;
constexpr float SCREEN_HEIGHT = 480.f;

struct Input {
    bool up{false};
    bool down{false};
    bool left{false};
    bool right{false};
    bool fire{false}; // primary weapon fire
    // additional inputs for shooting, weapon expansion etc. omitted
};

struct Bullet {
    float x{0.f};
    float y{0.f};
};

// Simple enemy representation
struct Enemy {
    float x{0.f};
    float y{0.f};
    int type{0}; // 0: goblin, 1: orc, 2: dragon
    int health{3};
};

struct GameState {
    float playerX{SCREEN_WIDTH / 2.f};
    float playerY{SCREEN_HEIGHT - 50.f}; // start near bottom
    float scrollOffset{0.f};

    static constexpr float PLAYER_SPEED = 200.f; // units per second
    static constexpr float SCROLL_SPEED = 100.f; // units per second
    static constexpr float FIRE_RATE = 5.0f; // shots per second
    static constexpr float BULLET_SPEED = 400.f;
    static constexpr float ENEMY_SPEED = 80.f;

    std::vector<Bullet> bullets;
    float timeSinceLastShot{0.f};

    enum class WeaponType { None = 0, Laser, Missile, Plasma, Bomb };
    WeaponType currentWeapon{WeaponType::None};
    int expansionLevel{0};
    static constexpr int MAX_EXPANSION_LEVEL = 3;

    void switchWeapon(WeaponType newType) {
        if (newType != currentWeapon) {
            currentWeapon = newType;
            expansionLevel = 0; // reset on new weapon
        }
    }

    void expandWeapon() {
        if (expansionLevel < MAX_EXPANSION_LEVEL)
            ++expansionLevel;
    }

    std::vector<Enemy> enemies;
    int score{0};
    int lives{3};

    // Spawn an enemy at world coordinates
    void spawnEnemy(int type, float x, float y) {
        Enemy e; e.type = type; e.x = x; e.y = y; e.health = 3;
        enemies.push_back(e);
    }

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

        // clamp to screen bounds (assuming 32x32 sprite)
        if (playerX < 0.f) playerX = 0.f;
        if (playerX > SCREEN_WIDTH - 32.f) playerX = SCREEN_WIDTH - 32.f;
        if (playerY < 0.f) playerY = 0.f;
        if (playerY > SCREEN_HEIGHT - 32.f) playerY = SCREEN_HEIGHT - 32.f;

        // handle firing with rate limit
        timeSinceLastShot += dt;
        if (input.fire && timeSinceLastShot >= 1.0f / FIRE_RATE) {
            bullets.push_back({playerX, playerY});
            timeSinceLastShot = 0.f;
        }

        // move bullets
        for (auto it = bullets.begin(); it != bullets.end();) {
            it->y -= BULLET_SPEED * dt;
            if (it->y < 0) {
                it = bullets.erase(it);
            } else {
                ++it;
            }
        }

        // move enemies and check collision with player
        for (auto eit = enemies.begin(); eit != enemies.end();) {
            eit->x -= ENEMY_SPEED * dt;
            // simple AABB collision between enemy and player
            bool hitPlayer = (
                std::abs(eit->x - playerX) < 16.f &&
                std::abs(eit->y - playerY) < 16.f
            );
            if (hitPlayer) {
                // reduce life and remove enemy
                lives--;
                eit = enemies.erase(eit);
                continue;
            }
            // remove off-screen left
            if (eit->x < -32.f) {
                eit = enemies.erase(eit);
                continue;
            }
            ++eit;
        }

        // collision between bullets and enemies
        for (auto bIt = bullets.begin(); bIt != bullets.end();) {
            bool bulletRemoved = false;
            for (auto eIt = enemies.begin(); eIt != enemies.end() && !bulletRemoved;) {
                if (
                    std::abs(bIt->x - eIt->x) < 16.f &&
                    std::abs(bIt->y - eIt->y) < 16.f
                ) {
                    // hit enemy
                    eIt->health--;
                    if (eIt->health <= 0) {
                        score += 10; // arbitrary points per kill
                        enemies.erase(eIt);
                    } else {
                        ++eIt;
                    }
                    bulletRemoved = true;
                } else {
                    ++eIt;
                }
            }
            if (bulletRemoved) {
                bIt = bullets.erase(bIt);
            } else {
                ++bIt;
            }
        }
    }

    int characterSelection{0}; // 0: default, 1/2/3 for other types

};

} // namespace hangarbay

#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest/doctest.h"
#include "../core/include/GameState.hpp"

TEST_CASE("Dummy") {
    CHECK(1 == 1);
} // end Dummy

TEST_CASE("Movement clamping") {
    hangarbay::GameState state;
    hangarbay::Input input{.up = true, .down=false, .left=false, .right=false};

    float dt = 10.f; // large dt to force boundary
    state.update(dt, input);
    CHECK(state.playerY >= 0.f);
    CHECK(state.playerX >= 0.f);
    CHECK(state.playerX <= hangarbay::SCREEN_WIDTH - 32.f);
}

TEST_CASE("Scroll offset") {
    hangarbay::GameState state;
    float dt = 2.f;
    state.update(dt, hangarbay::Input{});
    CHECK(doctest::Approx(state.scrollOffset).epsilon(0.001) == hangarbay::GameState::SCROLL_SPEED * dt);
}

TEST_CASE("Fire rate") {
    hangarbay::GameState state;
    hangarbay::Input input{.fire = true};
    float dt = 0.05f; // less than 1/5
    state.update(dt, input);
    CHECK(state.bullets.size() == 0);

    for (int i=0;i<4;i++) {
        state.update(0.05f, input); // accumulate time to exceed fire interval
    }
    CHECK(state.bullets.size() == 1);
}

TEST_CASE("Multiple fire rate") {
    hangarbay::GameState state;
    hangarbay::Input input{.fire = true};
    float dt = 0.05f; // 20 frames per second approx
    for (int i=0;i<20;i++) { // 1 second total
        state.update(dt, input);
    }
    CHECK(state.bullets.size() == 5); // floor(1 * FIRE_RATE)
}

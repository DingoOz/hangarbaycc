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

// Test cases for core logic

TEST_CASE("Weapon expansion capped at 3") {
    hangarbay::GameState state;
    using W = hangarbay::WeaponType;
    state.switchWeapon(W::Laser);
    for (int i=0;i<5;i++) state.expandWeapon();
    CHECK(state.expansionLevel == 3);
}

TEST_CASE("Smart bomb decrements count") {
    hangarbay::GameState state;
    for (int i=0;i<4;i++) {
        int prev = state.bombsRemaining;
        state.activateSmartBomb();
        CHECK(state.bombsRemaining == std::max(0, prev-1));
    }
}

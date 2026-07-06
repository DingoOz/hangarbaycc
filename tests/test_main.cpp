TEST_CASE("Weapon switching resets expansion") {
    hangarbay::GameState state;
    using W = hangarbay::WeaponType;
    state.switchWeapon(W::Laser);
    CHECK(state.expansionLevel == 0);
    state.expandWeapon();
    CHECK(state.expansionLevel == 1);
    state.switchWeapon(W::Missile);
    CHECK(state.expansionLevel == 0);
}

TEST_CASE("Weapon expansion capped at 3") {
    hangarbay::GameState state;
    using W = hangarbay::WeaponType;
    state.switchWeapon(W::Laser);
    for (int i=0;i<5;i++) state.expandWeapon();
    CHECK(state.expansionLevel == 3);
}

TEST_CASE("At least four weapon types exist") {
    using W = hangarbay::WeaponType;
    // just check that we can create instances of each
    W a = W::Laser; W b = W::Missile; W c = W::Plasma; W d = W::Bomb;
    CHECK(static_cast<int>(a) == 1);
    CHECK(static_cast<int>(b) == 2);
    CHECK(static_cast<int>(c) == 3);
    CHECK(static_cast<int>(d) == 4);
}

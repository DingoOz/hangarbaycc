#include <SDL2/SDL_image.h>
#include "GameState.hpp"
#include <iostream>
#include <vector>
#include <fstream>
#include <algorithm>
#include <random>
#include <chrono>
#include <array>

using namespace hangarbay;

// Helper to create a solid color texture
SDL_Texture* createSolidTexture(SDL_Renderer* renderer, Uint8 r, Uint8 g, Uint8 b, int w, int h) {
    SDL_Surface* surf = SDL_CreateRGBSurface(0, w, h, 32,
                                             0x00FF0000,
                                             0x0000FF00,
                                             0x000000FF,
                                             0xFF000000);
    if (!surf) return nullptr;
    SDL_FillRect(surf, NULL, SDL_MapRGB(surf->format, r,g,b));
    SDL_Texture* tex = SDL_CreateTextureFromSurface(renderer, surf);
    SDL_FreeSurface(surf);
        // LoadTexture helper
    SDL_Texture* loadTexture(SDL_Renderer* renderer, const char* path) {
        SDL_Surface* surface = IMG_Load(path);
        if (!surface) { std::cerr << "IMG_Load error: " << IMG_GetError() << std::endl; return nullptr; }
        SDL_Texture* texture = SDL_CreateTextureFromSurface(renderer, surface);
        SDL_FreeSurface(surface);
        return texture;
    }
}


struct HighScoreManager {
    std::string filename = "highscores.txt";
    std::vector<int> scores;
    void load() {
        scores.clear();
        std::ifstream in(filename);
        if (!in) return; // no file yet
        int s;
        while (in >> s) scores.push_back(s);
        std::sort(scores.begin(), scores.end(), std::greater<int>());
        if (scores.size() > 5) scores.resize(5);
    }
    void save() {
        std::ofstream out(filename, std::ios::trunc);
        for (int s : scores) out << s << "\n";
    }
    void addScore(int score) {
        scores.push_back(score);
        std::sort(scores.begin(), scores.end(), std::greater<int>());
        if (scores.size() > 5) scores.resize(5);
    }
};

int main() {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
        std::cerr << "Failed to initialize SDL: " << SDL_GetError() << std::endl;
        return -1;
    }

    SDL_Window* window = SDL_CreateWindow("HangarBayCC", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                          static_cast<int>(SCREEN_WIDTH), static_cast<int>(SCREEN_HEIGHT),
                                          SDL_WINDOW_SHOWN);
    if (!window) {
        std::cerr << "Failed to create window: " << SDL_GetError() << std::endl;
        SDL_Quit();
        return -1;
    }

    SDL_Renderer* renderer = SDL_CreateRenderer(window, -1,
                                                SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
            // Load assets
        SDL_Texture* heroTex = loadTexture(renderer, "assets/hero.png");
        SDL_Texture* bulletTex = loadTexture(renderer, "assets/bullet.png");
        SDL_Texture* enemyTex[3];
        enemyTex[0] = loadTexture(renderer, "assets/enemy0.png");
        enemyTex[1] = loadTexture(renderer, "assets/enemy1.png");
        enemyTex[2] = loadTexture(renderer, "assets/enemy2.png");


GameState game;


    enum class AppState { MENU, PLAYING, GAMEOVER, VICTORY } state = AppState::MENU;

    struct LevelCfg {
        float mapWidth;
        int maxEnemies;
        float spawnInterval;
    } levelConfigs[] = { {2000.f, 10, 1.5f}, {2000.f, 12, 1.2f} };
    int totalLevels = static_cast<int>(sizeof(levelConfigs) / sizeof(LevelCfg));
    int currentLevel = 0;
    int enemiesSpawned = 0;
    Uint32 nextEnemySpawnTime = 0; // in ms

    std::mt19937 rng(static_cast<unsigned>(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::uniform_int_distribution<int> typeDist(0, 2);
    std::uniform_real_distribution<float> yDist(32.f, SCREEN_HEIGHT - 64.f);

    HighScoreManager highScores;
    highScores.load();

    Uint32 lastTime = SDL_GetTicks();
    bool running = true;

    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) { running = false; break; }
            if (state == AppState::MENU && e.type == SDL_KEYDOWN) {
                switch (e.key.keysym.sym) {
                    case SDLK_1: game.characterSelection = 0; state = AppState::PLAYING; break;
                    case SDLK_2: game.characterSelection = 1; state = AppState::PLAYING; break;
                    case SDLK_3: game.characterSelection = 2; state = AppState::PLAYING; break;
                }
            }
        }

        Uint32 currentTime = SDL_GetTicks();
        float dt = (currentTime - lastTime) / 1000.0f;
        lastTime = currentTime;

        const Uint8* keyState = SDL_GetKeyboardState(nullptr);
        Input input;
        input.up   = keyState[SDL_SCANCODE_UP];
        input.down = keyState[SDL_SCANCODE_DOWN];
        input.left = keyState[SDL_SCANCODE_LEFT];
        input.right= keyState[SDL_SCANCODE_RIGHT];
        input.fire = keyState[SDL_SCANCODE_SPACE];

        if (state == AppState::MENU) {
            SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
            SDL_RenderClear(renderer);

            std::array<SDL_Color,3> colors = {{{200,50,50},{50,200,50},{50,50,200}}};
            for (int i = 0; i < 3; ++i) {
                SDL_Rect rect{100 + 150 * i, static_cast<int>(SCREEN_HEIGHT/2.f - 30), 60, 60};
                SDL_SetRenderDrawColor(renderer, colors[i].r, colors[i].g, colors[i].b, 255);
                SDL_RenderFillRect(renderer, &rect);
            }
            SDL_RenderPresent(renderer);
        } else if (state == AppState::PLAYING) {
            const LevelCfg& cfg = levelConfigs[currentLevel];
            if (enemiesSpawned < cfg.maxEnemies && currentTime >= nextEnemySpawnTime) {
                float x = game.scrollOffset + SCREEN_WIDTH + 100.f;
                float y = yDist(rng);
                int type = typeDist(rng);
                game.spawnEnemy(type, x, y);
                ++enemiesSpawned;
                nextEnemySpawnTime = currentTime + static_cast<Uint32>(cfg.spawnInterval * 1000.f);
            }

        game.update(dt, input);
        // Play shooting sound when fired
        // if (input.fire && game.timeSinceLastShot < 0.02f) {
            // Mix_PlayChannel(-1, shootSfx, 0);
        }


            if (game.scrollOffset > cfg.mapWidth && game.enemies.empty()) {
                ++currentLevel;
                enemiesSpawned = 0;
                nextEnemySpawnTime = currentTime + 500; // short pause
                if (currentLevel >= totalLevels) {
                    state = AppState::VICTORY;
                }
            }

            SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
            SDL_RenderClear(renderer);

            SDL_Rect pRect{static_cast<int>(game.playerX - game.scrollOffset), static_cast<int>(game.playerY), 32, 32};
            // Draw player using texture
            SDL_RenderCopy(renderer, heroTex, NULL, &pRect);


            // Draw enemies using textures
            for (const auto& e : game.enemies) {
                SDL_Rect er{static_cast<int>(e.x - game.scrollOffset), static_cast<int>(e.y), 32, 32};
                SDL_RenderCopy(renderer, enemyTex[e.type], NULL, &er);
            }


            // Draw bullets using texture
            for (const auto& b : game.bullets) {
                SDL_Rect br{static_cast<int>(b.x - game.scrollOffset), static_cast<int>(b.y), 8, 16};
                SDL_RenderCopy(renderer, bulletTex, NULL, &br);
            }


            SDL_RenderPresent(renderer);
        } else if (state == AppState::VICTORY || state == AppState::GAMEOVER) {
            std::cout << "\nGame " << (state==AppState::VICTORY?"Victory!":"Game Over!")
                      << " Score: " << game.score << "\n";
            highScores.addScore(game.score);
            highScores.save();
            std::cout << "High Scores:" << std::endl;
            for (size_t i=0;i<highScores.scores.size();++i) {
                std::cout << i+1 << ") " << highScores.scores[i] << "\n";
            }
            running = false;
        }
    }

    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}

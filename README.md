# 🌌 AetherSim: Advanced Multi-Agent Physics Simulation

AetherSim is a production-grade 2D simulation engine combining rigid-body physics with autonomous AI agents.

## 🚀 Quick Start
```bash
chmod +x setup.sh
./setup.sh
source venv/bin/activate
python main.py
```

## 🛠 Architecture
- **Physics Engine**: Custom impulse-based solver handling elastic collisions and basic rigid body dynamics.
- **AI Layer**: Hybrid intelligence using:
    - **Behavior Trees**: High-level state management (Hunt vs Wander).
    - **TinyNN**: A scratch-built feedforward network for fine-tuned movement forces.
    - **Boids**: Implementation of Reynolds' flocking (Separation, Alignment, Cohesion).
- **Rendering**: Pygame-based renderer with a virtual camera allowing panning and zooming.

## ⌨️ Controls
| Key | Action |
|-----|--------|
| `Space` | Pause / Resume |
| `R` | Reset current scenario |
| `1` | Switch to Flocking Demo |
| `2` | Switch to Ecosystem (Predator/Prey) |
| `S` | Save state to JSON |
| `Mouse Drag` | Pan Camera |
| `Mouse Wheel` | Zoom In/Out |

## 📈 Extensions
- Add A* pathfinding for agents navigating around static obstacles.
- Implement a genetic algorithm to evolve the `TinyNN` weights of the most successful predators.
- Add spring-joints for complex multi-body structures.

"""A simple text-based MUD (Multi-User Dungeon) game."""

import random


# ---------------------------------------------------------------------------
# Game world data
# ---------------------------------------------------------------------------

ROOMS = {
    "corridor": {
        "name": "Dark Corridor",
        "desc": "You stand in a long, dark corridor. Faint torchlight flickers on the walls.",
        "exits": {"north": "torchlit_chamber", "south": None},
        "items": ["rusty_sword"],
    },
    "torchlit_chamber": {
        "name": "Torchlit Chamber",
        "desc": "A chamber lit by torches. The air smells of damp stone and old metal.",
        "exits": {"south": "corridor", "east": None, "west": "courtyard"},
        "items": ["torch"],
    },
    "courtyard": {
        "name": "Courtyard",
        "desc": "An open courtyard with a stone fountain in the center. A heavy wooden door stands to the east.",
        "exits": {"west": "torchlit_chamber", "east": None},
        "items": [],
    },
    "armory": {
        "name": "Armory",
        "desc": "Shelves line the walls with weapons and armor. A sturdy table sits in the center.",
        "exits": {"south": "crypt"},
        "items": ["shield", "helmet"],
    },
    "crypt": {
        "name": "Crypt",
        "desc": "A cold, damp crypt with a skeleton slumped against one wall. A small chest sits nearby.",
        "exits": {"north": "armory"},
        "items": ["skeleton_key"],
    },
    "treasure_room": {
        "name": "Treasure Room",
        "desc": "Gold coins spill across the floor! A heavy iron door blocks your path north.",
        "exits": {"south": "crypt"},
        "items": ["gold_pile"],
    },
}

ITEMS = {
    "rusty_sword": {
        "name": "Rusty Sword",
        "desc": "A sword covered in rust. It looks ancient and heavy.",
        "weight": 5,
    },
    "torch": {
        "name": "Torch",
        "desc": "A wooden torch with a small flame flickering at the end.",
        "weight": 1,
    },
    "shield": {
        "name": "Shield",
        "desc": "A round wooden shield with an iron boss in the center. It looks well-used but sturdy.",
        "weight": 3,
    },
    "helmet": {
        "name": "Helmet",
        "desc": "A steel helmet with a tarnished visor. It still fits snugly on your head.",
        "weight": 2,
    },
    "skeleton_key": {
        "name": "Skeleton Key",
        "desc": "An ornate key shaped like a skeleton's hand. It gleams faintly in the dim light.",
        "weight": 0,
    },
    "gold_pile": {
        "name": "Pile of Gold",
        "desc": "A glittering pile of gold coins and gems worth more than you'll ever earn!",
        "weight": 10,
    },
}

NPCS = {
    "goblin": {
        "name": "Goblin",
        "desc": "A scrawny goblin with sharp teeth and a mischievous grin.",
        "hp": 20,
        "attack": 3,
        "dialogue": [
            "Hey! Give me your stuff!",
            "I'll take that sword for you... uh, *borrow* it!",
            "Run away! I won't hurt you if you run away!",
        ],
    },
    "guardian": {
        "name": "Stone Guardian",
        "desc": "A massive stone golem with glowing red eyes. It stands motionless.",
        "hp": 100,
        "attack": 8,
        "dialogue": [
            "*The guardian rumbles silently.*",
            "*Its red eyes glow brighter.*",
            "*It raises a massive fist.*",
        ],
    },
}

ENEMIES = {
    "goblin": NPCS["goblin"],
    "guardian": NPCS["guardian"],
}


# ---------------------------------------------------------------------------
# Game state
# ---------------------------------------------------------------------------

class Player:
    """The player's game state."""

    def __init__(self):
        self.inventory = []
        self.hp = 100
        self.max_hp = 100
        self.attack = 5
        self.defense = 2
        self.location = "corridor"
        self.has_been_here = {"corridor": True}

    def take_damage(self, amount):
        damage = max(1, amount - self.defense)
        self.hp -= damage
        if self.hp < 0:
            self.hp = 0
        return damage


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def random_dialogue(npc):
    """Return a random line from an NPC's dialogue list."""
    lines = npc["dialogue"]
    if len(lines) == 1:
        return lines[0]
    return random.choice(lines)


def pick_up(item_name):
    """Pick up an item from the current room. Returns True on success."""
    global player
    room = ROOMS[player.location]
    items = room.get("items", [])
    if item_name not in items or item_name == "":
        print(f"You can't find {item_name} here.")
        return False
    idx = items.index(item_name)
    del items[idx]
    player.inventory.append(item_name)
    print(f"You picked up the {ITEMS[item_name]['name']}.")
    return True


def drop_item(item_name):
    """Drop an item from your inventory. Returns True on success."""
    if not item_name or item_name not in player.inventory:
        print("You're not carrying that.")
        return False
    idx = player.inventory.index(item_name)
    del player.inventory[idx]
    room = ROOMS[player.location]
    room.setdefault("items", []).append(item_name)
    print(f"You dropped the {ITEMS[item_name]['name']}.")
    return True


def examine_item(item_name=None):
    """Print the description of an item."""
    if not item_name or item_name not in ITEMS:
        print("You don't know what that is.")
        return
    it = ITEMS[item_name]
    print(f"The {it['name']} — {it['desc']}.")


def look_at():
    """Print the current room's description."""
    room = ROOMS.get(player.location, {})
    if not room:
        print("Error: Your position is invalid!")
        return
    items = room.get("items", [])
    print(room["desc"])
    if player.inventory:
        inv = ", ".join(player.inventory)
        print(f"\nYou are carrying: {inv}.")


def go(direction):
    """Move in a direction. Returns True on success."""
    room = ROOMS.get(player.location, {})
    exits = room.get("exits", {})
    target = exits.get(direction)

    if not direction or direction not in exits:
        print(f"There is no {direction} there.")
        return False

    player.location = target
    player.has_been_here[target] = True
    print()  # blank line for readability

    enemy_name, enemy_info = find_enemy(target)
    if enemy_name:
        fight(enemy_name, enemy_info)
        return False

    return True


def find_enemy(location):
    """Check if there's an enemy in a given location. Returns (name, info) or (None, None)."""
    if not location:
        return None, None
    room = ROOMS.get(location, {})
    for name, info in ENEMIES.items():
        # Goblin appears randomly; guardian always blocks the treasure_room exit
        if name == "goblin" and random.random() < 0.5:
            return name, info
        elif name == "guardian":
            pass
    return None, None


def fight(enemy_name, enemy_info):
    """Simple turn-based combat."""
    print(f"\nA {enemy_info['name']} appears!")
    while True:
        print()
        print(f"{enemy_info['name']}: {random_dialogue(enemy_info)}")

        action = input("Type 'attack' or 'run': ").strip().lower()

        if action == "attack":
            hit_roll = random.random()
            if hit_roll < 0.7:
                damage = player.attack + random.randint(1, 3)
                print(f"You hit the {enemy_name} for {damage} damage!")
                enemy_info["hp"] -= damage

                enemy_dmg = enemy_info["attack"] + random.randint(-2, 2)
                dmg_taken = player.take_damage(enemy_dmg)
                print(f"The {enemy_name} hits you for {dmg_taken} damage!")

                if enemy_info["hp"] <= 0:
                    print(f"\nYou defeated the {enemy_name}!")
                    break
                elif player.hp <= 0:
                    print("\nYou have been killed...")
                    return False
            else:
                print("Your attack misses.")

        elif action == "run":
            if enemy_info["name"] == "guardian":
                print("\nThe guardian is too strong to run from! Fight or die!")
                continue
            chance = random.random()
            if chance < 0.5:
                print("You escape safely!")
                return True
            else:
                dmg = enemy_info["attack"] + random.randint(1, 3)
                player.take_damage(dmg)
                print(f"You tried to run but the {enemy_name} caught you! Took {dmg} damage.")

        else:
            print("Unknown command. Type 'attack' or 'run'.")


def help_msg():
    """Print available commands."""
    print("Available commands:")
    for cmd in COMMANDS:
        print(f"  {cmd}")


def quit_game():
    """End the game."""
    print("\nThanks for playing! Goodbye.")
    return True


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

COMMANDS = {
    "look": look_at,
    "go": go,
    "take": pick_up,
    "drop": drop_item,
    "examine": examine_item,
    "inventory": lambda: print(f"You are carrying: {', '.join(player.inventory) if player.inventory else 'nothing.'}"),
    "help": help_msg,
    "quit": quit_game,
}


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main():
    global player
    player = Player()

    print("=" * 50)
    print("Welcome to the Dark Dungeon!")
    print("=" * 50)
    look_at()

    while True:
        if player.hp <= 0:
            print("\nGame Over! Try again, adventurer.")
            break

        cmd = input("What will you do? ").strip().lower()

        if not cmd:
            continue

        parts = cmd.split(maxsplit=1)
        action = parts[0]
        arg = parts[1].lower() if len(parts) > 1 else None

        # Validate location before processing any command
        if player.location not in ROOMS:
            print("Error: Your position is invalid! Game over.")
            break

        handler = COMMANDS.get(action, None)
        if handler is None:
            print(f"I don't understand '{action}'. Type 'help' for a list of commands.")
            continue

        # Commands that take no argument
        no_arg_cmds = {"look", "inventory", "help"}
        result = False
        if action == "go" and arg is None:
            print("Go where? Specify a direction, e.g. 'go north'.")
            continue
        elif action in no_arg_cmds or arg is None:
            handler()
        else:
            result = handler(arg)

        # quit_game signals the loop to end; other handlers' True/False
        # results just report command success and don't stop the game.
        if action == "quit" and result is True:
            break


if __name__ == "__main__":
    main()

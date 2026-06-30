import sys


def greeting(name):
    print(f"Hey {name}")


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python mud.py <name>")
        sys.exit(1)
    greeting(sys.argv[1])

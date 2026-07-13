from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
MIN_LOC = 3000
MAX_LOC = 4000


def main() -> None:
    files = sorted(SRC.glob("*.vy"))
    physical = 0
    non_empty = 0

    for path in files:
        lines = path.read_text(encoding="utf-8").splitlines()
        physical += len(lines)
        non_empty += sum(1 for line in lines if line.strip())

    print(f"src physical LOC: {physical}")
    print(f"src non-empty LOC: {non_empty}")

    if physical < MIN_LOC or physical > MAX_LOC:
        raise SystemExit(f"src physical LOC must remain between {MIN_LOC} and {MAX_LOC}")
    if non_empty < MIN_LOC or non_empty > MAX_LOC:
        raise SystemExit(f"src non-empty LOC must remain between {MIN_LOC} and {MAX_LOC}")


if __name__ == "__main__":
    main()

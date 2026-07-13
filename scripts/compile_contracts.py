from pathlib import Path

from vyper import compile_code


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


def main() -> None:
    contracts = sorted(SRC.glob("*.vy"))
    if not contracts:
        raise SystemExit("no Vyper contracts found")

    for path in contracts:
        source = path.read_text(encoding="utf-8")
        compile_code(source, output_formats=["bytecode", "abi"])
        print(f"compiled {path.relative_to(ROOT).as_posix()}")


if __name__ == "__main__":
    main()

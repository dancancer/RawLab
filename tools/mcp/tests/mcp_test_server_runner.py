"""Windows test bootstrap; the production entrypoint and config stay unchanged."""
from rawlab_mcp.__main__ import main
from subprocess_support import python_cli_patch


if __name__ == "__main__":
    with python_cli_patch():
        main()

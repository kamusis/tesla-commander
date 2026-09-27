"""
Universal Cross-Shell Environment Loader.
Supports:
- Process environment variables (os.environ)
- Local .env files (current working dir or project dir)
- Shell configurations: Zsh (.zshrc, .zshenv), Bash (.bashrc, .bash_profile, .profile), Fish (config.fish)
"""

import os
import re
from typing import Optional

def load_env_var(name: str) -> Optional[str]:
    """
    Load an environment variable flexibly across shells and environments.
    1. Returns directly from os.environ if present.
    2. Searches local .env files (in current working directory and script directories).
    3. Dynamically inspects shell configuration files according to $SHELL and standard Unix profiles.
    """
    # 1. Direct process environment
    val = os.environ.get(name)
    if val:
        return val.strip()

    # 2. Local .env files
    candidate_files = []
    cwd_env = os.path.join(os.getcwd(), ".env")
    candidate_files.append(cwd_env)

    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        candidate_files.append(os.path.join(script_dir, ".env"))
        candidate_files.append(os.path.join(script_dir, "..", ".env"))
    except Exception:
        pass

    # 3. User shell configuration files
    home = os.path.expanduser("~")
    shell = os.environ.get("SHELL", "").lower()

    shell_specific = []
    if "zsh" in shell:
        shell_specific = [os.path.join(home, ".zshenv"), os.path.join(home, ".zshrc")]
    elif "fish" in shell:
        shell_specific = [os.path.join(home, ".config", "fish", "config.fish")]
    elif "bash" in shell:
        shell_specific = [os.path.join(home, ".bashrc"), os.path.join(home, ".bash_profile")]

    common_shell_files = [
        os.path.join(home, ".zshenv"),
        os.path.join(home, ".zshrc"),
        os.path.join(home, ".bashrc"),
        os.path.join(home, ".bash_profile"),
        os.path.join(home, ".profile"),
        os.path.join(home, ".config", "fish", "config.fish"),
    ]

    for fpath in shell_specific + common_shell_files:
        if fpath not in candidate_files:
            candidate_files.append(fpath)

    # 4. Search and parse files
    for file_path in candidate_files:
        if not os.path.isfile(file_path):
            continue
        try:
            with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue

                    # POSIX / Sh / Bash / Zsh: export VAR="val" or VAR="val"
                    match = re.match(rf'^(?:export\s+)?{name}=["\']?([^"\'#\r\n]+)', line)
                    if match:
                        return match.group(1).strip()

                    # Fish shell: set -gx VAR "val" or set -x VAR "val" or set VAR "val"
                    match_fish = re.match(rf'^set\s+(?:-[a-zA-Z]+\s+)*{name}\s+["\']?([^"\'#\r\n]+)', line)
                    if match_fish:
                        return match_fish.group(1).strip()
        except Exception:
            continue

    return None

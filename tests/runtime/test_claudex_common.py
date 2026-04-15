from pathlib import Path
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "scripts" / "claudex-common.sh"


def _helper(function_name: str, root: Path, braid_root: Path) -> str:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            f'. "{HELPER}"; {function_name} "{root}" "{braid_root}"',
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def test_default_repo_lane_uses_shared_state_dir(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    root.mkdir()

    assert _helper("claudex_state_dir", root, root / ".b2r") == str(root / ".claude" / "claudex")


def test_named_b2r_lane_gets_isolated_state_dir(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    root.mkdir()

    assert _helper("claudex_state_dir", root, root / ".b2r-v2-stable") == str(
        root / ".claude" / "claudex" / "b2r-v2-stable"
    )


def test_external_non_b2r_root_stays_on_shared_state_dir(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    root.mkdir()
    external = tmp_path / "external-braid-root"
    external.mkdir()

    assert _helper("claudex_state_dir", root, external) == str(root / ".claude" / "claudex")

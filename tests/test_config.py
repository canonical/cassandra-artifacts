"""Tests for the snap's configuration handling, against an installed snap.

Everything here goes through "snap set" and "snap unset" on the real snap, so it
covers snapd's part as well as the hook's - notably that an option whose
configure hook failed is rolled back, which is what the hook relies on to keep a
refusal from repeating on the next refresh.

The snap is left exactly as it was found: each test restores cassandra.yaml, the
recorded state and the snap options. The configure log is not restored, since it
is an append-only record and test entries in it are harmless.

Nothing here restarts the daemon, so a running Cassandra never sees these values
- it reads cassandra.yaml only at startup.
"""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parent.parent

SNAP = "cassandra"
SNAP_PATH = Path("/snap/cassandra/current")
SNAP_DATA = Path("/var/snap/cassandra/current")
SNAP_COMMON = Path("/var/snap/cassandra/common")

RENDER_CONFIG = SNAP_PATH / "opt" / "shared" / "bin" / "render-config.sh"
SHIPPED_CONF = SNAP_PATH / "etc" / "cassandra" / "cassandra.yaml"
LIVE_CONF = SNAP_DATA / "etc" / "cassandra" / "cassandra.yaml"
LIVE_STATE = SNAP_DATA / "ops" / "rendered-config.yaml"
LIVE_LOG = SNAP_COMMON / "ops" / "snap" / "logs" / "hook-configure.log"

# Values for the whole mapping. Never applied to a running node, so they only
# have to be plausible, and distinguishable from the shipped defaults.
OPTION_VALUES = {
    "broadcast-address": "10.0.0.5",
    "broadcast-rpc-address": "10.0.0.5",
    "cluster-name": "Config Test Cluster",
    "endpoint-snitch": "GossipingPropertyFileSnitch",
    "listen-address": "10.0.0.5",
    "num-tokens": "32",
    "rpc-address": "10.0.0.5",
    "seeds": "10.0.0.5:7000",
}


def snap_installed():
    if not shutil.which("snap"):
        return False
    return subprocess.run(["snap", "list", SNAP], capture_output=True).returncode == 0


def root_available():
    return subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0


pytestmark = [
    pytest.mark.skipif(not snap_installed(), reason=f"the {SNAP} snap is not installed"),
    pytest.mark.skipif(
        not root_available(),
        reason="needs passwordless sudo: snap get/set and cassandra.yaml are root owned",
    ),
]


def snap_get():
    """Every option currently set on the snap."""
    result = subprocess.run(
        ["sudo", "-n", "snap", "get", SNAP, "-d"], capture_output=True, text=True
    )
    if result.returncode != 0:
        # snapd fails rather than printing {} when nothing is set
        return {}
    return json.loads(result.stdout)


def snap_set(*assignments):
    return subprocess.run(
        ["sudo", "-n", "snap", "set", SNAP, *assignments], capture_output=True, text=True
    )


def snap_unset(*options):
    return subprocess.run(
        ["sudo", "-n", "snap", "unset", SNAP, *options], capture_output=True, text=True
    )


def assignment(key, value):
    """A "snap set" argument. snapd parses a JSON value back into a document."""
    if isinstance(value, str):
        return f"{key}={value}"
    return f"{key}={json.dumps(value)}"


def write_as_root(path, content):
    subprocess.run(
        ["sudo", "-n", "tee", str(path)],
        input=content,
        stdout=subprocess.DEVNULL,
        check=True,
    )


def config_options():
    """The option -> key mapping the installed snap declares."""
    body = re.search(
        r"declare -A CONFIG_OPTIONS=\((.*?)\n\)", RENDER_CONFIG.read_text(), re.DOTALL
    )
    assert body, f"CONFIG_OPTIONS not found in {RENDER_CONFIG}"

    return dict(re.findall(r"\[(\S+)\]=\"([^\"]+)\"", body.group(1)))


def yaml_key_label(key_path):
    """The key path as cassandra.yaml spells it.

    Mirrors key_label() in render-config.sh, which turns the "/" separated path
    the scripts traverse into the dotted form the file and the README use.
    """
    return re.sub(r"/", ".", re.sub(r"/\[", "[", key_path))


def read_key(document, key_path):
    """Follows a render-config.sh key path ("a/[0]/b") into a parsed document."""
    value = document
    for element in key_path.split("/"):
        if element.startswith("["):
            value = value[int(element.strip("[]"))]
        else:
            value = value[element]
    return value


def rendered():
    return yaml.safe_load(LIVE_CONF.read_text())


def recorded_state():
    if not LIVE_STATE.exists():
        return {}
    return yaml.safe_load(LIVE_STATE.read_text()) or {}


def log_lines():
    if not LIVE_LOG.exists():
        return []
    return LIVE_LOG.read_text().splitlines()


def edit_conf(key, value):
    """Stands in for an administrator editing cassandra.yaml by hand."""
    document = rendered()
    document[key] = value
    write_as_root(LIVE_CONF, yaml.safe_dump(document).encode())


@pytest.fixture(autouse=True)
def restored():
    """Puts the snap back exactly as it was found.

    cassandra.yaml is restored before the options, so that no hand edit is left
    to block them, and again afterwards, so that whatever the hook wrote while
    they were being restored does not survive either.
    """
    options = snap_get()
    conf = LIVE_CONF.read_bytes()
    state = LIVE_STATE.read_bytes() if LIVE_STATE.exists() else None

    def restore_files():
        write_as_root(LIVE_CONF, conf)
        if state is None:
            subprocess.run(["sudo", "-n", "rm", "-f", str(LIVE_STATE)], check=True)
        else:
            write_as_root(LIVE_STATE, state)

    yield

    restore_files()

    added = set(snap_get()) - set(options)
    if added:
        snap_unset(*added)
    if options:
        snap_set(*(assignment(key, value) for key, value in options.items()))

    restore_files()


def test_set_option_reaches_cassandra_yaml():
    result = snap_set("cluster-name=Config Test Cluster")

    assert result.returncode == 0, result.stderr
    assert rendered()["cluster_name"] == "Config Test Cluster"
    assert recorded_state()["cluster-name"] == "Config Test Cluster"


def test_every_supported_option_is_rendered():
    """Guards the whole mapping, not just the key the other tests use."""
    mapping = config_options()
    assert set(OPTION_VALUES) == set(mapping), "test data is out of step with the snap"

    result = snap_set(*(f"{option}={value}" for option, value in OPTION_VALUES.items()))

    assert result.returncode == 0, result.stderr

    document = rendered()
    for option, value in OPTION_VALUES.items():
        written = read_key(document, mapping[option])
        assert str(written).lower() == value.lower(), f"{option} was not rendered"


def test_option_types_are_preserved():
    """num_tokens is the one option that is not a string.

    Snap options are always strings, and a quoted 32 in cassandra.yaml is not
    what Cassandra wants.
    """
    result = snap_set("num-tokens=32")

    assert result.returncode == 0, result.stderr
    assert rendered()["num_tokens"] == 32


def test_seeds_is_written_to_the_nested_key():
    result = snap_set("seeds=10.0.0.1:7000,10.0.0.2:7000")

    assert result.returncode == 0, result.stderr

    provider = rendered()["seed_provider"][0]
    assert provider["parameters"][0]["seeds"] == "10.0.0.1:7000,10.0.0.2:7000"
    assert provider["class_name"].endswith("SimpleSeedProvider")


def test_setting_the_same_value_again_changes_nothing():
    """The hook also runs on refresh, where it must not ask for a restart."""
    assert snap_set("cluster-name=Config Test Cluster").returncode == 0
    before = log_lines()

    assert snap_set("cluster-name=Config Test Cluster").returncode == 0

    new_lines = log_lines()[len(before) :]
    assert not [line for line in new_lines if "setting cluster_name" in line]
    assert not [line for line in new_lines if "snap restart" in line]


def test_unsupported_option_is_rejected_and_rolled_back():
    """snapd must undo an option whose configure hook failed.

    The hook relies on this: it refuses a change it cannot apply, and needs the
    option gone afterwards so the refusal does not repeat on the next refresh.

    "storage-port" is a cassandra.yaml key that is deliberately not mapped, which
    is the only kind of option the hook can see to refuse - see
    test_option_naming_no_cassandra_key_is_accepted.
    """
    result = snap_set("storage-port=7100")

    assert result.returncode != 0
    assert "storage-port" in result.stderr
    assert "storage-port" not in snap_get()


def test_unsupported_option_is_rejected_before_writing():
    before = LIVE_CONF.read_bytes()

    result = snap_set("storage-port=7100", "cluster-name=Rejected")

    assert result.returncode != 0
    assert LIVE_CONF.read_bytes() == before


def test_option_naming_no_cassandra_key_is_accepted():
    """The limit of what the hook can refuse, pinned down.

    snapd offers a hook no way to list the options it holds - "snapctl get" reads
    an option only when it is named - so the hook looks for the cassandra.yaml
    keys it knows about. A name matching none of them is invisible to it, and
    snapd stores it with nobody to read it.
    """
    before = LIVE_CONF.read_bytes()

    result = snap_set("definitely-not-a-cassandra-option=1")

    assert result.returncode == 0, result.stderr
    assert LIVE_CONF.read_bytes() == before


def test_hand_edit_blocks_the_option():
    """The case that has to fail: a "snap set" that cannot be honoured.

    snapd only shows hook output when the hook fails, so refusing is the only way
    the user learns the option went nowhere.
    """
    edit_conf("cluster_name", "Edited By Hand")

    result = snap_set("cluster-name=Config Test Cluster")

    assert result.returncode != 0
    assert "cannot apply the 'cluster-name' option" in result.stderr
    assert "Edited By Hand" in result.stderr
    assert rendered()["cluster_name"] == "Edited By Hand"
    assert "cluster-name" not in snap_get()


def test_blocked_option_leaves_the_others_unwritten():
    """A rejected transaction must not be half applied."""
    edit_conf("cluster_name", "Edited By Hand")
    shipped_tokens = yaml.safe_load(SHIPPED_CONF.read_text())["num_tokens"]

    result = snap_set("cluster-name=Config Test Cluster", "num-tokens=32")

    assert result.returncode != 0
    assert rendered()["num_tokens"] == shipped_tokens
    assert "num-tokens" not in recorded_state()


def test_hand_edit_of_a_rendered_key_is_kept():
    """Editing a key the snap already wrote is allowed, and survives.

    Re-running the hook here must not fail: this is also the refresh path, where
    there is nobody to tell.
    """
    assert snap_set("cluster-name=Config Test Cluster").returncode == 0
    edit_conf("cluster_name", "Edited By Hand")
    before = log_lines()

    # an unrelated option, to make snapd run the hook again
    result = snap_set("num-tokens=32")

    assert result.returncode == 0, result.stderr
    assert rendered()["cluster_name"] == "Edited By Hand"

    new_lines = "\n".join(log_lines()[len(before) :])
    assert "ignoring the 'cluster-name' option" in new_lines


def test_reverting_the_edit_returns_control():
    assert snap_set("cluster-name=Config Test Cluster").returncode == 0
    edit_conf("cluster_name", "Edited By Hand")
    assert snap_set("cluster-name=Another Cluster").returncode != 0

    # restoring the value the snap last wrote hands the key back
    edit_conf("cluster_name", "Config Test Cluster")

    result = snap_set("cluster-name=Another Cluster")

    assert result.returncode == 0, result.stderr
    assert rendered()["cluster_name"] == "Another Cluster"


def test_unset_restores_the_shipped_default():
    shipped = yaml.safe_load(SHIPPED_CONF.read_text())["cluster_name"]
    assert snap_set("cluster-name=Config Test Cluster").returncode == 0

    result = snap_unset("cluster-name")

    assert result.returncode == 0, result.stderr
    assert rendered()["cluster_name"] == shipped
    assert "cluster-name" not in recorded_state()


def test_unset_leaves_a_hand_edit_alone():
    assert snap_set("cluster-name=Config Test Cluster").returncode == 0
    edit_conf("cluster_name", "Edited By Hand")

    result = snap_unset("cluster-name")

    assert result.returncode == 0, result.stderr
    assert rendered()["cluster_name"] == "Edited By Hand"


def test_configure_log_records_the_changes():
    """snapd discards hook output on success, so the log is the only record."""
    before = len(log_lines())

    assert snap_set("cluster-name=First Cluster").returncode == 0
    assert snap_set("cluster-name=Second Cluster").returncode == 0

    new_lines = log_lines()[before:]
    logged = "\n".join(new_lines)

    # both runs, so the log accumulates rather than being truncated each time
    assert "setting cluster_name to 'First Cluster'" in logged
    assert "setting cluster_name to 'Second Cluster'" in logged
    assert "run 'snap restart cassandra.server'" in logged
    for line in new_lines:
        assert re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \S", line), line


def test_readme_documents_every_option():
    """The option table in the README is the contract, so it has to be right."""
    readme = (REPO / "README.md").read_text()

    # the README holds more than one two-column table, so anchor on this one's
    # header and stop at the blank line that ends it
    table = re.search(
        r"^\| Snap option \| `cassandra\.yaml` key \|$\n(.*?)\n\n",
        readme,
        re.DOTALL | re.MULTILINE,
    )
    assert table, "the snap option table is missing from the README"

    documented = dict(
        re.findall(r"^\| `([a-z0-9-]+)` \| `([^`]+)` \|$", table.group(1), re.MULTILINE)
    )
    mapping = {option: yaml_key_label(key) for option, key in config_options().items()}

    assert documented == mapping

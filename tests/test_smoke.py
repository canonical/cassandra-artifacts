import subprocess
import yaml
import pytest

NUM_OPS = 100
CL = "ONE"
SNAP = "cassandra"
KEYSPACE = "smoke"
TABLE = "t1"

def run_command(cmd):
    result = subprocess.run(cmd, shell=False, text=True, capture_output=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        raise subprocess.CalledProcessError(result.returncode, cmd)
    return result.stdout

def is_snap_installed():
    try:
        subprocess.run(["snap", "--version"], check=True)
        return True
    except Exception:
        return False

def cqlsh(*statements):
    # cqlsh -e accepts several ';'-separated statements in a single invocation
    script = " ".join((f"CONSISTENCY {CL};",) + statements)
    return run_command(["snap", "run", f"{SNAP}.cqlsh", "-e", script])


def test_cassandra_snap_installed():
    result = subprocess.run(
        ["snap", "list", SNAP],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    assert result.returncode == 0, (
        f"'{SNAP}' snap is not installed.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )

@pytest.mark.run(after="test_cassandra_snap_installed")
def test_nodetool_status():
    if not is_snap_installed():
        pytest.fail("[FAILED] snap command not found")

    print("Running nodetool status...")

    try:
        output = subprocess.check_output(
            ['sudo', 'snap', 'run', f'{SNAP}.nodetool', 'status'],
            text=True,
            stderr=subprocess.STDOUT
        )
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Failed to run nodetool status: {e.output}") from e

    print(output)

    if "UN" in output:
        print("Nodetool status is healthy: Node is Up and Normal.")
    else:
        raise RuntimeError("Nodetool status check failed! Node is not Up and Normal.")


@pytest.mark.run(after="test_nodetool_status")
def test_write_data():
    if not is_snap_installed():
        pytest.fail("[FAILED] snap command not found")

    print("▶ Starting WRITE test...")

    # Re-runnable: the CI job runs this suite again after a snap upgrade
    inserts = " ".join(
        f"INSERT INTO {KEYSPACE}.{TABLE} (id, message) VALUES ({i}, 'hello-{i}');"
        for i in range(NUM_OPS)
    )

    try:
        cqlsh(
            f"CREATE KEYSPACE IF NOT EXISTS {KEYSPACE} WITH replication = "
            "{'class': 'SimpleStrategy', 'replication_factor': 1};",
            f"CREATE TABLE IF NOT EXISTS {KEYSPACE}.{TABLE} "
            "(id int PRIMARY KEY, message text);",
            inserts,
        )
    except subprocess.CalledProcessError:
        pytest.fail("[FAILED] WRITE test failed")
    print(f"[SUCCESS] WRITE test completed ({NUM_OPS} rows)")

@pytest.mark.run(after="test_write_data")
def test_read_data():
    if not is_snap_installed():
        pytest.fail("[FAILED] snap command not found")

    print("▶ Starting READ test...")
    try:
        output = cqlsh(f"SELECT count(*) FROM {KEYSPACE}.{TABLE};")
    except subprocess.CalledProcessError:
        pytest.fail("[FAILED] READ test failed")

    print(output)

    if NUM_OPS not in [int(tok) for tok in output.split() if tok.isdigit()]:
        pytest.fail(f"[FAILED] expected {NUM_OPS} rows in {KEYSPACE}.{TABLE}")
    print("[SUCCESS] READ test completed")

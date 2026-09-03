# Recipes for building, testing and operating the snap. "just" lists them.

pytest := "poetry run pytest -vv --no-header --tb native --log-cli-level=INFO"

[private]
default:
    @just --list

# Check the packaging against the coding style standards
lint: lint-deps
    poetry check --lock
    poetry run yamllint --no-warnings ./snap/ spread.yaml tests/spread/

# Configuration tests, against an installed snap
config: test-deps
    {{ pytest }} tests/test_config.py -s

# Smoke test, against an installed and running snap
smoke: test-deps
    {{ pytest }} tests/test_smoke.py -s

# Connect the interfaces the daemon refuses to start without, and hardware-observe
connect-interfaces:
    sudo snap connect cassandra:process-control
    sudo snap connect cassandra:system-observe
    sudo snap connect cassandra:mount-observe
    sudo snap connect cassandra:hardware-observe

# See: https://docs.datastax.com/en/cassandra-oss/3.0/cassandra/install/installRecommendSettings.html#Setuserresourcelimits
# Apply the recommended sysctl settings to the running kernel
sysctl-tuning:
    @echo "Applying recommended sysctl settings for Cassandra..."
    sudo sysctl -w vm.max_map_count=1048575
    sudo sysctl -w vm.swappiness=0

# Installed as dependencies rather than inside each recipe, so that a run asking
# for more than one - "just config smoke" - installs once.
[private]
lint-deps:
    poetry install --only lint,format --no-root

[private]
test-deps:
    poetry install --only unit --no-root

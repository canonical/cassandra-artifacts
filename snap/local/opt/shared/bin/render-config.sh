#!/usr/bin/env bash

# Maps the snap options onto ${CASSANDRA_CONF}/cassandra.yaml.
#
# Configuration can be set in two ways: through "snap set cassandra <key>=<value>",
# and by editing cassandra.yaml directly. A value edited by hand always takes
# precedence over the matching snap option.
#
# A hand edited value is recognised by comparing what cassandra.yaml currently
# holds against what it is expected to hold if nobody touched it: the value
# rendered by the previous run, recorded in ${RENDERED_STATE_FILE}, falling back
# to the default shipped in ${DEFAULT_CONF_FILE} for a key never rendered before.

source "${SNAP}"/opt/shared/bin/set-conf.sh

CONF_FILE="${CASSANDRA_CONF}/cassandra.yaml"
DEFAULT_CONF_FILE="${SNAP}/etc/cassandra/cassandra.yaml"
RENDERED_STATE_FILE="${SNAP_COMMON}/ops/rendered-config.yaml"
LOG_FILE="${SNAP_COMMON}/ops/snap/logs/hook-configure.log"

# Snap option -> cassandra.yaml key path. snap options can not contain underscore.
declare -A CONFIG_OPTIONS=(
    [broadcast-address]="broadcast_address"
    [broadcast-rpc-address]="broadcast_rpc_address"
    [cluster-name]="cluster_name"
    [endpoint-snitch]="endpoint_snitch"
    [listen-address]="listen_address"
    [num-tokens]="num_tokens"
    [rpc-address]="rpc_address"
    [seeds]="seed_provider/[0]/parameters/[0]/seeds"
)


# Write to the log as well as to stdout: stdout only survives when the hook
# fails, and the log is what the user can still read afterwards.
function report () {
    local message="${1}"
    local log_dir
    log_dir="$(dirname "${LOG_FILE}")"

    [ -d "${log_dir}" ] || mkdir -p "${log_dir}"

    echo "${message}"
    echo "$(date '+%F %T') ${message}" >> "${LOG_FILE}"
}

# The key path as cassandra.yaml spells it. Internally paths are traversed with
# "/" so that a key may contain ".", which is not how anyone reading the file
# would write it.
function key_label () {
    echo "${1}" | sed -e 's@/\[@[@g' -e 's@/@.@g'
}

function supported_options () {
    printf '%s\n' "${!CONFIG_OPTIONS[@]}" | sort
}

# Which of the given option names are currently set.
#
# snapctl offers a hook no way to list the options it holds: "snapctl get -d"
# needs at least one key - given none it fails with "get which option?" - and
# there is no listing flag. Every name to be looked for therefore has to be
# passed in. What comes back is a document holding only the ones that are set.
#
# The assignment is deliberately a statement of its own: a failure of snapctl
# aborts the hook there, rather than being read as "nothing is set", which would
# silently apply no configuration at all.
function set_options () {
    local config

    config="$(snapctl get -d "${@}")"

    echo "${config}" | "${SNAP}"/bin/yq -p json 'keys | .[]'
}

# The options this snap maps that are currently set.
function assigned_options () {
    set_options "${!CONFIG_OPTIONS[@]}"
}

# Option names that would name a cassandra.yaml key: every top level key the
# shipped file holds, plus the ones it ships commented out, spelled the way a
# snap option would be. Since an option can only be read by naming it, this is
# the list an unsupported option is looked for under - which is what makes
# "snap set cassandra storage-port=7100" answerable. A name matching no key in
# cassandra.yaml, on the other hand, cannot be seen by this hook at all.
function candidate_options () {
    {
        "${SNAP}"/bin/yq 'keys | .[]' "${DEFAULT_CONF_FILE}"
        sed -n 's/^# \([a-z0-9_]\+\): .*/\1/p' "${DEFAULT_CONF_FILE}"
    } | tr '_' '-' | sort -u
}

function ensure_state_file () {
    local state_dir
    state_dir="$(dirname "${RENDERED_STATE_FILE}")"

    [ -d "${state_dir}" ] || mkdir -p "${state_dir}"
    [ -f "${RENDERED_STATE_FILE}" ] || : > "${RENDERED_STATE_FILE}"
}

# Fails the hook, and with it the "snap set" that triggered it, when asked for a
# cassandra.yaml key this snap does not map. Everything the mapping leaves out
# stays settable by editing cassandra.yaml, which is what the refusal says.
function reject_unsupported_options () {
    local option
    local -a candidates=()
    local -a unsupported=()

    while read -r option; do
        if [ -z "${CONFIG_OPTIONS[${option}]+isset}" ]; then
            candidates+=("${option}")
        fi
    done < <(candidate_options)

    while read -r option; do
        [ -n "${option}" ] || continue
        unsupported+=("${option}")
    done < <(set_options "${candidates[@]}")

    if [ ${#unsupported[@]} -gt 0 ]; then
        report "option(s) that cannot be applied: ${unsupported[*]}"
        report "set the matching key in ${CONF_FILE} instead"
        report "options settable through 'snap set':"
        while read -r option; do
            report "  ${option}"
        done < <(supported_options)
        return 1
    fi
}

# What cassandra.yaml holds as long as nobody edited the key by hand.
function unmodified_value () {
    local option="${1}"
    local key="${2}"
    local rendered

    rendered="$(get_yaml_prop "${RENDERED_STATE_FILE}" "${option}")"

    if [ "${rendered}" != "null" ]; then
        echo "${rendered}"
    else
        get_yaml_prop "${DEFAULT_CONF_FILE}" "${key}"
    fi
}

function is_hand_edited () {
    local option="${1}"
    local key="${2}"

    [ "$(get_yaml_prop "${CONF_FILE}" "${key}")" \
        != "$(unmodified_value "${option}" "${key}")" ]
}

# Refuses a "snap set" that cannot reach cassandra.yaml because the key is owned
# by hand. Failing is the only way to say so: on success snapd discards whatever
# the hook printed. It also makes snapd roll the option back, which is what
# keeps the conflict from lingering and failing a later refresh.
#
# Runs before anything is written, so a rejected "snap set" leaves both
# cassandra.yaml and the recorded state untouched.
function reject_blocked_options () {
    local option
    local key
    local value
    local message
    local -a blocked=()

    while read -r option; do
        [ -n "${option}" ] || continue

        key="${CONFIG_OPTIONS[${option}]}"
        value="$(snapctl get "${option}")"

        # Only an option asking for something new is worth refusing. One that
        # already holds the value last rendered is not a change, and this hook
        # also runs on install and refresh, where there is nobody to tell.
        if is_hand_edited "${option}" "${key}" \
            && [ "${value}" != "$(get_yaml_prop "${RENDERED_STATE_FILE}" "${option}")" ]; then
            blocked+=("cannot apply the '${option}' option: $(key_label "${key}") is set to '$(get_yaml_prop "${CONF_FILE}" "${key}")' in cassandra.yaml")
        fi
    done < <(assigned_options)

    if [ ${#blocked[@]} -gt 0 ]; then
        for message in "${blocked[@]}"; do
            report "${message}"
        done
        report "a value edited by hand takes precedence; to hand the key back to 'snap set', remove that edit from ${CONF_FILE}"
        return 1
    fi
}

function render_option () {
    local option="${1}"
    local value="${2}"
    local key="${CONFIG_OPTIONS[${option}]}"
    local current

    current="$(get_yaml_prop "${CONF_FILE}" "${key}")"

    # Anything still blocked here already holds the value that was rendered for
    # it, so there is no change being asked for - reject_blocked_options has
    # turned the rest away already.
    if is_hand_edited "${option}" "${key}"; then
        report "$(key_label "${key}") is set to '${current}' in cassandra.yaml, ignoring the '${option}' option"
        return
    fi

    if [ "${current}" != "${value}" ]; then
        report "setting $(key_label "${key}") to '${value}'"
        set_yaml_prop "${CONF_FILE}" "${key}" "${value}"
        RESTART_REQUIRED="yes"
    fi

    # recorded as parsed back from cassandra.yaml, so that the next run compares
    # canonical values on both sides
    set_yaml_prop "${RENDERED_STATE_FILE}" "${option}" "$(get_yaml_prop "${CONF_FILE}" "${key}")"
}

# Puts the default back once an option is unset, unless the value was edited by
# hand in the meantime.
function revert_option () {
    local option="${1}"
    local key="${CONFIG_OPTIONS[${option}]}"
    local rendered
    local current
    local default

    rendered="$(get_yaml_prop "${RENDERED_STATE_FILE}" "${option}")"
    if [ "${rendered}" == "null" ]; then
        return
    fi

    current="$(get_yaml_prop "${CONF_FILE}" "${key}")"
    if [ "${current}" == "${rendered}" ]; then
        default="$(get_yaml_prop "${DEFAULT_CONF_FILE}" "${key}")"

        report "'${option}' is unset, restoring $(key_label "${key}") to '${default}'"
        if [ "${default}" == "null" ]; then
            remove_yaml_prop "${CONF_FILE}" "${key}"
        else
            set_yaml_prop "${CONF_FILE}" "${key}" "${default}"
        fi
        RESTART_REQUIRED="yes"
    fi

    remove_yaml_prop "${RENDERED_STATE_FILE}" "${option}"
}

function render_config () {
    local option
    local value

    RESTART_REQUIRED="no"

    for option in $(supported_options); do
        if value="$(snapctl get "${option}" 2>/dev/null)" && [ -n "${value}" ]; then
            render_option "${option}" "${value}"
        else
            revert_option "${option}"
        fi
    done

    # Cassandra reads cassandra.yaml once, at startup
    if [ "${RESTART_REQUIRED}" == "yes" ]; then
        report "run 'snap restart cassandra.server' to apply the new configuration"
    fi
}

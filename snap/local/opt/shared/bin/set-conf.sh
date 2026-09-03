#!/usr/bin/env bash


function replace_in_file() {
    "${SNAP}"/usr/bin/setpriv \
        --reuid _daemon_ -- sed -i "s@${2}@${3}@" "${1}"
}

# Builds the yq expression addressing a key path. Traversal must be done through
# the "/" separator to allow for "." in key names, and "[n]" path elements are
# passed through untouched so that list entries can be addressed.
function yaml_key_expression() {
    local full_key_path="${1}"
    local expression=""
    local -a keys
    local key
    local prefix
    local suffix

    IFS='/' read -r -a keys <<< "${full_key_path}"

    for key in "${keys[@]}"
    do
        prefix=""
        suffix=""
        if [[ "${key}" != [* ]]; then
            prefix=".\""
            suffix="\""
        fi
        expression="${expression}${prefix}${key}${suffix}"
    done

    echo "${expression}"
}

# Prints the value held by a key path, or "null" when the key is absent.
function get_yaml_prop() {
    local target_file="${1}"
    local expression
    expression="$(yaml_key_expression "${2}")"

    "${SNAP}"/bin/yq "${expression}" "${target_file}"
}

function remove_yaml_prop() {
    local target_file="${1}"
    local expression
    expression="$(yaml_key_expression "${2}")"

    "${SNAP}"/bin/yq -i "del(${expression})" "${target_file}"
}


function set_yaml_prop() {
    local target_file="${1}"
    local full_key_path="${2}"
    local value="${3}"
    local append="${4:-"no"}"
    local split_array_content="${5:-"yes"}"

    operator="="

    # allow appending
    if [ "${append}" == "yes" ]; then
        operator="+="
    fi

    expression="$(yaml_key_expression "${full_key_path}")"

    # yq fails serializing values starting with or containing special characters so they must be wrapped in double quotes
    # so, wrap any non number
    if [[ "${value}" == [* ]]; then
        value=${value:1:-1}

        if [ "${split_array_content}" == "yes" ]; then
            IFS=',' read -r -a arr_elts <<< "${value}"

            value=""
            for key in "${arr_elts[@]}"
            do
                key=$(echo -e "${key}" | tr -d '[:space:]')
                if ! [[ ${key} =~ ^[0-9]+$ ]] && ! [[ ${key} =~ ^\".*\"$ ]]; then
                    key="\"${key}\""
                fi
                value="${value}${key},"
            done
            value="[${value:0:-1}]"
        else
            value="[${value}]"
        fi
    # booleans are left unquoted too, so that they keep their type once parsed
    elif ! [[ "${value}" =~ ^[0-9]+$ ]] && ! [[ "${value}" =~ ^(true|false)$ ]] \
        && ! [[ ${value} =~ ^\".*\"$ ]]; then
       value="\"${value}\""
    fi

    "${SNAP}"/bin/yq -i "${expression} ${operator} ${value}" "${target_file}"
}

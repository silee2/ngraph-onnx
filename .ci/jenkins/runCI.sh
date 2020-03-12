#!/bin/bash

# ******************************************************************************
# Copyright 2018-2020 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ******************************************************************************

HELP_MESSAGE="Usage: runCI.sh [ARGS] [--help]

Builds nGraph and runs nGraph-ONNX tests.

Arguments:
    --help                      - Displays this message.
    --cleanup                   - Removes docker container and files created during script execution, instead of running CI.
    --rebuild                   - Rebuilds nGraph and runs tox tests.
    --ngraph_branch=...         - Will use specified branch of nGraph.
                                  Default: master
    --ngraph_sha=...            - Checkout to specified nGraph commit.
                                  Default: none - latest commit of cloned branch used
    --backends=...              - Comma separated list (no whitespaces!) of nGraph backends to run CI on.
                                  Default: cpu,interpreter
"

NGRAPH_REPO_ADDRESS="https://github.com/NervanaSystems/ngraph.git"
NGRAPH_REPO_DIR_NAME="ngraph"

NGRAPH_ONNX_CI_DIR=".ci/jenkins"

DEFAULT_NGRAPH_REPO_BRANCH="master"
DEFAULT_NGRAPH_REPO_SHA=""

# "<OPERATING_SYSTEM>" will be replaced by particular OS during script execution
DOCKER_CONTAINER_NAME_PATTERN="ngraph-onnx_ci_reproduction_<OPERATING_SYSTEM>"
DOCKER_IMAGE_NAME_PATTERN="aibt/aibt/ngraph/<OPERATING_SYSTEM>/base"
DOCKER_BASE_IMAGE_TAG="ci"
DOCKER_EXEC_IMAGE_TAG="ci_run"
DOCKER_HOME="/home/${USER}"

DEFAULT_BACKENDS="cpu interpreter"
HTTP_PROXY="${http_proxy}"
HTTPS_PROXY="${https_proxy}"

function main() {
    # Main function

    # Load parameters defaults
    CLEANUP="false"
    REBUILD="false"
    NGRAPH_REPO_BRANCH="${DEFAULT_NGRAPH_REPO_BRANCH}"
    NGRAPH_REPO_SHA="${DEFAULT_NGRAPH_REPO_SHA}"
    BACKENDS="${DEFAULT_BACKENDS}"

    parse_arguments "${@}"

    WORKSPACE="$(pwd)/$( dirname "${BASH_SOURCE[0]}" )"
    cd "${WORKSPACE}"
    local repo_clone_location="${WORKSPACE%/.ci*}"

    if [ "${CLEANUP}" = "true" ]; then
        cleanup "${repo_clone_location}"
        return 0
    fi


    if ! check_ngraph_repo "${repo_clone_location}"; then
        git clone "${NGRAPH_REPO_ADDRESS}" --branch "${NGRAPH_REPO_BRANCH}" "${repo_clone_location}/${NGRAPH_REPO_DIR_NAME}"
    fi

    local cloned_repo_branch="$(ngraph_rev_parse "${repo_clone_location}" "--abbrev-ref")"
    if [[ "${cloned_repo_branch}"!="${NGRAPH_REPO_BRANCH}" ]]; then
        checkout_ngraph_repo "${repo_clone_location}" "${NGRAPH_REPO_BRANCH}"
    fi

    local cloned_repo_sha="$(ngraph_rev_parse "${repo_clone_location}")"
    if [ -z "${NGRAPH_REPO_SHA}" ]; then
        NGRAPH_REPO_SHA="${cloned_repo_sha}"
    fi

    if [[ "${NGRAPH_REPO_SHA}" != "${cloned_repo_sha}" ]]; then
        checkout_ngraph_repo "${repo_clone_location}" "${NGRAPH_REPO_SHA}"
    fi

    run_ci

    return 0
}

function parse_arguments {
    # Parses script arguments
    PATTERN='[-a-zA-Z0-9_]*='
    for i in "${@}"; do
        case $i in
            "--help")
                printf ${HELP_MESSAGE}
                exit 0
                ;;
            "--cleanup")
                CLEANUP="true"
                echo "[INFO] Performing cleanup."
                ;;
            "--rebuild")
                REBUILD="true"
                echo "[INFO] nGraph is going to be rebuilt."
                ;;
            "--ngraph_branch="*)
                NGRAPH_REPO_BRANCH="${i//${PATTERN}/}"
                ;;
            "--ngraph_sha="*)
                NGRAPH_REPO_SHA="${i//${PATTERN}/}"
                echo "[INFO] Using nGraph commit ${NGRAPH_REPO_SHA}"
                ;;
            "--backends="*)
                BACKENDS="${i//${PATTERN}/}"
                # Convert comma separated values into whitespace separated
                BACKENDS="${BACKENDS//,/ }"
                ;;
            *)
                echo "[ERROR] Unrecognized argument: ${i}"
                printf ${HELP_MESSAGE}
                exit -1
                ;;
        esac
    done

    echo "[INFO] Using nGraph branch ${NGRAPH_REPO_BRANCH}"
    echo "[INFO] Backends tested: ${BACKENDS}"

    return 0
}

function cleanup() {
    # Performs cleanup of artifacts and containers from previous runs.
    local repo_clone_location="${1}"
    local container_name_pattern="${DOCKER_CONTAINER_NAME_PATTERN/<OPERATING_SYSTEM>/*}"
    docker rm -f "$(docker ps -a --format="{{.ID}}" --filter="name=${container_name_pattern}")"
    rm -rf "${repo_clone_location}/${NGRAPH_REPO_DIR_NAME}"

    return 0
}


function check_ngraph_repo() {
    # Verifies if nGraph-ONNX repository is present
    local repo_clone_location="${1}"
    local ngraph_git="${repo_clone_location}/${NGRAPH_REPO_DIR_NAME}/.git"
    if [ -d "${ngraph_git}" ]; then
        # 0 - true
        return 0
    else
        # 0 - false
        return 1
    fi
}

function ngraph_rev_parse() {
    # Returns the result of git rev-parse on nGraph repository.
    local repo_clone_location="${1}"
    local rev_parse_args="${2}"
    local previous_dir="$(pwd)"
    local ngraph_dir="${repo_clone_location}/${NGRAPH_REPO_DIR_NAME}"
    cd "${ngraph_dir}"
    local result="$(git rev-parse ${rev_parse_args} HEAD)"
    cd "${previous_dir}"
    echo "${result}"

    return 0
}

function checkout_ngraph_repo() {
    # Switches nGraph repository to commit SHA
    local repo_clone_location="${1}"
    local rev="${2}"
    local previous_dir="$(pwd)"
    cd "${repo_clone_location}/${NGRAPH_REPO_DIR_NAME}"
    git checkout "${rev}"
    cd "${previous_dir}"

    return 0
}

function run_ci() {
    # Builds necessary Docker images and executes CI

    # Calculate necessary paths
    local ngraph_onnx_ci_dockerfiles_dir="${WORKSPACE}/dockerfiles"
    local ngraph_onnx_parrent_path="$(dirname ${WORKSPACE%/.ci*})"
    local container_ngraph_onnx_ci_path="${WORKSPACE#*$ngraph_onnx_parrent_path/}"

    for dockerfile in $(find ${ngraph_onnx_ci_dockerfiles_dir} -maxdepth 1 -name *.dockerfile -printf "%f"); do
        local operating_system="${dockerfile/.dockerfile/}"
        local docker_container_name="${DOCKER_CONTAINER_NAME_PATTERN/<OPERATING_SYSTEM>/$operating_system}"
        local docker_image_name="${DOCKER_IMAGE_NAME_PATTERN/<OPERATING_SYSTEM>/$operating_system}"
        # Rebuild container if REBUILD parameter used or if there's no container present
        if [[ "${REBUILD}" = "true" || -z "$(check_container_status "${docker_container_name}")" ]]; then
            docker rm -f "${docker_container_name}" >/dev/null 2>&1
            build_docker_image "${operating_system}" "${docker_image_name}"
            run_docker_container "${docker_image_name}" "${docker_container_name}" "${ngraph_onnx_parrent_path}"
            prepare_environment "${docker_container_name}" "${container_ngraph_onnx_ci_path}"
        elif [[ "$(check_container_status)"==*"Exited"* ]]; then
            docker start "${docker_container_name}"
        fi
        run_tox_tests "${docker_container_name}" "${container_ngraph_onnx_ci_path}"
    done

    return 0
}

function check_container_status() {
    # Returns status of container for container name given as parameter
    local docker_container_name="${1}"
    echo "$(docker ps -a --format="{{ .Status }}" --filter="name=${docker_container_name}")"

    return 0
}

function build_docker_image() {
    # Builds CI Docker image for operating system given as parameter
    local operating_system="${1}"
    local docker_image_name="${2}"
    local dockerfiles_dir="${WORKSPACE}/dockerfiles"
    local postprocess_dockerfile_subpath="postprocess/append_user.dockerfile"
    local previous_dir="$(pwd)"
    cd "${dockerfiles_dir}"
    # build base image
    docker build \
        --build-arg http_proxy="${HTTP_PROXY}" \
        --build-arg https_proxy="${HTTPS_PROXY}" \
        -f "./${operating_system}.dockerfile" \
        -t "${docker_image_name}:${DOCKER_BASE_IMAGE_TAG}" .
    # build image with appended user
    docker build \
        --build-arg base_image="${docker_image_name}:${DOCKER_BASE_IMAGE_TAG}" \
        --build-arg UID="$(id -u)" \
        --build-arg GID="$(id -g)" \
        --build-arg USERNAME="${USER}" \
        -f "${dockerfiles_dir}/${postprocess_dockerfile_subpath}" \
        -t "${docker_image_name}:${DOCKER_EXEC_IMAGE_TAG}" .
    cd "${previous_dir}"

    return 0
}

function run_docker_container() {
    # Runs Docker container using image specified as parameter
    local docker_image_name="${1}"
    local docker_container_name="${2}"
    local ngraph_onnx_parrent_path="${3}"
    docker run -td \
                --privileged \
                --user "${USER}" \
                --name "${docker_container_name}"  \
                --volume "${ngraph_onnx_parrent_path}:${DOCKER_HOME}" \
                ${docker_image_name}:${DOCKER_EXEC_IMAGE_TAG}

    return 0
}

function prepare_environment() {
    # Prepares environment - builds nGraph
    local docker_container_name="${1}"
    local container_ngraph_onnx_ci_path="${2}"
    local container_ci_path_absolute="${DOCKER_HOME}/${container_ngraph_onnx_ci_path}"
    local container_ngraph_onnx_dir="${DOCKER_HOME}/${container_ngraph_onnx_ci_path%/.ci*}"
    docker exec ${docker_container_name} bash -c "${container_ci_path_absolute}/prepare_environment.sh \
                                                    --build-dir=${container_ngraph_onnx_dir} \
                                                    --backends=${BACKENDS// /,}"

    return 0
}

function run_tox_tests() {
    # Executes tox tests for every backend
    local docker_container_name="${1}"
    local container_ngraph_onnx_ci_path="${2}"
    for backend in ${BACKENDS}; do
        run_backend_test "${docker_container_name}" "${container_ngraph_onnx_ci_path}" "${backend}"
    done

    return 0
}

function run_backend_test() {
    # Executes single set of tox tests for backend given as parameter
    local docker_container_name="${1}"
    local container_ngraph_onnx_ci_path="${2}"
    local backend="${3}"
    local ngraph_onnx_dir="${DOCKER_HOME}/${container_ngraph_onnx_ci_path%/.ci*}"
    local backend_env="NGRAPH_BACKEND=$(printf '%s\n' "${backend}" | awk '{ print toupper($0) }')"
    local ngraph_whl=$(docker exec ${docker_container_name} find ${ngraph_onnx_dir}/ngraph/python/dist/ -name 'ngraph*.whl')
    local tox_env="TOX_INSTALL_NGRAPH_FROM=${ngraph_whl}"
    docker exec -e "${tox_env}" -e "${backend_env}" -w "${ngraph_onnx_dir}" ${docker_container_name} tox -c .

    return 0
}

main "${@}"

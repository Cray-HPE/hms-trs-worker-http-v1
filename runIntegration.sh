#!/bin/bash

# MIT License
#
# (C) Copyright [2021] Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

set -x

# Mac's don't have md5sum, they have md5...
md5_exe=$(command -v md5sum)
if ! [[ -x "$md5_exe" ]]; then
    md5_exe=$(command -v md5)
    if ! [[ -x "$md5_exe" ]]; then
        echo "Unable to find usable MD5 exe!"
        exit 1
    fi
fi

RANDY=$(echo $RANDOM | ${md5_exe} | awk '{print $1}')
CURWD=$(pwd)
REPO_DIR=$CURWD/repos
REPOS=(
    hms-trs-app-api
)

CURBRANCH=$(git branch | grep \* | cut -d ' ' -f2)
CURCOMMIT=$(git rev-parse --verify HEAD)

BRANCH_HIERARCHY=(
    ${CURBRANCH}
    develop
    master
)

# Check if we are building a PR in jenkins
echo $CURBRANCH | grep -E "^PR-[0-9]+"
if [[ $? -eq 0 ]]; then
    BRANCHES_AT_HEAD=$(git ls-remote --heads origin | grep $CURCOMMIT | awk '{print $2}')
    echo "Branches at head commit: $BRANCHES_AT_HEAD"

    # Remove non-feature branches
    BRANCHES_AT_HEAD=$(echo "${BRANCHES_AT_HEAD}" | grep -v "master")
    BRANCHES_AT_HEAD=$(echo "${BRANCHES_AT_HEAD}" | grep -v "develop")

    while IFS= read -r branch; do
        # Extract the branch name by removing 'refs/heads/' from the beginning of the line
        branch=$(echo $branch | cut -c 12- )
        echo "Adding branch $branch to branch hierarchy"
        BRANCH_HIERARCHY=($branch ${BRANCH_HIERARCHY[@]})
    done <<< "$BRANCHES_AT_HEAD"
fi

echo "Branch Hierarchy: ${BRANCH_HIERARCHY[@]}"

# Parse command line arguments
function usage() {
    echo "$FUNCNAME: $0 [-h] [-k]";
    echo "-k: Keep repo directory after integration test cleanup"
    exit 0
}

KEEP_REPO_DIR=false
NO_CLEAN=false

while getopts "hkd" opt; do
    case $opt in
        h) usage;;
        k) KEEP_REPO_DIR=true;;
        d) NO_CLEAN=true;;
        *) usage;;
    esac
done

# Configure docker compose
export COMPOSE_PROJECT_NAME=$RANDY
export COMPOSE_FILE=docker-compose.testing.yml

echo "RANDY: ${RANDY}"
echo "Current directory: $CURWD"
echo "Current branch: $CURBRANCH"
echo "Compose project name: $COMPOSE_PROJECT_NAME"
echo "Keep repo dirirectory after cleanup: $KEEP_REPO_DIR"
echo "Skip Cleanup: $NO_CLEAN"

function cleanup {
    if [[ ${NO_CLEAN} == false ]]; then
        ${docker_compose_exe} down
        if ! [[ $? -eq 0 ]]; then
            echo "Failed to decompose environment!"
            exit 1
        fi

        if [[ ${KEEP_REPO_DIR} == false ]]; then
            echo "Cleaning up temporary repo dir..."
            rm -rf ${REPO_DIR}
            if ! [[ $? -eq 0 ]]; then
                echo "Failed to remove repo dir!"
                exit 1
            fi
        fi
    fi
    exit $1
}

# It's possible we don't have docker-compose, so if necessary bring our own.
docker_compose_exe=$(command -v docker-compose)
if ! [[ -x "$docker_compose_exe" ]]; then
    if ! [[ -x "./docker-compose" ]]; then
        echo "Getting docker-compose..."
        curl -L "https://github.com/docker/compose/releases/download/1.23.2/docker-compose-$(uname -s)-$(uname -m)" \
        -o ./docker-compose

        if [[ $? -ne 0 ]]; then
            echo "Failed to fetch docker-compose!"
            exit 1
        fi

        chmod +x docker-compose
    fi
    docker_compose_exe="./docker-compose"
fi

# Step 1) Get source code of the base containers
echo "Checking out all repos"
for repo in ${REPOS[@]}; do
    echo "Cloning $repo into $REPO_DIR/$repo"
    git clone --depth 1 --no-single-branch https://github.com/Cray-HPE/"$repo".git "${REPO_DIR}"/"${repo}"

done

echo "trying to checkout feature branch"
for repo in ${REPOS[@]} ; do
    echo "cd into $REPO_DIR/$repo"
    cd $REPO_DIR/$repo
    echo $(pwd)

    # Step 2) make sure on the right branch
    for x in ${BRANCH_HIERARCHY[@]} ; do
        echo "attempting to checkout branch ${x}"
        git checkout ${x}
        if [ $? -eq 0 ]
        then
            echo "successfully checked out branch ${x}"
            break
        else
            echo "could not find branch ${x}..." >&2
            if [ "${x}" == "master" ]; then
                echo "all out of options... exiting"
                exit 1
            fi
        fi
    done
done

# Go back to this repos directory
cd $CURWD

# Step 3) Get the base containers running
echo "Starting containers..."
${docker_compose_exe} pull \
    && ${docker_compose_exe} build \
    && ${docker_compose_exe} up -d zookeeper kafka \
    && ${docker_compose_exe} up -d worker
if [[ $? -ne 0 ]]; then
    echo "Failed to setup environment!"
    cleanup 1
fi

# Step 4) Start the integration test container.
${docker_compose_exe} up --exit-code-from integration integration


if [[ $? -ne 0 ]]; then
    echo "Integration tests FAILED!"
    cleanup 1
fi

echo "Integration tests PASSED!"
cleanup 0

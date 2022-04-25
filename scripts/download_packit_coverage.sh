#!/bin/bash

##############################################
# initial configuration, adjust when necessary
##############################################

# maximum duration of the task in seconds
MAX_DURATION="${MAX_DURATION:-5400}"  # 90 minutes

# delay in seconds before doing another URL read
# should not be too short not to exceed GitHub API quota
SLEEP_DELAY="${SLEEP_DELAY:-120}"

# github user/project we are going to work with
#PROJECT="keylime/keylime"
PROJECT="keylimecov/keylime"

# TF_JOB_DESC points to a Testing farm job that does code coverage measurement and 
# uploads coverage XML files to a web drive
# currently we are doing that in a job running tests on Fedora-35
TF_JOB_DESC="testing-farm:fedora-35-x86_64"

# TF_TEST_OUTPUT points to a file with test output containing URLs to a web drive
# we are going to parse the output to get those URL and download coverage XML files
TF_TEST_OUTPUT="/setup/generate_coverage_report/output.txt"

# TF_ARTIFACTS_URL is URL prefix of Testing farm test artifacts
TF_ARTIFACTS_URL="https://artifacts.dev.testing-farm.io/"

# WEBDRIVE_URL points to a web page that stores coverage XML files
WEBDRIVE_URL="https://transfer.sh/"

##################################
# no need to change anything below
##################################

if [ -z "$GITHUB_SHA" -a -z "$1" ]; then
  echo "Commit SHA is required as an argument or in GITHUB_SHA environment variable"
  exit 1
fi

# COMMIT is necessary so we can access the GITHUB API URL to read check runs status
COMMIT=$GITHUB_SHA
[ -n "$1" ] && COMMIT="$1"

# build GITHUB_API_PR_URLs
GITHUB_API_PREFIX_URL="https://api.github.com/repos/${PROJECT}"
GITHUB_API_COMMIT_URL="${GITHUB_API_PREFIX_URL}/commits"

# meassure approx. task duration
DURATION=0

TMPFILE=$( mktemp )

######################################
# now start with the actual processing
######################################

# First we need to get the actual HEAD commit from PR.
# On GitHub commit always changes when doing rebase and merge
# and therefore commit differs between the PR branch and master branch
# Here we try to find the commit from PR branch since this is the commit
# for which tests have been run.

GITHUB_API_PR_URL="${GITHUB_API_COMMIT_URL}/${COMMIT}/pulls"
PR_COMMIT=''
while [ -z "${PR_COMMIT}" -a ${DURATION} -lt ${MAX_DURATION} ]; do
    curl -s -H "Accept: application/vnd.github.v3+json" "${GITHUB_API_PR_URL}" &> ${TMPFILE}
    PR_COMMIT=$( cat ${TMPFILE} | grep '"sha"' | head -1 | cut -d '"' -f 4 )
    # if we have failed to parse PR_COMMIT, wait a bit and try again
    if [ -z "${PR_COMMIT}" ]; then
        echo "Failed to parse PR commit from ${GITHUB_API_PR_URL}, waiting ${SLEEP_DELAY} seconds..."
        sleep $SLEEP_DELAY
        DURATION=$(( $DURATION+$SLEEP_DELAY ))
    fi
done

if [ -z "${PR_COMMIT}" ]; then
  echo "Cannot get PR commit from ${GITHUB_API_PR_URL}"
  exit 2
fi

echo "PR_COMMIT=${PR_COMMIT}"

# now if PR_COMMIT and COMMIT differs, it means we are processing merge to master branch
# in this case we can use PR code coverage only if the parent and base commit are equal,
# i.e. there were no other commits added to master branch in the meantime

if [ "${PR_COMMIT}" != "${COMMIT}" ]; then

    echo "Provided commit ${COMMIT} differs from PR commit ${PR_COMMIT}"
    echo "Need to verify that parent commit matches PR base commit"

    GITHUB_API_PR_URL="${GITHUB_API_COMMIT_URL}/${PR_COMMIT}/pulls"
    # we need to get parent commit from the master branch
    curl -s -H "Accept: application/vnd.github.v3+json" "${GITHUB_API_COMMIT_URL}/${COMMIT}" &> ${TMPFILE}
    PARENT_COMMIT=$( cat ${TMPFILE} | grep -A 5 '"parents"' | grep '"sha"' | cut -d '"' -f 4 )

    if [ -z "${PARENT_COMMIT}" ]; then
        echo "Unable to get parent commit for ${COMMIT} from ${GITHUB_API_COMMIT_URL}/${COMMIT}"
        exit 10
    fi

    # and also base commit from PR
    curl -s -H "Accept: application/vnd.github.v3+json" "${GITHUB_API_PR_URL}" &> ${TMPFILE}
    BASE_COMMIT=$( cat ${TMPFILE} | grep -A 5 '"base"' | grep '"sha"' | cut -d '"' -f 4 )

    if [ -z "${BASE_COMMIT}" ]; then
        echo "Unable to get base commit for ${PR_COMMIT} from ${GITHUB_API_PR_URL}"
        exit 10
    fi

    # not check if these commits are the same
    if [ "${PARENT_COMMIT}" != "${BASE_COMMIT}" ]; then
        echo "Parent commit ${PARENT_COMMIT} differs from PR base commit ${BASE_COMMIT}"
        echo "Code coverage data cannot be used"
        exit 20
    else
        echo "Parent commit ${PARENT_COMMIT} matches PR base commit ${BASE_COMMIT}"
    fi

fi

# build GITHUB_API_RUNS_URL using the COMMIT
GITHUB_API_RUNS_URL="https://api.github.com/repos/${PROJECT}/commits/${PR_COMMIT}/check-runs"
echo "GITHUB_API_RUNS_URL=${GITHUB_API_RUNS_URL}"

# Now we try to parse URL of Testing farm job from GITHUB_API_RUNS_URL page
TF_BASEURL=''
while [ -z "${TF_BASEURL}" -a ${DURATION} -lt ${MAX_DURATION} ]; do
    curl -s -H "Accept: application/vnd.github.v3+json" "${GITHUB_API_RUNS_URL}" &> ${TMPFILE}
    TF_BASEURL=$( cat ${TMPFILE} | sed -n "/${TF_JOB_DESC}/, /\"id\"/ p" | egrep -o "${TF_ARTIFACTS_URL}[^ ]*" )
    # if we have failed to parse URL, wait a bit and try again
    if [ -z "${TF_BASEURL}" ]; then
        echo "Failed to parse Testing Farm job ${TF_JOB_DESC} URL from ${GITHUB_API_RUNS_URL}, waiting ${SLEEP_DELAY} seconds..."
        sleep $SLEEP_DELAY
        DURATION=$(( $DURATION+$SLEEP_DELAY ))
    fi
done

if [ -z "${TF_BASEURL}" ]; then
  echo "Cannot parse artifacts URL for ${TF_JOB_DESC} from ${GITHUB_API_RUNS_URL}"
  exit 3
fi

echo "TF_BASEURL=${TF_BASEURL}"

# now we wait for the Testing farm job to finish
TF_STATUS=''
while [ "${TF_STATUS}" != "completed" -a ${DURATION} -lt ${MAX_DURATION} ]; do
    # parse Testing Farm job status
    curl -s -H "Accept: application/vnd.github.v3+json" ${GITHUB_API_RUNS_URL} | sed -n "/${TF_JOB_DESC}/, /\"id\"/ p" &> ${TMPFILE}
    TF_STATUS=$( cat ${TMPFILE} | grep '"status"' | cut -d '"' -f 4 )
    # if status is not "completed" wait a bit and try again
    if [ "${TF_STATUS}" != "completed" ]; then
        echo "Testing Farm job status: ${TF_STATUS}, waiting ${SLEEP_DELAY} seconds..."
        sleep ${SLEEP_DELAY}
        DURATION=$(( $DURATION+$SLEEP_DELAY ))
    fi
done

if [ "${TF_STATUS}" != "completed" ]; then
  echo "Testing farm job ${TF_JOB_DESC} didn't complete within $MAX_DURATION seconds ${GITHUB_API_RUNS_URL}"
  exit 4
fi

echo "TF_STATUS=${TF_STATUS}"

# check test results - we won't proceed if test failed since coverage data may be incomplete,
# see https://docs.codecov.com/docs/comparing-commits#commits-with-failed-ci
TF_RESULT=$( cat ${TMPFILE} | grep '"conclusion"' | cut -d '"' -f 4 )
echo TF_RESULT=${TF_RESULT}

if [ "${TF_RESULT}" != "success" ]; then
    echo "Testing Farm tests failed, we won't be uploading coverage data since they may be incomplete"
    return 30
fi

# wait a bit since there could be some timing issue
sleep 10

# now we read the test log
TF_TESTLOG=$( curl -s ${TF_BASEURL}/results.xml | egrep -o "${TF_ARTIFACTS_URL}.*${TF_TEST_OUTPUT}" )
echo "TF_TESTLOG=${TF_TESTLOG}"

# parse the URL of coverage XML file on WEBDRIVE_URL and download it
for REPORT in coverage.packit.xml coverage.testsuite.xml coverage.unittests.xml; do
    COVERAGE_URL=$( curl -s "${TF_TESTLOG}" | grep "$REPORT report is available at" | grep -o "${WEBDRIVE_URL}.*\.xml" )
    echo "COVERAGE_URL=${COVERAGE_URL}"

    if [ -z "${COVERAGE_URL}" ]; then
        echo "Could not parse $REPORT URL at ${WEBDRIVE_URL} from test log ${TF_TESTLOG}"
        exit 5
    fi

    # download the file
    curl -O ${COVERAGE_URL}
done

rm ${TMPFILE}

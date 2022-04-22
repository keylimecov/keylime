#!/bin/bash

##############################################
# initial configuration, adjust when necessary
##############################################

# maximum duration of the task in seconds
MAX_DURATION=$(( 60*90 ))  # 90 minutes

# delay in seconds before doing another URL read
# should not be too short not to exceed GitHub API quota
SLEEP_DELAY=120

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

# build GITHUB_API_URL using the COMMIT
GITHUB_API_URL="https://api.github.com/repos/${PROJECT}/commits/${COMMIT}/check-runs"
echo "GITHUB_API_URL=${GITHUB_API_URL}"

# meassure approx. task duration
DURATION=0

TMPFILE=$( mktemp )

######################################
# now start with the actual processing
######################################


# First we try to parse URL of Testing farm job from GITHUB_API_URL page
TF_BASEURL=''
while [ -z "${TF_BASEURL}" -a ${DURATION} -lt ${MAX_DURATION} ]; do
    curl -s -H "Accept: application/vnd.github.v3+json" "${GITHUB_API_URL}" &> ${TMPFILE}
    TF_BASEURL=$( cat ${TMPFILE} | sed -n "/${TF_JOB_DESC}/, /\"id\"/ p" | egrep -o "${TF_ARTIFACTS_URL}[^ ]*" )
    # if we have failed to parse URL, wait a bit and try again
    if [ -z "${TF_BASEURL}" ]; then
        echo "Failed to parse Testing Farm job ${TF_JOB_DESC} URL from ${GITHUB_API_URL}, waiting ${SLEEP_DELAY} seconds..."
        sleep $SLEEP_DELAY
        DURATION=$(( $DURATION+$SLEEP_DELAY ))
    fi
done

if [ -z "${TF_BASEURL}" ]; then
  echo "Cannot parse artifacts URL for ${TF_JOB_DESC} from ${GITHUB_API_URL}"
  exit 2
fi

echo "TF_BASEURL=${TF_BASEURL}"

# now we wait for the Testing farm job to finish
TF_STATUS=''
while [ "${TF_STATUS}" != "completed" -a ${DURATION} -lt ${MAX_DURATION} ]; do
    # parse Testing Farm job status
    curl -s -H "Accept: application/vnd.github.v3+json" ${GITHUB_API_URL} | sed -n "/${TF_JOB_DESC}/, /\"id\"/ p" &> ${TMPFILE}
    TF_STATUS=$( cat ${TMPFILE} | grep '"status"' | cut -d '"' -f 4 )
    # if status is not "completed" wait a bit and try again
    if [ "${TF_STATUS}" != "completed" ]; then
        echo "Testing Farm job status: ${TF_STATUS}, waiting ${SLEEP_DELAY} seconds..."
        sleep ${SLEEP_DELAY}
        DURATION=$(( $DURATION+$SLEEP_DELAY ))
    fi
done

if [ "${TF_STATUS}" != "completed" ]; then
  echo "Testing farm job ${TF_JOB_DESC} didn't complete within $MAX_DURATION seconds ${GITHUB_API_URL}"
  exit 3
fi

echo "TF_STATUS=${TF_STATUS}"

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
        exit 4
    fi

    # download the file
    curl -O ${COVERAGE_URL}
done

rm ${TMPFILE}

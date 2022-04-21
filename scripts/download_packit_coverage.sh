#!/bin/bash

if [ -z "$GITHUB_SHA" -a -z "$1" ]; then
  echo "Commit SHA is required as an argument or in GITHUB_SHA environment variable"
  exit 1
fi

COMMIT=$GITHUB_SHA
[ -n "$1" ] && COMMIT="$1"
PROJECT="keylime/keylime"
PROJECT="keylimecov/keylime"
TF_JOB_DESC="testing-farm:fedora-35-x86_64"

# First we try to get URL of Testing farm job
DURATION=0
MAX_DURATION=600  # maximum action duration in seconds
SLEEP_DELAY=60
while [ -z "${TF_BASEURL}" -a ${DURATION} -lt ${MAX_DURATION} ]; do
    TF_BASEURL=$( curl -s -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/${PROJECT}/commits/${COMMIT}/check-runs | sed -n "/${TF_JOB_DESC}/"', /"id"/ p' | egrep -o 'https://artifacts.dev.testing-farm.io/[^ ]*' )
    DURATION=$(( $DURATION+$SLEEP_DELAY ))
    [ -z "${TF_BASEURL}" ] && sleep $SLEEP_DELAY
done

if [ -z "${TF_BASEURL}" ]; then
  echo "Cannot parse artifacts URL for ${TF_JOB_DESC} from https://api.github.com/repos/${PROJECT}/commits/${COMMIT}/check-runs"
  exit 2
fi

echo "TF_BASEURL=${TF_BASEURL}"

# now we wait for the Testing farm job to finish
DURATION=0
MAX_DURATION=$(( 60*90 ))
SLEEP_DELAY=60
while [ "${TF_STATUS}" != "completed" -a ${DURATION} -lt ${MAX_DURATION} ]; do
    TF_STATUS=$( curl -s -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/${PROJECT}/commits/${COMMIT}/check-runs | sed -n "/${TF_JOB_DESC}/"', /"id"/ p' | grep '"status":' | cut -d '"' -f 4 )
    DURATION=$(( $DURATION+$SLEEP_DELAY ))
    [ -z "${TF_STATUS}" ] && echo "Status: $TF_STATUS, waiting..." && sleep $SLEEP_DELAY
done

if [ "${TF_STATUS}" != "completed" ]; then
  echo "Testing farm job ${TF_JOB_DESC} didn't complete within $MAX_DURATION seconds https://api.github.com/repos/keylime/keylime/commits/${COMMIT}/check-runs"
  exit 3
fi

echo "TF_STATUS=${TF_STATUS}"

# now we read the test log
TF_TESTLOG=$( curl -s ${TF_BASEURL}/results.xml | egrep -o 'https://artifacts.dev.testing-farm.io/.*/data/setup/generate_coverage_report/output.txt' )

echo "TF_TESTLOG=${TF_TESTLOG}"

# parse the URL to transfer.sh with coverage.xml file
COVERAGE_URL=$( curl -s "${TF_TESTLOG}" | grep 'coverage.xml report is available at' | grep -o 'https://transfer.sh/.*/coverage.xml' )

if [ -z "${COVERAGE_URL}" ]; then
    echo "Could not parse coverage.xml URL at transfer.sh from test log ${TF_TESTLOG}"
    exit 4
fi

echo "COVERAGE_URL=${COVERAGE_URL}"

curl -O ${COVERAGE_URL}

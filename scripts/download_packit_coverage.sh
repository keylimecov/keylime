#!/bin/bash

##############################################
# initial configuration, adjust when necessary
##############################################

# maximum duration of the task in seconds
MAX_DURATION="${MAX_DURATION:-5400}"  # 90 minutes

# delay in seconds before doing another URL read
# should not be too short not to exceed GitHub API quota
SLEEP_DELAY="${SLEEP_DELAY:-120}"

# TF_JOB_DESC points to a Testing farm job that does code coverage measurement and 
# uploads coverage XML files to a web drive
# currently we are doing that in a job running tests on Fedora-35
TF_JOB_DESC="testing-farm:fedora-35-x86_64"

# TF_TEST_OUTPUT points to a file with test output containing URLs to a web drive
# we are going to parse the output to get those URL and download coverage XML files
TF_TEST_OUTPUT="/setup/generate_coverage_report/output.txt"

# TF_ARTIFACTS_URL is URL prefix of Testing farm test artifacts
TF_ARTIFACTS_URL="https://artifacts.dev.testing-farm.io"

# WEBDRIVE_URL points to a web page that stores coverage XML files
WEBDRIVE_URL="https://transfer.sh"

##################################
# no need to change anything below
##################################

# COMMIT is necessary so we can access the GITHUB API URL to read check runs status
if [ -z "$GITHUB_SHA" -a -z "$1" ]; then
  echo "Commit SHA is required as an argument or in GITHUB_SHA environment variable"
  exit 1
fi
COMMIT="${GITHUB_SHA}"
[ -n "$1" ] && COMMIT="$1"
echo "COMMIT=${COMMIT}"

# github project is also necessary so we can build API URL
if [ -z "${GITHUB_REPOSITORY}" -a -z "$2" ]; then
  echo "GitHub repository name USER/PROJECT is required as an argument or in GITHUB_REPOSITORY environment variable"
  exit 1
fi
PROJECT="${GITHUB_REPOSITORY}"
[ -n "$2" ] && PROJECT="$2"
echo "PROJECT=${PROJECT}"

# build GITHUB_API_URLs
GITHUB_API_PREFIX_URL="https://api.github.com/repos/${PROJECT}"
GITHUB_API_COMMIT_URL="${GITHUB_API_PREFIX_URL}/commits"

# meassure approx. task duration
DURATION=0

####################################
# some functions we are going to use
####################################

# run API call and parse the required value
# repeat until we get the value or exceed job duration
# URL - API URL
# JQ_REF - code for jq that will be used for JSON parsing
# ERROR_MSG - error message to print in case we fail to parse the value
# EXP_VALUE - expected value (used e.g. when waiting for job completion)
function do_GitHub_API_call() {
    local URL="$1"
    local JQ_REF="$2"
    local ERROR_MSG="$3"
    local EXP_VALUE="$4"
    local VALUE=''
    local TMPFILE=$( mktemp )

    while [ -z "${VALUE}" -o \( -n "${EXP_VALUE}" -a "${VALUE}" != "${EXP_VALUE}" \) ] && [ ${DURATION} -lt ${MAX_DURATION} ]; do
        curl -s -H "Accept: application/vnd.github.v3+json" "$URL" &> ${TMPFILE}
        VALUE=$( cat ${TMPFILE} | jq "${JQ_REF}" | sed 's/"//g' )
        if [ -z "${VALUE}" ] || [ -n "${EXP_VALUE}" -a "${VALUE}" != "${EXP_VALUE}" ]; then
            if [ -z "${ERROR_MSG}" ]; then
                echo "Warning: Failed to read data using GitHub API, trying again after ${SLEEP_DELAY} seconds" 1>&2
            else
                echo "$ERROR_MSG" 1>&2
            fi
            sleep ${SLEEP_DELAY}
            DURATION=$(( ${DURATION}+${SLEEP_DELAY} ))
        fi
    done

    if [ ${DURATION} -ge ${MAX_DURATION} ]; then
         echo "Error: Maximum job diration exceeded. Terminating" 1>&2
         exit 9
    fi

    rm ${TMPFILE}
    echo $VALUE
}

######################################
# now start with the actual processing
######################################

# build GITHUB_API_RUNS_URL using the COMMIT
GITHUB_API_RUNS_URL="${GITHUB_API_COMMIT_URL}/${COMMIT}/check-runs?check_name=${TF_JOB_DESC}"
echo "GITHUB_API_RUNS_URL=${GITHUB_API_RUNS_URL}"

# Now we try to parse URL of Testing farm job from GITHUB_API_RUNS_URL page
TF_BASEURL=$( do_GitHub_API_call "${GITHUB_API_RUNS_URL}" \
                                 ".check_runs[0] | .output.summary | match(\"${TF_ARTIFACTS_URL}/[^ ]*\") | .string" \
                                 "Failed to parse Testing Farm job ${TF_JOB_DESC} URL from ${GITHUB_API_RUNS_URL}, trying again after ${SLEEP_DELAY} seconds..." )
echo "TF_BASEURL=${TF_BASEURL}"

# now we wait for the Testing farm job to finish
TF_STATUS=$( do_GitHub_API_call "${GITHUB_API_RUNS_URL}" \
                                 '.check_runs[0] | .status' \
                                 "Testing Farm job ${TF_JOB_DESC} hasn't completed yet, trying again after ${SLEEP_DELAY} seconds..." \
                                 "completed" )
echo "TF_STATUS=${TF_STATUS}"
                                
# check test results - we won't proceed if test failed since coverage data may be incomplete,
# see https://docs.codecov.com/docs/comparing-commits#commits-with-failed-ci
TF_RESULT=$( do_GitHub_API_call "${GITHUB_API_RUNS_URL}" \
                                 '.check_runs[0] | .conclusion' \
                                 "Cannot get Testing Farm job ${TF_JOB_DESC} result, trying again after ${SLEEP_DELAY} seconds..." )
echo TF_RESULT=${TF_RESULT}

if [ "${TF_RESULT}" != "success" ]; then
    echo "Testing Farm tests failed, we won't be uploading coverage data since they may be incomplete"
    return 3
fi

# wait a bit since there could be some timing issue
sleep 10

# now we read the actual test log URL
TF_TESTLOG=$( curl -s ${TF_BASEURL}/results.xml | egrep -o "${TF_ARTIFACTS_URL}.*${TF_TEST_OUTPUT}" )
echo "TF_TESTLOG=${TF_TESTLOG}"

# parse the URL of coverage XML file on WEBDRIVE_URL and download it
TMPFILE=$( mktemp )
curl -s "${TF_TESTLOG}" &> ${TMPFILE}
for REPORT in coverage.packit.xml coverage.testsuite.xml coverage.unittests.xml; do
    COVERAGE_URL=$( grep "$REPORT report is available at" ${TMPFILE} | grep -o "${WEBDRIVE_URL}.*\.xml" )
    echo "COVERAGE_URL=${COVERAGE_URL}"

    if [ -z "${COVERAGE_URL}" ]; then
        echo "Could not parse $REPORT URL at ${WEBDRIVE_URL} from test log ${TF_TESTLOG}"
        exit 5
    fi

    # download the file
    curl -O ${COVERAGE_URL}
done
rm ${TMPFILE}

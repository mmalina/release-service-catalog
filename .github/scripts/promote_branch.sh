#!/usr/bin/env bash

# This script promotes branches in the release-service-catalog repository.
#
# The script promotes the development content into the staging branch, or the staging
# content into the production branch. It starts by performing the following checks, then
# it performs a git push. There is no pull request.
#
# Checks:
#   - If there is content in the staging branch that is not yet in the production branch, the
#     script will not git push to add more content to the staging branch. This can be overridden with
#     --force-to-staging true
#   - If promoting to production and the content has not been in the staging branch for at least 7 days,
#     the script will exit without doing a push. Content is expected to sit in staging for at least a week
#     to provide sufficient testing time. This can be overridden with --override true
#
# Prerequisities:
#   - An environment variable GITHUB_TOKEN is defined that provides access to the user's account. See
#     https://github.com/konflux-ci/release-service-utils/blob/main/ci/promote-overlay/README.md#setup for help.
#   - curl, git and jq installed.

set -e

# GitHub repository details
ORG="konflux-ci"
REPO="release-service-catalog"

print_help(){
    echo "Usage: $0 --branches branch1-to-branch2 [--force-to-staging false] [--override false] [--dry-run false]"
    echo
    echo "  --promotion-type:   The type of promotion to perform. Either development-to-staging"
    echo "                      or staging-to-production."
    echo "  --force-to-staging: If passed with value true, allow promotion to staging even"
    echo "                      if staging and production differ."
    echo "  --override:         If passed with value true, allow promotion to production"
    echo "                      even if the change has not been in staging for one week."
    echo "  --dry-run:          If passed with value true, print out the changes that would"
    echo "                      be promoted but do not git push or delete the temp repo."
    echo
    echo "  --promotion-type has to be specified."
}

OPTIONS=$(getopt --long "promotion-type:,force-to-staging:,override:,dry-run:,help" -o "p:,h" -- "$@")
eval set -- "$OPTIONS"
while true; do
    case "$1" in
        -p|--promotion-type)
            PROMOTION_TYPE="$2"
            shift 2
            ;;
        --force-to-staging)
            FORCE_TO_STAGING="$2"
            shift 2
            ;;
        --override)
            OVERRIDE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="$2"
            shift 2
            ;;
        -h|--help)
            print_help
            exit
            ;;
        --)
            shift
            break
            ;;
        *) echo "Error: Unexpected option: $1" % >2
    esac
done

check_if_branch_differs() {
    ACTUAL_DIFFERENT_LINES=$(git diff --numstat origin/$1 | wc -l)
    if [ $ACTUAL_DIFFERENT_LINES -ne 0 ] ; then
        echo "Lines differ in branch $1"
        echo "Actual differing lines: $(git diff --numstat origin/$1)"
        exit 1
    fi
}

check_if_any_commits_in_last_week() {
    NEW_COMMITS=$(git log --oneline --since="$(date --date="6 days ago" +%Y-%m-%d)" | wc -l)
    if [ $NEW_COMMITS -ne 0 ] ; then
        echo "There are commits in staging that are less than a week old. Blocking promotion to production"
        echo "Commits less than a week old: $(git log --oneline --since="$(date --date="6 days ago" +%Y-%m-%d)")"
        exit 1
    fi
}

if [ -z "${PROMOTION_TYPE}" ]; then
    echo -e "Error: missing '--promotion-type' argument\n"
    print_help
    exit 1
fi
if [ "${PROMOTION_TYPE}" == development-to-staging ]; then
    SOURCE_BRANCH=development
    TARGET_BRANCH=staging
elif [ "${PROMOTION_TYPE}" == staging-to-production ]; then
    SOURCE_BRANCH=staging
    TARGET_BRANCH=production
else
    echo "Invalid promotion type. Only 'development-to-staging' and 'staging-to-production' are allowed"
    print_help
    exit 1
fi
if [ -z "${GITHUB_TOKEN}" ]; then
    echo -e "Error: missing 'GITHUB_TOKEN' environment variable\n"
    print_help
    exit 1
fi
if [ -z "${GEMINI_API_KEY}" ]; then
    echo -e "Error: missing 'GEMINI_API_KEY' environment variable\n"
    print_help
    exit 1
fi


# Personal access token with appropriate permissions
token="${GITHUB_TOKEN}"

ORIGINAL_DIRECTORY=$(pwd)

# Use gdate on Mac
if [[ "$(uname)" == "Darwin" ]]; then
    date() {
        gdate "$@"
    }
fi

# Clone the repository
tmpDir=$(mktemp -d)
releaseServiceCatalogDir=${tmpDir}/release-service-catalog
mkdir -p ${releaseServiceCatalogDir}

echo -e "---\nPromoting release-service-catalog ${SOURCE_BRANCH} to ${TARGET_BRANCH}\n---\n"

git clone "https://oauth2:$GITHUB_TOKEN@github.com/$ORG/$REPO.git" ${releaseServiceCatalogDir}
cd ${releaseServiceCatalogDir}

# A change cannot go into production if the changes in staging are less than a week old
if [[ "${TARGET_BRANCH}" == "production" && "${OVERRIDE}" != "true" ]] ; then
    git checkout origin/staging
    check_if_any_commits_in_last_week
fi

# A change cannot go into staging if staging and production differ
if [[ "${TARGET_BRANCH}" == "staging" && "${FORCE_TO_STAGING}" != "true" ]] ; then
    git checkout origin/staging
    check_if_branch_differs production
fi

MESSAGES_FILE=$(mktemp)
COMMIT_LINKS_FILE=$(mktemp)
RESULT_FILE="${RESULT_FILE:-$ORIGINAL_DIRECTORY/summary_of_changes.html}"
GITHUB_REPO_URL="https://github.com/konflux-ci/release-service-catalog"

echo "Included commits:"
COMMITS=($(git rev-list --first-parent --ancestry-path origin/"$TARGET_BRANCH"'...'origin/"$SOURCE_BRANCH"))
## now loop through the above array
for COMMIT in "${COMMITS[@]}"
do
  LINE=$(git show --oneline --no-patch "$COMMIT")
  echo "$LINE"
  SHA=$(echo "$LINE" | awk '{print $1}')
  MESSAGE=$(echo "$LINE" | cut -d' ' -f2-)
  echo "<a href=\"$GITHUB_REPO_URL/commit/$SHA\">$SHA</a> $MESSAGE<br>" >> $COMMIT_LINKS_FILE
  git show --no-patch --pretty=format:%B $COMMIT >> $MESSAGES_FILE
  echo >> $MESSAGES_FILE
  echo --- >> $MESSAGES_FILE
done

echo Summary of changes:

curl "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$GEMINI_API_KEY" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d '{
    "contents": [
      {
        "parts": [
          {
            "text": "Provide a summary of changes made in the following commits (commit messages separated by `---`):\n\n'"$(cat $MESSAGES_FILE)"'\n\nThe summary should be concise and suitable for a newsletter sent out to users. It should be formatted in html (but no enclosing in ```html ``` please) and should not include any links or references to the commits themselves. The summary should be written in a friendly and engaging tone, suitable for a general audience.",
          }
        ]
      }
    ]
  }' | jq -r '.candidates[0].content.parts[0].text' > $RESULT_FILE

echo "<p>Changes promoted from <b>${SOURCE_BRANCH}</b> to <b>${TARGET_BRANCH}</b></p>" >> $RESULT_FILE
cat $COMMIT_LINKS_FILE >> $RESULT_FILE

echo Results written to $RESULT_FILE
cat $RESULT_FILE

if [ "${DRY_RUN}" == "true" ] ; then
    exit
fi

git checkout $SOURCE_BRANCH
git push origin $SOURCE_BRANCH:$TARGET_BRANCH

cd -
rm -rf ${tmpDir}

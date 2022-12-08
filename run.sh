#!/bin/sh

set -eux

QUEUED=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs?status=queued" | jq -cr '.workflow_runs[].id')
for WORKFLOW_ID in $QUEUED; do
  JOB_LABELS=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs/${WORKFLOW_ID}/jobs" | jq -cr '.jobs[].labels')
  echo "${JOB_LABELS}" | grep 'self-hosted' || continue
  INSTANCE_TYPE=$(echo "${JOB_LABELS}" | jq -cr '.[2]')
  TAG="${REPO}-${WORKFLOW_ID}"
  INSTANCES_STATUS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${TAG}" | jq -cr '.Reservations[].Instances[].State.Name')
  # just in case we somehow ended up with multiple machines with the same id
  if [ "${INSTANCES_STATUS}" != "" ] && [ $(echo "${INSTANCES_STATUS}" | grep -v terminated) ]; then
    echo 'already deployed'
    continue
  fi

  echo 'deploying'
  RUNNER_LABELS=$(echo "${JOB_LABELS}" | jq -cr 'join(",")')
  cat cloud-init.sh | sed -e "s#__REPO__#${REPO}#" -e "s/__RUNNER_LABELS__/${RUNNER_LABELS}/" -e "s/__GITHUB_TOKEN__/${GH_PAT}/" > .startup.sh
  # continue on error
  aws ec2 run-instances \
    --user-data file://.startup.sh \
    --block-device-mapping "[ { \"DeviceName\": \"/dev/sda1\", \"Ebs\": { \"VolumeSize\": 32, \"DeleteOnTermination\": true } } ]" \
    --ebs-optimized \
    --instance-initiated-shutdown-behavior terminate \
    --no-associate-public-ip-address \
    --instance-type "${INSTANCE_TYPE}" \
    --image-id "${IMAGE_ID}" \
    --key-name "${KEY_NAME}" \
    --subnet-id "${SUBNET_ID}" \
    --security-group-id "${SECURITY_GROUP_ID}" \
    --tag-specification "ResourceType=instance,Tags=[{Key=Name,Value=${TAG}}]" || continue
done

# cleanup if no jobs are in progress nor queued
RES=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${REPO}-*" "Name=instance-state-name,Values=running" | jq -cr '.Reservations[].Instances[] | [.InstanceId, .Tags[0].Value]')
for VAL in $RES; do
  ID=$(echo "${VAL}" | jq -cr '.[0]')
  TAG=$(echo "${VAL}" | jq -cr '.[1]')
  WORKFLOW_ID=$(echo "${TAG}" | awk -F '-' '{ print $NF }')
  JOB_STATUS=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs/${WORKFLOW_ID}" | jq -cr '.status')
  if [ "${JOB_STATUS}" != "queued" ] && [ "${JOB_STATUS}" != "in_progress" ]; then
    aws ec2 terminate-instances --instance-ids "$ID"
  fi
done

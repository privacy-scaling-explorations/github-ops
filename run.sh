#!/bin/sh

set -eux

QUEUED=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs?status=queued" | jq -cr '.workflow_runs[].id')
for WORKFLOW_ID in $QUEUED; do
  JOB_LABELS=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs/${WORKFLOW_ID}/jobs" | jq -cr '.jobs[].labels')
  echo "${JOB_LABELS}" | grep 'self-hosted' || continue
  INSTANCE_TYPE=$(echo "${JOB_LABELS}" | jq -cr '.[1]')
  TAG="${REPO}-${WORKFLOW_ID}"
  INSTANCES_STATUS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${TAG}" | jq -cr '.Reservations[].Instances[].State.Name')
  if [ "${INSTANCES_STATUS}" != "" ] && [ "${INSTANCES_STATUS}" != "terminated" ]; then
    echo 'already deployed'
    continue
  fi

  echo 'deploying'
  cat cloud-init.sh | sed -e "s#__REPO__#${REPO}#" -e "s/__RUNNER_LABEL__/${INSTANCE_TYPE}/" -e "s/__GITHUB_TOKEN__/${GH_PAT}/" > .startup.sh
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
RET=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs?status=in_progress" | jq -cr '.workflow_runs[].id')
if [ "${RET}" != "" ]; then
  exit
fi
RET=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs?status=queued" | jq -cr '.workflow_runs[].id')
if [ "${RET}" != "" ]; then
  exit
fi
INSTANCES=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${REPO}-*" | jq -cr '.Reservations[].Instances[].InstanceId')
if [ "${INSTANCES}" == "" ]; then
  exit
fi
aws ec2 terminate-instances --instance-ids $INSTANCES

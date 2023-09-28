#!/bin/sh

set -eux

EXIT_CODE=0
QUEUED=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs?status=queued" | jq -cr '.workflow_runs[].id')
for WORKFLOW_ID in $QUEUED; do
  JOBS=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs/${WORKFLOW_ID}/jobs" | jq -cr '.jobs')
  N_JOBS=$(echo "${JOBS}" | jq -cr '. | length')
  if [ "${N_JOBS}" = "0" ]; then
    continue
  fi

  for i in $(seq 1 "${N_JOBS}"); do
    JOB_DATA=$(echo "${JOBS}" | jq --arg i "${i}" -cr '.[$i | tonumber - 1]')
    JOB_LABELS=$(echo "${JOB_DATA}" | jq -cr '.labels')
    # skip if not self hosted
    echo "${JOB_LABELS}" | grep 'self-hosted' || continue

    JOB_ATTEMPTS=$(echo "${JOB_DATA}" | jq -cr '.run_attempt')
    INSTANCE_TYPE=$(echo "${JOB_LABELS}" | jq -cr '.[2]')
    JOB_ID=$(echo "${JOB_DATA}" | jq -cr '.id')
    TAG="${REPO}-${WORKFLOW_ID}-${JOB_ID}"
    RUNNER_LABELS=$(echo "${JOB_LABELS}" | jq -cr 'join(",")')

    RAND_SUBNET_ID=''
    if [ "${SUBNET_ID}" != "" ]; then
      SUBNETS_NUM=$(echo ${SUBNET_ID} | awk -F\s '{print NF -1}')
      RAND_SUBNET=$(shuf -i 1-${SUBNETS_NUM} -n 1)
      RAND_SUBNET_ID=$(echo ${SUBNET_ID} | awk -v rand_num=${RAND_SUBNET} -F' ' '{print $rand_num}')
    fi

    IS_SPOT=$(echo "${JOB_LABELS}" | grep -qv "spot"; echo "$?")
    if [ "${IS_SPOT}" = "1" ]; then
      INSTANCES_STATUS=$(aws ec2 describe-spot-instance-requests --filters "Name=tag:Name,Values=${TAG}" | jq -cr '.SpotInstanceRequests[].State')
      # just in case we somehow ended up with multiple machines with the same id
      if [ "${INSTANCES_STATUS}" != "" ] && [ "$(echo "${INSTANCES_STATUS}" | grep -q -E '(open|active)'; echo "$?")" = "0" ]; then
        echo 'already deployed'
        continue
      fi

      USER_DATA=$(cat cloud-init.sh | sed -e "s#__REPO__#${REPO}#" -e "s#__RUNNER_LABELS__#${RUNNER_LABELS}#" -e "s/__GITHUB_TOKEN__/${GH_PAT}/" | base64 -w 0)
      JSON=$(
cat | jq -cr '.' << EOF
{
  "UserData": "${USER_DATA}",
  "SecurityGroupIds": ["${SECURITY_GROUP_ID}"],
  "SubnetId": "${RAND_SUBNET_ID}",
  "ImageId": "${IMAGE_ID}",
  "InstanceType": "${INSTANCE_TYPE}",
  "KeyName": "${KEY_NAME}",
  "BlockDeviceMappings": [
    { "DeviceName": "/dev/sda1", "Ebs": { "VolumeSize": 64, "DeleteOnTermination": true } }
  ],
  "EbsOptimized": true
}
EOF
)

      # continue on error
      aws ec2 request-spot-instances \
        --type one-time \
        --instance-interruption-behavior terminate \
        --instance-count 1 \
        --tag-specification "ResourceType=spot-instances-request,Tags=[{Key=Name,Value=${TAG}}]" \
        --client-token "${TAG}-${JOB_ATTEMPTS}" \
        --launch-specification "${JSON}" || EXIT_CODE=1

    else
      INSTANCES_STATUS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${TAG}" | jq -cr '.Reservations[].Instances[].State.Name')
      # just in case we somehow ended up with multiple machines with the same id
      if [ "${INSTANCES_STATUS}" != "" ] && [ $(echo "${INSTANCES_STATUS}" | grep -v terminated) ]; then
        echo 'already deployed'
        continue
      fi

      # continue on error
      cat cloud-init.sh | sed -e "s#__REPO__#${REPO}#" -e "s#__RUNNER_LABELS__#${RUNNER_LABELS}#" -e "s/__GITHUB_TOKEN__/${GH_PAT}/" > .startup.sh
      aws ec2 run-instances \
        --user-data "file://.startup.sh" \
        --block-device-mapping "[ { \"DeviceName\": \"/dev/sda1\", \"Ebs\": { \"VolumeSize\": 64, \"DeleteOnTermination\": true } } ]" \
        --ebs-optimized \
        --instance-initiated-shutdown-behavior terminate \
        --instance-type "${INSTANCE_TYPE}" \
        --image-id "${IMAGE_ID}" \
        --key-name "${KEY_NAME}" \
        --subnet-id "${RAND_SUBNET_ID}" \
        --security-group-id "${SECURITY_GROUP_ID}" \
        --tag-specification "ResourceType=instance,Tags=[{Key=Name,Value=${TAG}}]" || EXIT_CODE=1
    fi
  done
done

# cleanup if no jobs are in progress nor queued
RES=$(aws ec2 describe-spot-instance-requests --filters "Name=tag:Name,Values=${REPO}-*" | jq -cr '.SpotInstanceRequests[] | [.InstanceId, .SpotInstanceRequestId, .Tags[0].Value, .State]')
for VAL in $RES; do
  INSTANCE_ID=$(echo "${VAL}" | jq -cr '.[0]')
  SPOT_ID=$(echo "${VAL}" | jq -cr '.[1]')
  TAG=$(echo "${VAL}" | jq -cr '.[2]')
  STATE=$(echo "${VAL}" | jq -cr '.[3]')
  JOB_ID=$(echo "${TAG}" | awk -F '-' '{ print $NF }')
  JOB_STATUS=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/jobs/${JOB_ID}" | jq -cr '.status')
  if [ "${JOB_STATUS}" != "queued" ] && [ "${JOB_STATUS}" != "in_progress" ]; then
    if [ "${STATE}" != "cancelled" ] && [ "${STATE}" != "closed" ]; then
      aws ec2 cancel-spot-instance-requests --spot-instance-request-ids "${SPOT_ID}" || EXIT_CODE=1
    fi
    if [ "${INSTANCE_ID}" != "null" ]; then
      aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" || EXIT_CODE=1
    fi
  fi
done

# cleanup for non-spot instances
RES=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${REPO}-*" "Name=instance-state-name,Values=running" | jq -cr '.Reservations[].Instances[] | [.InstanceId, .Tags[0].Value]')
for VAL in $RES; do
  ID=$(echo "${VAL}" | jq -cr '.[0]')
  TAG=$(echo "${VAL}" | jq -cr '.[1]')
  JOB_ID=$(echo "${TAG}" | awk -F '-' '{ print $NF }')
  JOB_STATUS=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/jobs/${JOB_ID}" | jq -cr '.status')
  if [ "${JOB_STATUS}" != "queued" ] && [ "${JOB_STATUS}" != "in_progress" ]; then
    aws ec2 terminate-instances --instance-ids "${ID}"
  fi
done

exit "${EXIT_CODE}"

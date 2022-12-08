#!/bin/sh

set -eux
trap 'poweroff' TERM EXIT INT

# github
REPO='__REPO__'
RUNNER_LABELS='__RUNNER_LABELS__'
GITHUB_TOKEN='__GITHUB_TOKEN__'

# idle poweroff script
cat >> /etc/crontab << 'EOF'
*/1 * * * * root cat /proc/uptime | awk -F ' ' '{ if ($1 < 300) exit 1 }' && (cat /proc/loadavg | awk -F ' ' '{ if ($1 <= .3 && $2 < .3 && $3 < .3) exit 1 }' || poweroff)
EOF

# basics
apt-get update
apt-get install -y curl jq git ca-certificates gnupg lsb-release

# docker
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
chmod a+r /etc/apt/keyrings/docker.gpg
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
usermod -a -G docker ubuntu

# github runner
cd /
rm -rf github
mkdir github
cd github
RUNNER_TOKEN=$(curl -s -X POST "https://api.github.com/repos/${REPO}/actions/runners/registration-token" -H "accept: application/vnd.github.everest-preview+json" -H "authorization: token ${GITHUB_TOKEN}" | jq -r '.token')
LATEST_VERSION_LABEL=$(curl -H "authorization: token ${GITHUB_TOKEN}" -s -X GET 'https://api.github.com/repos/actions/runner/releases/latest' | jq -r '.tag_name')
LATEST_VERSION=$(printf -- ${LATEST_VERSION_LABEL} | cut -c 2-)
RUNNER_FILE="actions-runner-linux-x64-${LATEST_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/${LATEST_VERSION_LABEL}/${RUNNER_FILE}"
curl -o runner.tar -L "${RUNNER_URL}"
mkdir runner
chown -R ubuntu runner
sudo -u ubuntu tar -xf runner.tar -C runner
rm runner.tar
cd ./runner
RUNNER_URL="https://github.com/${REPO}"
sudo -u ubuntu ./config.sh --ephemeral --unattended --disableupdate --replace --url "${RUNNER_URL}" --token "${RUNNER_TOKEN}" --labels "${RUNNER_LABELS}"
sudo -u ubuntu ./run.sh


This project manages ephemeral GitHub runners for specific repositories.
If you want to add a new repository, then copy and edit [this file](.github/workflows/zkevm-chain.yml).

To make sure this workflow gets executed as soon as possible you can copy and adapt [this workflow](github-ops.yml)
into the target repository. Normally, the workflow queue checks are scheduled each 5 minutes on this repository but that
behaviour is highly inconsistent. Hence, it's better to copy the `github-ops` workflow into the target repository instead.
This needs an additional github personal access token with the `public repo scope` only (classic github token).

Edit any workflows of the target repository and add this line to request a self hosted runner with the aws instance type of your liking.
Note: The first two parts must not be omitted, the third one can be choosen.
```
runs-on: ["${{github.run_id}}", self-hosted, r6a.48xlarge]
```

The [run.sh](run.sh) script basically checks:
- for any queued workflows on the target repository.
- creates a new instance with [this cloud-init script](cloud-init.sh) for each unique workflow run.
- terminates any stuck instances if the workflow concluded - just in case if the instances don't poweroff normally.


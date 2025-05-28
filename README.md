# Overview
Model-AD Data Manager is a tool that loads the JSON files into Model-AD's document database
instances in our AWS environments.

# Purpose
This project allows Model-AD maintainers to update the Model-AD database with
new versions of gene data from Synapse.  This is a manually triggered,
self-service update.

# Execution

![alt text][db_update]

# Workflow

To deploy an updated data version to the Model-AD development database
1. Increment `data_version` in `data-manifest.json` on the `develop` branch.
2. Commit the change
3. The Github action CI system automatically updates the dev DB


To deploy an updated data version to the Model-AD staging database:
1. Merge the data_version update from the dev branch to the staging branch.
2. The Github action CI system automatically updates the dev DB

To deploy an updated data version to the Model-AD production database:
1. Merge the data_version update from the staging branch to the production branch.
2. The Github action CI system automatically updates the dev DB


# Setup

## Secrets

The following secrets need to be setup in Github for the scripts to deploy database updates:

Global secrets:

| Variable             | Description                      | Example                          |
|----------------------|----------------------------------|----------------------------------|
| SYNAPSE_PASSWORD     | Synapse service user token (PAT) | glY4283tLQHZ...0eXAiOi...JKV1QiL |


Context specific secrets for each environment that corresponds to a git branch (develop/staging/prod):

| Variable  | Description                 | Example                                                                   |
|-----------|-----------------------------|---------------------------------------------------------------------------|
| DB_HOST   | The database host           | dbcluster-mr0a782pfjnk.cluster-ctcayu3de2lt.us-east-1.docdb.amazonaws.com |
| DB_USER   | The database user           | dbuser                                                                    |
| DB_PASS   | The database password       | supersecret                                                               |


![alt text][github_secrets]


## Self hosted runners

[modeladexplorer-infra] repository deploys a bastion host in AWS for each environment which have access to
the databases.  We manually configure a [Github self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners)
for each bastion host, a label is applied to each runner to match the corresponding git branch name (develop/staging/prod).
Each runner corresponds to an environment which corresponds to a git branch. The update is
executed from these runners.  When a push happens on a branch (i.e. develop), the update
is executed on the self-hosted runner with the `develop` label, which in turn updates the development database.


![alt text][self_hosted_runners]


### Setup self hosted runners

Github self hosted runners are deployed with [Cloudformation](https://github.com/Sage-Bionetworks-IT/modeladexplorer-infra/blob/dev/src/bastion_stack.py).

Self Hosted Runner setup:
* Deploy the template to the Model-AD AWS account.
* Login to AWS console and goto `EC2 -> select the deployed instance -> Connect -> Session Manager -> Connect` to gain ssh access to the instance.
* Follow the instructions to install the [Github self hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners#adding-a-self-hosted-runner-to-a-repository).  We installed it to the `/home/ssm-user/actions-runner` folder.
* Run the `config.sh` script to configure the runner.  !! Important !! Make sure to set the runner `name` and `label` corresponding to the desired deployment environment (develop/staging/prod)..
```text
sh-4.2$ pwd
/home/ssm-user/actions-runner

sh-4.2$ ./config.sh --url https://github.com/Sage-Bionetworks/model-ad-data-manager --token XXXXXXXXXXXXXXXXX6VLI

--------------------------------------------------------------------------------
|        ____ _ _   _   _       _          _        _   _                      |
|       / ___(_) |_| | | |_   _| |__      / \   ___| |_(_) ___  _ __  ___      |
|      | |  _| | __| |_| | | | | '_ \    / _ \ / __| __| |/ _ \| '_ \/ __|     |
|      | |_| | | |_|  _  | |_| | |_) |  / ___ \ (__| |_| | (_) | | | \__ \     |
|       \____|_|\__|_| |_|\__,_|_.__/  /_/   \_\___|\__|_|\___/|_| |_|___/     |
|                                                                              |
|                       Self-hosted runner registration                        |
|                                                                              |
--------------------------------------------------------------------------------

# Authentication


√ Connected to GitHub

# Runner Registration

Enter the name of the runner group to add this runner to: [press Enter for Default]

Enter the name of runner: [press Enter for ip-10-XXX-XXX-XXX] model-ad-bastion-prod

This runner will have the following labels: 'self-hosted', 'Linux', 'X64'
Enter any additional labels (ex. label-1,label-2): [press Enter to skip] prod

√ Runner successfully added
√ Runner connection is good

# Runner settings

Enter name of work folder: [press Enter for _work]

√ Settings Saved.
```
* Setup the [GH runner agent to run as a service](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/configuring-the-self-hosted-runner-application-as-a-service)
* Run the agent and then check the [GH Runners page](https://github.com/Sage-Bionetworks/model-ad-data-manager/settings/actions/runners) to make sure that the runner is in `Idle` status.

[db_update]: model-ad-db-update.drawio.png "update diagram"
[github_secrets]: github_secrets.png "github secrets screen"
[self_hosted_runners]: self-hosted-runners.png "self hosted runners"
[modeladexplorer-infra]: https://github.com/Sage-Bionetworks-IT/modeladexplorer-infra "modeladexplorer-infra repository"
[Github self-hosted runners]: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#about-self-hosted-runners

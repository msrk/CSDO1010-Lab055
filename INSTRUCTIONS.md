# Lab 055 — Continuous Integration with GitHub Actions

This lab uses a single Continuous Integration pipeline to manage infrastructure with Terraform. GitHub Actions executes Terraform operations. Authentication uses GitHub OIDC to assume an AWS IAM role.

The Terraform state is stored in S3 so the infrastructure can be created and destroyed consistently.

No Terraform code is introduced or modified in this lab. The lab focuses on how infrastructure lifecycle actions execute through CI using short-lived credentials, shared state, and explicit control boundaries.

**Outcomes**

These outcomes define what you will build and what you must remove at the end. The OIDC provider establishes trust between AWS and GitHub Actions. The IAM role and policies define exactly what the pipeline is allowed to do in AWS.

1. Create a GitHub **OIDC provider** in AWS.
2. Create IAM **role** and **least-privilege policies** for EC2, VPC create/teardown, and TF backend (S3+DDB).
3. Configure GitHub **environment** and **secrets/variables**.
4. Execute two workflows:
   - `.github/workflows/task-01-create-ec2-instance.yml` → runs Terraform in `terraform/` to build one EC2 instance in a **new VPC** using OIDC credentials and S3 backend.
   - `.github/workflows/task-02-destroy-ec2-instance.yml` → triggers on changes under `terraform/**` and destroys the instance using the state file saved in S3.
5. Destroy infrastructure and **clean up OIDC** and backend.

The GitHub environment centralizes configuration used by workflows. The two workflows separate infrastructure changes from configuration changes so each can run with clear scope and predictable triggers. The cleanup requirement enforces cost control and confirms you can fully reverse the deployment.

> Assumptions: your Terraform in `terraform/` deploys a single EC2 instance and tags resources `Project=lab055`. You will not modify TF in this lab.

This assumption is required because the IAM policies and inventory logic depend on consistent tagging and predictable resource shape. The lab focuses on pipeline mechanics and Cloud authentication, not Terraform authoring. If Terraform does not tag resources as specified, policy conditions can block create and destroy actions and inventory filtering can fail.

# 1. Prerequisites

## 1.1. Required Tools

Before beginning this lab, you need essential tools to authenticate with AWS and automate infrastructure provisioning using Terraform. These tools allow you to define, plan, and apply Infrastructure as Code safely and consistently.

Ensure each item below is installed and configured before proceeding.

| Requirement         | Description                                                         |
| :------------------ | :------------------------------------------------------------------ |
| **AWS Account**     | Create an account at [aws.amazon.com](https://aws.amazon.com).      |
| **AWS CLI**         | Install from [aws.amazon.com/cli](https://aws.amazon.com/cli).      |
| **AWS Credentials** | Run `aws configure` to set up access keys or SSO login.             |
| **Git Installed**   | Install from [git-scm.com/downloads](https://git-scm.com/downloads) |
| **GitHub Account**  | Create one at [github.com/join](https://github.com/join).           |

Confirm each tool functions correctly before starting the lab. A working AWS CLI and Terraform installation are required to complete deployment and cleanup steps.

These prerequisites establish the minimum environment needed to execute the lab without changing its scope. AWS CLI access is required to create IAM and backend resources. The GitHub repository is required because the workflows run from the repository. Terraform and Ansible content must exist because the pipelines reference those directories. The region must be consistent across AWS resources and pipeline configuration so state, locking, and deployments occur in the intended location.

## 1.2 Prepare metadata for deployment

These variables define where the pipeline runs, who it runs as, and what it is allowed to control. They bind GitHub Actions to a specific AWS account, region, and role, establish a shared and locked Terraform state, and scope permissions to lab resources only. This ensures the CI workflow is predictable, repeatable, and fully reversible.

This table explains how each variable establishes identity, scope, state control, and permission boundaries within the Continuous Integration pipeline.

| Variable       | Purpose in this exercise                                                                                                                                                                                                   |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ACCOUNT_ID`   | Identifies the AWS account where all resources, IAM roles, and policies are created. This ensures that trust relationships, ARNs, and permissions are applied to the correct account and not to an unintended environment. |
| `AWS_REGION`   | Defines the AWS region where Terraform backend resources and infrastructure operations occur. All CI-driven AWS API calls are scoped to this region to keep state, locking, and resource deployment consistent.            |
| `ENVIRONMENT`  | Binds GitHub Actions jobs to a specific GitHub Environment. This value is enforced in the IAM trust policy so only workflows running in this environment can assume the AWS role used by the pipeline.                     |
| `ROLE`         | Names the IAM role that GitHub Actions assumes using OIDC. This role represents the execution identity for all Terraform and Ansible operations performed by the CI pipelines.                                             |
| `RANDOM_SEED`  | Generates a unique suffix to avoid global naming collisions, primarily for S3 resources. This allows the lab to be executed multiple times without reusing or conflicting with existing infrastructure.                    |
| `STATE_BUCKET` | Specifies the S3 bucket that stores Terraform remote state. This bucket becomes the authoritative record of deployed infrastructure for all pipeline runs.                                                                 |
| `STATE_PREFIX` | Defines the logical path inside the state bucket where Lab 055 Terraform state is stored. This keeps lab state isolated and predictable within the backend.                                                                 |
| `LOCK_TABLE`   | Identifies the DynamoDB table used for Terraform state locking. This prevents concurrent CI executions from modifying the same state at the same time.                                                                     |
| `POLICY_EC2`   | Names the IAM policy that allows Terraform to manage EC2 instances and related resources that belong to this lab.                                                                                                          |
| `POLICY_VPC`   | Names the IAM policy that grants Terraform permission to create, modify, and delete VPC networking components required for the lab environment.                                                                            |

On the command line, set up the following variables:

```bash
# Basic Information
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-east-1
ENVIRONMENT=LAB055
ROLE=TF-Lab055-GitHubOIDC

# An unique 8-digit identifier for S3
RANDOM_SEED=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ' | cut -c1-8)

# TF backend names (unique per account)
STATE_BUCKET="csdo1010-lab055-tfstate-${RANDOM_SEED}"
STATE_PREFIX=lab055
LOCK_TABLE=csdo1010-lab055-tflock

# Policy names
POLICY_EC2=TF-Lab055-EC2
POLICY_VPC=TF-Lab055-VPCManage
```

`RANDOM_SEED` is used to generate a unique S3 bucket name because S3 bucket names are globally unique. The backend variables define where Terraform state is stored and how it is organized. The policy name variables standardize IAM policy creation and make attachment steps consistent.

---

## 2 Create GitHub OIDC provider

AWS requires the thumbprint to verify that when it connects to the OIDC provider’s HTTPS endpoint, it is talking to the legitimate service. It compares the fingerprint of the server certificate chain against the thumbprint you specify.

This section creates the identity provider entry in IAM that represents GitHub’s OIDC issuer. AWS uses this provider definition during role assumption to validate tokens issued by GitHub Actions. The thumbprint requirement exists because AWS must validate the certificate chain for the OIDC issuer endpoint at the TLS level before it trusts tokens from that issuer.

Check for the GitHub OIDC provider first, and then create if missing:

```bash
aws iam list-open-id-connect-providers
```

This command lists OIDC providers already registered in the AWS account. The purpose is to avoid duplicating the provider and to confirm whether the account already supports GitHub OIDC. If the provider already exists, creation should be skipped and you proceed to role and policy creation.

AWS stores this value as part of the OIDC provider definition. During each authentication exchange, AWS verifies that the TLS certificate of token.actions.githubusercontent.com ultimately chains to a certificate with that fingerprint.

That value is the SHA-1 thumbprint of the TLS certificate used by GitHub’s OIDC issuer [https://token.actions.githubusercontent.com](https://token.actions.githubusercontent.com). In this case, `6938fd4d98bab03faadb97b34396831e3780aea1` is the SHA-1 digest of the root CA certificate (“DigiCert High Assurance EV Root CA”) that signs GitHub’s OIDC endpoint.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

This command registers GitHub’s token issuer with AWS IAM so AWS can accept identity tokens from GitHub Actions. The `--client-id-list sts.amazonaws.com` value restricts the audience to AWS STS, which is required for `AssumeRoleWithWebIdentity`. The thumbprint pins the expected certificate chain so AWS can validate the issuer endpoint when it retrieves metadata and validates tokens.

If GitHub ever switches certificate authority, AWS will publish a new thumbprint in its documentation, and you would need to update it in your OIDC provider definition.

This statement sets an operational requirement. The trust relationship relies on correct TLS validation. If the certificate chain changes and the thumbprint is not updated, role assumption will fail because AWS will not trust the issuer endpoint.

---

# 3 Create policies

This section defines least-privilege permissions for Terraform runs executed by GitHub Actions. Policies are separated by domain to keep scope clear and to support targeted troubleshooting. Terraform requires both read permissions for planning and write permissions for resource creation and teardown.

## 3.1 EC2 only (instances + tagging)

This policy grants Terraform the ability to read EC2 state for planning and to manage the lifecycle of instances and related EC2 constructs. The read statement enables Terraform to discover current resources and determine drift. This design enforces scoping so the workflow cannot modify unrelated EC2 resources in the same AWS account.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PlanRead",
      "Effect": "Allow",
      "Action": ["ec2:Describe*"],
      "Resource": "*"
    },
    {
      "Sid": "InstanceLifecycleTagged",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:StartInstances",
        "ec2:StopInstances",
        "ec2:RebootInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:AssociateIamInstanceProfile",
        "ec2:DisassociateIamInstanceProfile",
        "ec2:ReplaceIamInstanceProfileAssociation",
        "ec2:ModifyInstanceAttribute",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:AllocateAddress",
        "ec2:ReleaseAddress",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TouchTaggedOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:StartInstances",
        "ec2:StopInstances",
        "ec2:RebootInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:ModifyInstanceAttribute",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress"
      ],
      "Resource": "*"
    }
  ]
}
```

In some cases, you may observe conditional statements like this one:

```json
{
  "Sid": "CreateVpcStackWithProjectTag",
  "Effect": "Allow",
  "Action": [
    "ec2:StartInstances",
    "ec2:StopInstances",
    "ec2:RebootInstances",
    "ec2:TerminateInstances",
    "ec2:CreateTags",
    "ec2:DeleteTags",
    "ec2:ModifyInstanceAttribute",
    "ec2:AttachVolume",
    "ec2:DetachVolume",
    "ec2:AssociateAddress",
    "ec2:DisassociateAddress"
  ],
  "Resource": "*",
  "Condition": {
    "StringEquals": { "aws:RequestTag/Project": "lab055" },
    "ForAllValues:StringEquals": { "aws:TagKeys": ["Project"] }
  }
}
```

The create permissions require the `Project=lab055` request tag so newly created resources are scoped to the lab. The modify and delete permissions require the resource tag so actions only apply to lab resources. The explicit deny on prevents accidental creation of a default EC2 instance, which is not part of the lab design and can create long-lived resources that are not properly controlled by Terraform state.

This can fail with Terraform because the condition requires the **create request** to include `Project=lab055` as a **request tag**, and Terraform does not always send tags on the same API call that creates a resource. For some EC2 and VPC-related resources, Terraform may create first and then apply tags in a separate `CreateTags` call, or it may not include `Project` on every create action that appears in the policy.

When that happens, the create action is denied because `aws:RequestTag/Project` is missing, even if Terraform would have tagged the resource immediately afterward. The `ForAllValues:StringEquals` requirement can also deny requests when Terraform includes additional tag keys beyond `Project`, which is common if you use provider `default_tags` or module tags such as `Name`, `Environment`, or `Owner`.

This is an example of a thoughtful, logical and defensive technique to prevent unwanted rogue resources. However, this may fail in execution due to nuance in the deployment process.

## 3.2 VPC create + manage

This policy gives Terraform the ability to create, connect, modify, and delete the networking resources required for a dedicated VPC deployment. The read permissions support planning and state reconciliation.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadForPlanning",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeAccountAttributes",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeVpcs",
        "ec2:DescribeVpcAttribute",
        "ec2:DescribeSubnets",
        "ec2:DescribeRouteTables",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeNatGateways",
        "ec2:DescribeAddresses",
        "ec2:DescribeNetworkAcls",
        "ec2:DescribeSecurityGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CreateVpcStackWithProjectTag",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc",
        "ec2:CreateSubnet",
        "ec2:CreateRouteTable",
        "ec2:CreateInternetGateway",
        "ec2:CreateNatGateway",
        "ec2:AllocateAddress",
        "ec2:CreateNetworkAcl",
        "ec2:CreateNetworkAclEntry",
        "ec2:CreateSecurityGroup",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AssociateAndModifyOnlyTaggedVpcStack",
      "Effect": "Allow",
      "Action": [
        "ec2:AttachInternetGateway",
        "ec2:DetachInternetGateway",
        "ec2:AssociateRouteTable",
        "ec2:DisassociateRouteTable",
        "ec2:ReplaceRouteTableAssociation",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:ModifyVpcAttribute",
        "ec2:ModifySubnetAttribute",
        "ec2:ReplaceNetworkAclAssociation",
        "ec2:DeleteNetworkAclEntry",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:DeleteTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DeleteOnlyTaggedVpcStack",
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteVpc",
        "ec2:DeleteSubnet",
        "ec2:DeleteRouteTable",
        "ec2:DeleteInternetGateway",
        "ec2:DeleteNatGateway",
        "ec2:ReleaseAddress",
        "ec2:DeleteNetworkAcl",
        "ec2:DeleteSecurityGroup"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BlockDefaultVpcCreation",
      "Effect": "Deny",
      "Action": "ec2:CreateDefaultVpc",
      "Resource": "*"
    }
  ]
}
```

## 3.3 Terraform backend

This policy allows Terraform running in CI to access the remote state. Listing the bucket is required for Terraform to locate the state key and manage workspace-related operations. Read, write, and delete on the state objects are required to update state as resources are created and destroyed.

The Terraform state must be shared between pipeline runs. An S3 bucket is created to store state. Versioning is enabled so state history is preserved. Encryption is enabled to protect state data. Tags identify the bucket as part of the lab.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateBucketList",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::<STATE_BUCKET>"
    },
    {
      "Sid": "StateObjectsRW",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<STATE_BUCKET>/lab055/*"
    }
  ]
}
```

### 3.3.1 Complete the policy

Replace the placeholder for `<STATE_BUCKET>` in the file `aws/policy-03-backend.json`. Refer to your variables above.

This optional command replaces the placeholder in the backend policy file with the actual bucket name generated earlier. This is required because IAM policies must reference the exact bucket ARN. Without this substitution, the policy would not match the real backend bucket and Terraform would fail to read or write state.

```bash
sed -i '' \
  -e "s/<STATE_BUCKET>/$STATE_BUCKET/g" \
  aws/policy-03-backend.json
```

### 3.3.2 Create and attach policies

These commands create managed IAM policies in your AWS account from the JSON documents. The purpose is to make permissions reusable and attachable to the CI role. Separating policies by function supports controlled updates and clearer auditing. At this stage you are defining what the CI role will be able to do, but the role itself does not yet exist.

```bash
aws iam create-policy \
  --policy-name "$POLICY_VPC" \
  --policy-document file://aws/policy-01-vpc.json

aws iam create-policy \
  --policy-name "$POLICY_EC2" \
  --policy-document file://aws/policy-02-ec2.json

aws iam create-policy \
  --policy-name "$POLICY_BACKEND" \
  --policy-document file://aws/policy-03-backend.json
```

## 4 Create the IAM role for GitHub OIDC

This section creates the IAM role that GitHub Actions will assume using the OIDC provider. The trust policy controls who can assume the role. The attached permission policies control what the assumed role can do. This separation is required because identity and authorization must be enforced independently.

## 4.1 Update the trust policy

Trust policy with **environment subject**. Save as `aws/policy-04-trust.json` and replace the placeholders for `<ACCOUNT_ID>`, `<OWNER>`, `<REPO>` and `<ENVIRONMENT>`.

This block extracts the GitHub repository owner and repository name from your Git remote URL and exports them as variables. Printing them verifies they were parsed correctly. The `sed` command then substitutes those values into the trust policy template.

```bash
eval "$(git remote get-url origin \
 | sed -E 's#.*github.com[:/](.+)/(.+)\.git#export GITHUB_OWNER=\1\nexport GITHUB_REPO=\2#')"

echo "$GITHUB_OWNER"
echo "$GITHUB_REPO"
```

You can use this command to replace these variables dynamically.

```bash
sed -i '' \
  -e "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" \
  -e "s/<OWNER>/$GITHUB_OWNER/g" \
  -e "s/<REPO>/$GITHUB_REPO/g" \
  -e "s/<ENVIRONMENT>/$ENVIRONMENT/g" \
  aws/policy-04-trust.json
```

Make changes to `aws/policy-04-trust.json` with the command above, or do it manually. This is required because the trust policy uses repository identity and environment identity to restrict role assumption. Without correct substitutions, the role might be assumable by the wrong repository or might not be assumable at all.

This trust policy allows AWS STS to issue role credentials only when the caller presents a valid GitHub OIDC token from the expected issuer and with expected claims. The `Principal.Federated` ties this role to the specific OIDC provider you created earlier. The audience restriction ensures the token is intended for AWS STS. The subject patterns restrict which GitHub contexts can assume the role, including the repository, the GitHub Environment, the main branch, tags, and pull requests. This is the enforcement point that prevents other repositories from using your role.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:<OWNER>/<REPO>:environment:<ENVIRONMENT>",
            "repo:<OWNER>/<REPO>:ref:refs/heads/main",
            "repo:<OWNER>/<REPO>:ref:refs/tags/*",
            "repo:<OWNER>/<REPO>:pull_request"
          ]
        }
      }
    }
  ]
}
```

## 4.2 Create role and attach policies:

The first command creates the IAM role with the trust policy you prepared.

```bash
aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document file://aws/policy-04-trust.json
```

The next three commands attach the VPC, EC2, and S3 backend policies so the role has the permissions Terraform needs.

```bash
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_VPC

aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_EC2

aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_BACKEND
```

The final command prints the role ARN, which is the identifier GitHub Actions must use when requesting credentials. The role ARN becomes a value you store in GitHub as a secret to keep workflow configuration consistent and centralized.

```bash
### Obtain the ROLE ARN
aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text
```

# 5 Create backend resources

We create the Terraform backend resources to establish a single, shared source of truth for infrastructure state that can be safely used by automation. Storing state in S3 allows every pipeline run to see the same view of deployed resources instead of relying on local files tied to one machine. These backend resources make Terraform usable in CI, support repeatable create and destroy operations, and ensure infrastructure changes remain controlled and reversible.

These commands create and harden the S3 bucket used for Terraform state. Versioning is required to preserve history and support recovery if state is overwritten. Encryption enforces protection of state data at rest. Tagging marks the bucket as part of the lab so it can be identified during cleanup and audited for cost and ownership.

```bash
aws s3api create-bucket \
  --bucket "$STATE_BUCKET" \
  --region $AWS_REGION

aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-bucket-tagging \
  --bucket "$STATE_BUCKET" \
  --tagging 'TagSet=[{Key=Project,Value=lab055}]'
```

# 6 Configure GitHub environment

The GitHub Environment acts as a controlled scope for secrets and variables, and it can enforce approvals if configured. The role ARN is stored as a secret because it is security-relevant configuration used to request credentials. Region and account id are stored as variables because they are operational inputs used by workflows and are not secrets. These values in the environment reduce duplication across workflows and makes changes consistent.

1. Open the repository in GitHub.
2. Select **Settings** in the top navigation.
3. In the left menu, select **Environments**.
4. Create environment `LAB055` in the repo.
5. In the **Secrets** section, select **Add secret**
   1. Add secret `AWS_OIDC_ROLE_ARN`
   1. Add secret `AWS_REGION`
   1. Add secret `STATE_BUCKET`

The purpose is to make the setup repeatable and scriptable. This supports lab execution in a controlled sequence and reduces manual configuration errors in the GitHub UI.

## 6 Workflows

The workflow files are the CI pipeline definition. Each job specifies where it runs, what permissions it needs, how it authenticates to AWS, and what commands it executes. This is the implementation of continuous integration for both infrastructure and configuration.

## 6.1 Deploy Infrastructure

Source: `.github/workflows/task-01-create-ec2-instance.yml`

This pipeline manages infrastructure using Terraform. It runs in GitHub Actions and uses the same Terraform configuration and backend on every execution. This ensures all infrastructure operations are performed against a single, shared state.

The workflow is manually triggered. A confirmation value is required before execution so destructive actions only run when explicitly approved. This prevents accidental removal of infrastructure.

The job runs in the LAB055 GitHub Environment. This environment supplies the secrets and variables required for execution. AWS validates this environment context when the pipeline assumes the IAM role using OIDC.

```yaml
# task-01-create-ec2-instance.yaml
name: Deploy Infrastructure

on:
  workflow_dispatch:

env:
  TF_WORKING_DIR: terraform

  # Terraform backend configuration
  TF_BACKEND_BUCKET: ${{ secrets.STATE_BUCKET }}
  TF_BACKEND_KEY: lab055/terraform.tfstate
  TF_BACKEND_REGION: ${{ secrets.AWS_REGION }}
  TF_BACKEND_LOCK_TABLE: csdo1010-lab055-tflock

jobs:
  terraform:
    environment: LAB055
    name: Provision AWS EC2
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Print repo and ref
        run: |
          echo "repo=${{ github.repository }}"
          echo "ref=${{ github.ref }}"
          echo "ref_name=${{ github.ref_name }}"
          echo "event=${{ github.event_name }}"
          echo "actor=${{ github.actor }}"
          echo "sha=${{ github.sha }}"
          echo "workflow_ref=${{ github.workflow_ref }}"

      - name: Print env vars
        run: |
          echo "GITHUB_REPOSITORY=$GITHUB_REPOSITORY"
          echo "GITHUB_REF=$GITHUB_REF"
          echo "GITHUB_REF_NAME=$GITHUB_REF_NAME"
          echo "GITHUB_HEAD_REF=$GITHUB_HEAD_REF"
          echo "GITHUB_BASE_REF=$GITHUB_BASE_REF"

      - name: Show OIDC claims
        run: |
          url="${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com"
          tok="$(curl -sH "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "$url" | jq -r .value)"
          echo "$tok" | awk -F. '{print $2}' | base64 -d 2>/dev/null | jq

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ${{ secrets.AWS_REGION }}
          role-to-assume: ${{ secrets.AWS_OIDC_ROLE_ARN }}

      - uses: hashicorp/setup-terraform@v3

      - name: Terraform init (S3 backend)
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: |
          terraform init -reconfigure -input=false \
            -backend-config="bucket=${TF_BACKEND_BUCKET}" \
            -backend-config="key=${TF_BACKEND_KEY}" \
            -backend-config="region=${TF_BACKEND_REGION}" \
            -backend-config="use_lockfile=true" \
            -backend-config="encrypt=true"

      - name: Terraform plan/apply
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: |
          terraform plan -out=tfplan -input=false
          terraform apply -input=false -auto-approve tfplan

      - name: Export EC2 tag filter for Ansible
        id: tfout
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: |
          terraform output -json > tf-outputs.json
          cat tf-outputs.json
          echo "tag_key=$(jq -r '.ansible_tag_key.value // "Project"' tf-outputs.json)" >> "$GITHUB_OUTPUT"
          echo "tag_value=$(jq -r '.ansible_tag_value.value // "lab055"' tf-outputs.json)" >> "$GITHUB_OUTPUT"
```

Terraform is initialized with a remote backend in S3 and locking enabled. This forces the pipeline to use the authoritative state and blocks concurrent Terraform executions. The pipeline then executes Terraform in non-interactive mode so it can run fully within CI without operator input.

## 6.2 Manually execute the infrastructure pipeline

This execution runs Terraform entirely from CI using shared state and short-lived credentials. No local Terraform execution is involved.

1. Open the GitHub repository in your browser.
2. Select the **Actions** tab.
3. In the left sidebar, select the workflow responsible for Terraform execution.
4. Select **Run workflow**.
5. Choose the branch to run against, typically `main`.
6. Select **Run workflow** to start execution.
7. Observe the workflow run to confirm AWS authentication using OIDC, Terraform initialization with the remote backend, and Terraform execution complete successfully.

## 6.3 Infrastructure Destroy pipeline

Source: `.github/workflows/task-02-destroy-ec2-instance.yml`

This pipeline manages software configuration using Ansible. It operates independently from Terraform and does not create or destroy infrastructure.

The pipeline targets instances dynamically by querying AWS and filtering resources by tag. This removes the need for static inventories and ensures configuration is applied only to instances created for this lab.

```yaml
name: Destroy Infrastructure

on:
  workflow_dispatch:
    inputs:
      confirm:
        description: "Type DESTROY to confirm"
        required: true
        default: ""

env:
  TF_WORKING_DIR: terraform

  # Terraform backend configuration
  TF_BACKEND_BUCKET: ${{ secrets.STATE_BUCKET }}
  TF_BACKEND_KEY: lab055/terraform.tfstate
  TF_BACKEND_REGION: ${{ secrets.AWS_REGION }}
  TF_BACKEND_LOCK_TABLE: csdo1010-lab055-tflock

jobs:
  destroy:
    name: Terraform destroy (CI)
    runs-on: ubuntu-latest
    environment: LAB055
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Block accidental runs
        run: |
          if [ "${{ github.event.inputs.confirm }}" != "DESTROY" ]; then
            echo "Refusing to run. Re-run and type DESTROY."
            exit 1
          fi

      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_OIDC_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - uses: hashicorp/setup-terraform@v3

      - name: Terraform init (same backend)
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: |
          terraform init -input=false \
            -backend-config="bucket=${TF_BACKEND_BUCKET}" \
            -backend-config="key=${TF_BACKEND_KEY}" \
            -backend-config="region=${TF_BACKEND_REGION}" \
            -backend-config="use_lockfile=true" \
            -backend-config="encrypt=true"

      - name: Terraform destroy
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: |
          terraform destroy -auto-approve -input=false
```

The separation from the infrastructure pipeline enforces a clear boundary between provisioning and configuration. Infrastructure changes and software changes follow different execution paths and can be triggered independently.

Authentication follows the same OIDC process used by the infrastructure pipeline. The pipeline assumes the same IAM role, ensuring all automation runs under a consistent and auditable identity.

## 6.4 Manually destroy infrastructure using the pipeline

This execution removes infrastructure using the same identity, permissions, and state used during creation, ensuring cleanup is complete and consistent.

1. Open the **Actions** tab in the repository.
2. Select the Destroy Infrastructure workflow.
3. Select **Run workflow**.
4. Choose the appropriate branch.
5. Enter the required confirmation value exactly as defined in the workflow input.
6. Select **Run workflow**.
7. Monitor the workflow to confirm Terraform initializes against the same backend and destroys all tracked resources.

# 7 Destroy and cleanup

This section enforces cost control and account hygiene. The goal is to leave no resources behind. Destruction removes infrastructure. Cleanup removes the authentication and backend components that enabled CI to run. This confirms the lab is reversible and that permissions and state storage are not left available after completion.

## 7.1 Delete backend resources

This sequence removes Terraform state data and then removes the bucket itself. The first command deletes objects under the lab prefix, which is necessary but not sufficient when versioning is enabled.

```bash
# Remove state objects
aws s3 rm "s3://$STATE_BUCKET/$STATE_PREFIX/" --recursive || true
```

The next commands enumerate object versions and delete markers and then delete them explicitly. This is required because versioned S3 buckets retain historical versions until they are removed.

```bash
# Clean versioned objects and delete the bucket
aws s3api list-object-versions \
 --bucket "$STATE_BUCKET" \
 --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
 --output json > /tmp/objs.json || true

aws s3api delete-objects \
 --bucket "$STATE_BUCKET" \
 --delete file:///tmp/objs.json || true

aws s3api list-object-versions \
 --bucket "$STATE_BUCKET" \
 --query='{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
 --output json > /tmp/dm.json || true

# Clean versioned objects and delete the bucket
aws s3api delete-objects \
 --bucket "$STATE_BUCKET" \
 --delete file:///tmp/dm.json || true
```

The final command deletes the bucket after it has been fully emptied. The purpose is to ensure no state artifacts remain and to stop ongoing storage and versioning costs.

```bash
aws s3api delete-bucket --bucket "$STATE_BUCKET"
```

## 7.2 Detach and delete OIDC role and policies

Detaching policies is required before a role can be deleted. This loop retrieves all policy ARNs attached to the role and removes each attachment.

```bash
# Detach Policies
for arn in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text); do
  aws iam detach-role-policy \
    --role-name "$ROLE" \
    --policy-arn "$arn"
done
```

Deleting the role removes the ability for GitHub Actions to assume permissions in your account.

```bash
# Delete role
aws iam delete-role --role-name "$ROLE"
```

The final loop deletes the custom managed policies created for the lab. The version deletion step is required because managed policies can have multiple versions and AWS requires non-default versions to be deleted before the policy itself can be deleted. The purpose is to remove permissions artifacts so they cannot be reused unintentionally.

```bash
# Delete custom policies (only if unused elsewhere)
for P in "$POLICY_EC2" "$POLICY_VPC" "$POLICY_BACKEND"; do
  ARN="arn:aws:iam::$ACCOUNT_ID:policy/$P"
  for v in $(aws iam list-policy-versions --policy-arn "$ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null); do
    aws iam delete-policy-version \
      --policy-arn "$ARN" \
      --version-id "$v"
  done
  aws iam delete-policy --policy-arn "$ARN" || true
done
```

## 7.3 Delete OIDC provider

This removes the OIDC provider registration from AWS. The purpose is to eliminate the trust anchor that allows any role to be assumed via GitHub OIDC in this account.

The condition “only if no other roles use it” matters because other pipelines in the account may rely on the same provider. Deleting it will break those workflows.

```bash
PROVIDER_ARN=arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "$PROVIDER_ARN" || true
```

## 7.4 Remove GitHub secrets and variables

This step removes repository configuration that enables the workflows to run. The purpose is to prevent accidental reuse of the lab environment configuration and to ensure that future workflows do not inherit lab-specific values. This also reduces the footprint of sensitive configuration in the repository settings.

- Go to the repostory Settings → Environment `LAB055` → delete secrets `AWS_OIDC_ROLE_ARN`, `AWS_REGION`, and `STATE_BUCKET`.

---

# Troubleshooting

This troubleshooting section identifies the failure domains that stop the lab. OIDC failures are caused by missing job permissions or trust policy mismatch. Backend failures are caused by incorrect bucket naming, missing bucket resources, or insufficient S3 and DynamoDB permissions for state operations. VPC creation failures are caused by policy enforcement that blocks default VPC creation or by missing required tags that make requests fail IAM conditions.

- **Not authorized to perform `sts:AssumeRoleWithWebIdentity`**
  Job needs `permissions: { id-token: write }`. Trust must allow `sub = repo:OWNER/REPO:environment:LAB055` and `aud = sts.amazonaws.com`.

- **Terraform backend errors**
  Ensure backend policy names match bucket/table ARNs. Bucket exists, encryption and versioning set, and IAM has S3/DDB rights.

- **VPC create blocked**
  Policy includes a deny for `CreateDefaultVpc`. Ensure TF creates a new VPC and applies `Project=lab055` tags to all resources.

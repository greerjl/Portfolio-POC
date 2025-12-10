# Portfolio-POC

This project demonstrates a CI/CD pipeline that builds and pushes a Docker image to Amazon ECR and deploys infrastructure with Terraform. The GitHub Actions workflow has been configured to use GitHub OIDC to assume an AWS IAM role instead of storing long-lived AWS credentials in repository secrets.

## Table of contents

- The Problem
- The Solution
- Considerations
- Deliverables
- Risks
- What this repo contains
- Architecture Diagram
- Timeline for Project Deployment at scale
- Prerequisites
- Local development
- CI / GitHub Actions (OIDC)
- Terraform usage
- AWS IAM role / OIDC setup
- Debugging & verification
- Security notes

## The Problem

- **Objective:**
Standardize deployment and configuration of observability agents across environments
Ensure consistent telemetry pipelines through automation and IaC
- **Approach:**
GitHub Actions orchestrates Terraform-driven deploys for ECS workloads
Immutable image tagging ensures reliable promotion from Dev → Prod
OpenTelemetry Collector configuration injected securely via AWS Parameter Store
CI/CD gates simulate real-world approval and change management flows
- **Outcome:**
Zero manual deployment steps
Consistent agent configuration between environments
Secure, versioned observability pipeline setup
Seamless promotion process validated through automation

## The Solution

**1. Continuous Integration (Build and Validation)**
Triggered automatically on merge to main.
Builds and tags immutable Docker images.
Validates Terraform syntax and configuration.
Ensures repeatable, consistent artifacts across environments.
Reduces drift and build-time errors before deployment.

**2. Continuous Deployment (Environment Promotion)**
GitHub Actions assumes AWS IAM roles via OIDC (no static creds).
Terraform applies infrastructure and ECS updates automatically.
Manual approval step simulates enterprise change control.
Promotes tested builds from Dev → Prod with auditability.

**3. Observability and Agent Automation**
ECS tasks run an OpenTelemetry sidecar alongside the app.
Collector config stored securely in AWS Parameter Store.
Sends traces and metrics to CloudWatch (future: Datadog/X-Ray).
Observability is built-in, not bolted on.

**4. Infrastructure Lifecycle and Maintenance**
Terraform enables full teardown and rebuild on demand.
Remote state stored in S3 + DynamoDB for team collaboration.
Supports rapid iteration and rollback testing.
Keeps environments clean, consistent, and cost-efficient.

## Considerations

- **Scalability:**
	- Auto-scales ECS tasks with Fargate
	- ALB balances traffic across tasks
	- Multi-AZ setup for high availability
	- Scales based on CPU, memory, or load
- **Automation:**
	- CI/CD fully automated via GitHub Actions
	- Terraform provisions and manages all infra
	- OIDC roles for secure cross-account deploys
	- Immutable image tagging for safe promotions
	- Repeatable, hands-free environment builds
- **Reliability:**
	- ECS circuit breaker auto-rolls back failed deploys
	- ALB + health checks ensure healthy routing
	- CloudWatch logs for visibility and alerting
	- OpenTelemetry adds deep observability
	- S3 + DynamoDB maintain consistent Terraform state

## Deliverables

- **Phase 1: Foundation** - Start with Terraform - define infrastructure as code to make environments reproducible.
- **Phase 2: Automation** - Implement CI/CD pipelines (GitHub Actions + OIDC) for Dev → Prod deployments.
- **Phase 3: Observability** - Integrate OpenTelemetry collector for traces, metrics, and logs.
- **Phase 4: Scalability** - Enable auto-scaling and deploy across multiple Availability Zones for high availability.
- **Phase 5: Optimization** - Once stable, focus on fine-tuning monitoring, alerting, and cost efficiency.

## Risks 

- **Permissions:** IAM roles must be tightly scoped = too broad or narrow can break pipelines.
- **State drift:** Manual AWS changes outside Terraform cause instability.
- **Tag immutability:** Immutable ECR tags protect production but require unique tagging strategies.
- **Service limits:** Scaling too fast may hit ECS or Fargate limits.
- **Collector reliability:** If the OpenTelemetry collector fails, trace data is lost.
- **Cross-account roles:** OIDC trust between Dev and Prod must stay synchronized.
- **Cost management:** More containers and logs increase spend; watch budgets as usage grows.

## What this repo contains

- `.github/workflows/ci.yaml` - GitHub Actions workflow that builds and pushes a Docker image to ECR and runs Terraform to apply infrastructure changes.
- `Dockerfile` (if present) - image build instructions used by the workflow.
- `*.tf` - Terraform configuration for provisioning resources (if present in the repo).
- `.gitignore` - rules added to avoid committing local artifacts, credentials and build outputs.

> Note: This repository is an example/proof-of-concept. Adjust registry names, Terraform variables, and IAM policies before using in production.

## Architecture Diagram
<img width="1891" height="699" alt="Demo drawio" src="https://github.com/user-attachments/assets/549c87fd-604b-459d-bfca-98ea2f1bf8ae" />


## Timeline for Project Deployment at scale
<img width="1807" height="722" alt="POC Deployment Timeline" src="https://github.com/user-attachments/assets/0b935855-293b-4fe8-8df6-864603c1a4a0" />


## Prerequisites

- Git and a GitHub account with push access to this repository.
- An AWS account and an IAM role created for GitHub OIDC (example: `arn:aws:iam::[account ID]:role/GitHubAction-AssumeRoleWithAction`).
- Terraform (recommended v1.5.0 as used in CI) installed locally if you plan to run Terraform locally.
- Docker installed locally if you plan to build images locally.

## Local development

1. Clone the repository:

	 git clone git@github.com:greerjl/Implementation-Services-POC.git
	 cd Implementation-Services-POC

2. Build the Docker image locally (optional):

	 docker build -t myrepo/myimage:local .

3. Run Terraform locally (optional):

	 export TF_VAR_env=dev
	 export TF_VAR_image=myrepo/myimage:local
	 terraform init
	 terraform plan
	 terraform apply

If you run Terraform locally you must configure AWS credentials on your machine (for example via `aws configure` or environment variables). The CI uses OIDC and does not require repository AWS secrets.

## CI / GitHub Actions (OIDC)

The workflow `.github/workflows/ci.yaml` performs these high-level steps when changes are pushed to `main` (or a PR targeting `main`):

1. Checkout the repo.
2. Setup Terraform.
3. Configure AWS credentials using `aws-actions/configure-aws-credentials@v2` via OIDC IAM role.
4. Login to Amazon ECR.
5. Build and push a Docker image to ECR.
6. Write the image tag to the GitHub Actions outputs and run Terraform init/plan/apply to deploy.

Key permissions in the workflow header (required for OIDC):

- `permissions: id-token: write` — necessary to request a JWT from GitHub's OIDC provider.
- `permissions: contents: read` — necessary for `actions/checkout`.

If you want to verify which role the workflow assumed, there is a temporary debug step in the workflow that runs:

```
aws sts get-caller-identity
```

This prints the assumed-role ARN in the Actions logs.

## Terraform usage

The workflow sets Terraform variables from the matrix and built image and runs:

- `terraform init -input=false`
- `terraform plan -input=false -out=tfplan`
- `terraform apply -input=false -auto-approve tfplan`

Locally, use the same pattern but make sure `TF_VAR_*` environment variables are set before running Terraform commands.

## AWS IAM role / OIDC setup

Ensure the role's trust policy allows GitHub's OIDC provider and restricts access to the repository and, optionally, branches.

Example minimal trust policy:

```json
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Principal": {
				"Federated": "arn:aws:iam::[account ID]:oidc-provider/token.actions.githubusercontent.com"
			},
			"Action": "sts:AssumeRoleWithWebIdentity",
			"Condition": {
				"StringEquals": {
					"token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
					"token.actions.githubusercontent.com:sub": "repo:greerjl/Implementation-Services-POC:ref:refs/heads/main"
				}
			}
		}
	]
}
```

If you want to allow workflows from any branch in the repo, use:

```
"token.actions.githubusercontent.com:sub": "repo:greerjl/Implementation-Services-POC:*"
```

Or to allow multiple repositories, add multiple Statement entries or widen the subject pattern with care.

Permissions policy attached to the role
- Grant only the minimum permissions required for CI: ECR push/pull, STS assume, and whatever Terraform needs (for example, create/update specific infra resources). Avoid using AdministratorAccess in production.

## Debugging & verification

- Trigger the workflow: push a commit to `main` or open a PR against `main`.
- Inspect the `Configure AWS credentials (OIDC)` step and the `Check caller identity (debug)` step in the Actions run to confirm the assumed role ARN.
- If the workflow fails to assume the role, check the CloudWatch logs for STS failures and confirm the role trust policy matches the token subject/audience the workflow provides.

Common issues:

- Wrong OIDC provider ARN in trust policy — use `arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com`.
- Incorrect `sub` or `aud` condition values in the trust policy — ensure these match the repo and `sts.amazonaws.com` respectively.
- Missing `id-token: write` permission in the workflow — required for requesting JWTs.

## Security notes

- Remove long-lived AWS credentials from the repository settings if you fully adopt OIDC.
- Rotate any keys that were committed by mistake and consider using a secret scanner (GitHub advanced security or a tool like `truffleHog`) to check history.
- Limit the IAM role permissions as narrowly as possible.

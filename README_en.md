<table>
	<thead>
    	<tr>
      		<th style="text-align:center"><a href="./README.md">日本語</a></th>
          <th style="text-align:center">English</th>
    	</tr>
  	</thead>
</table>

# Bedrock Cost Alert

A GitHub Actions workflow that aggregates Amazon Bedrock usage cost from CloudWatch Logs and generates a per-IAM-user cost report.

## Prerequisites

### 1. Enable Bedrock model invocation logging

You need to configure Amazon Bedrock in the AWS console to send model invocation logs to CloudWatch Logs.

1. Open AWS Console > Amazon Bedrock > Settings > **Model invocation logging**
2. Enable **CloudWatch Logs** as the log destination
3. Use the default log group name `/aws/bedrock/model-invocations` (matches the script's default)

### 2. Configure the OIDC identity provider for GitHub Actions

The workflow connects to AWS via OIDC authentication. Register a GitHub OIDC identity provider in your AWS account.

1. AWS Console > IAM > **Identity providers** > Add provider
2. Set the following values:
   - Provider type: **OpenID Connect**
   - Provider URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`

### 3. Create an IAM role

Create an IAM role that GitHub Actions will assume to access AWS resources.

#### Trust policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_OWNER>/<REPOSITORY_NAME>:*"
        }
      }
    }
  ]
}
```

Replace `<AWS_ACCOUNT_ID>`, `<GITHUB_OWNER>`, and `<REPOSITORY_NAME>` with the actual values.

#### Required IAM permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:StartQuery",
        "logs:GetQueryResults"
      ],
      "Resource": "arn:aws:logs:*:<AWS_ACCOUNT_ID>:log-group:/aws/bedrock/model-invocations:*"
    }
  ]
}
```

### 4. Configure GitHub repository Secrets

Register the following Secrets in **Settings > Secrets and variables > Actions** of your repository.

| Secret name | Required | Description |
|---|---|---|
| `AWS_ROLE_ARN` | Yes | ARN of the IAM role created in step 3 (e.g. `arn:aws:iam::123456789012:role/bedrock-cost-role`) |
| `AWS_REGION` | No | Default region. Falls back to `ap-northeast-1` if not set |
| `TEAMS_WEBHOOK_URL` | No | Teams Webhook URL for cost alert notifications. Notifications are skipped if not set |

## How to run the workflow

### Scheduled execution (automatic)

The workflow aggregates the current month's cost on the following schedule.

- Daily at JST 12:00 (UTC 03:00)
- Daily at JST 17:00 (UTC 08:00)

The alert threshold for scheduled runs is set to `$1000`.

### Manual execution

You can run the workflow manually from the **Actions** tab of the GitHub repository.

1. **Actions** tab > Select **Bedrock-Cost-Report** from the left menu
2. Click **Run workflow**
3. Enter parameters and run

| Parameter | Default | Description |
|---|---|---|
| `month` | Empty (auto-set to current month) | Target month (YYYY-MM format, e.g. `2026-03`) |
| `regions` | `ap-northeast-1` | Target regions (comma-separated for multiple, e.g. `ap-northeast-1,us-west-2`) |
| `alert_threshold` | `0` | Cost threshold in USD for sending Teams alert. `0` disables notification |

## Viewing results

- **Job Summary**: The cost report is displayed in the Summary tab of the workflow run
- **Teams notification**: When `alert_threshold` is set and the total cost across all users exceeds the threshold, an Adaptive Card notification is sent

<table>
	<thead>
    	<tr>
      		<th style="text-align:center">日本語</th>
          <th style="text-align:center"><a href="./README_en.md">English</a></th>
    	</tr>
  	</thead>
</table>

# Bedrock Cost Alert

Amazon Bedrock の利用コストを CloudWatch Logs から集計し、IAM ユーザーごとのコストレポートを生成する GitHub Actions ワークフローです。

## 前提条件

### 1. Bedrock モデル呼び出しログの有効化

AWS コンソールで Bedrock のモデル呼び出しログを CloudWatch Logs に送信する設定が必要です。

1. AWS コンソール > Amazon Bedrock > Settings > **Model invocation logging** を開く
2. ログの送信先として **CloudWatch Logs** を有効化する
3. ロググループ名はデフォルトで `/aws/bedrock/model-invocations` を使用する（スクリプトのデフォルト値と一致）

### 2. GitHub Actions 用 OIDC ID プロバイダーの設定

ワークフローは OIDC 認証で AWS に接続します。AWS アカウントに GitHub 用の OIDC ID プロバイダーを登録してください。

1. AWS コンソール > IAM > **ID プロバイダー** > プロバイダを追加
2. 以下の値を設定する:
   - プロバイダのタイプ: **OpenID Connect**
   - プロバイダの URL: `https://token.actions.githubusercontent.com`
   - 対象者: `sts.amazonaws.com`

### 3. IAM ロールの作成

GitHub Actions が AWS リソースにアクセスするための IAM ロールを作成します。

#### 信頼ポリシー

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWSアカウントID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<GitHubオーナー>/<リポジトリ名>:*"
        }
      }
    }
  ]
}
```

`<AWSアカウントID>`、`<GitHubオーナー>`、`<リポジトリ名>` を実際の値に置き換えてください。

#### 必要な IAM 権限

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
      "Resource": "arn:aws:logs:*:<AWSアカウントID>:log-group:/aws/bedrock/model-invocations:*"
    }
  ]
}
```

### 4. GitHub リポジトリの Secrets 設定

リポジトリの **Settings > Secrets and variables > Actions** で以下の Secrets を登録してください。

| Secret 名 | 必須 | 説明 |
|---|---|---|
| `AWS_ROLE_ARN` | Yes | 手順 3 で作成した IAM ロールの ARN（例: `arn:aws:iam::123456789012:role/bedrock-cost-role`） |
| `AWS_REGION` | No | デフォルトリージョン。未設定の場合は `ap-northeast-1` が使用される |
| `TEAMS_WEBHOOK_URL` | No | コスト超過時の Teams 通知先 Webhook URL。未設定の場合は通知しない |

## ワークフローの実行方法

### スケジュール実行（自動）

以下のスケジュールで当月分を自動集計します。

- 毎日 JST 12:00（UTC 03:00）
- 毎日 JST 17:00（UTC 08:00）

スケジュール実行時のアラート閾値は `$1000` に設定されています。

### 手動実行

GitHub リポジトリの **Actions** タブから手動で実行できます。

1. **Actions** タブ > 左メニューから **Bedrock-Cost-Report** を選択
2. **Run workflow** をクリック
3. パラメータを入力して実行する

| パラメータ | デフォルト値 | 説明 |
|---|---|---|
| `month` | 空（当月を自動セット） | 集計対象月（YYYY-MM 形式、例: `2026-03`） |
| `regions` | `ap-northeast-1` | 集計対象リージョン（カンマ区切りで複数指定可、例: `ap-northeast-1,us-west-2`） |
| `alert_threshold` | `0` | Teams アラートを送信するコスト閾値（USD）。`0` の場合は通知しない |

## 実行結果の確認

- **Job Summary**: ワークフロー実行の Summary タブにコストレポートが表示されます
- **Teams 通知**: `alert_threshold` を設定し、全ユーザーの合計コストが閾値を超えた場合に Adaptive Card で通知されます
 
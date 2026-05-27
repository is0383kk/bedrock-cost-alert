<#
.SYNOPSIS
    Amazon Bedrock の Claude Code 利用コストをユーザーごとに集計して出力します。

.DESCRIPTION
    AWS CLI で CloudWatch Logs Insights を呼び出し、Bedrock モデル呼び出しログから
    入力/出力トークン数を取得してコストを算出し、IAM ユーザーごとに集計します。

.PARAMETER LogGroupName
    Bedrock モデル呼び出しログのロググループ名。
    デフォルト: /aws/bedrock/model-invocations

.PARAMETER Regions
    集計対象の AWS リージョン (複数指定可)。
    デフォルト: ap-northeast-1

.PARAMETER DaysBack
    集計対象の日数 (当日から遡る)。デフォルト: 30
    -Month を指定した場合は無視されます。

.PARAMETER Month
    集計対象の月を "YYYY-MM" 形式で指定します (例: "2026-03")。
    指定した場合、その月の 1 日 00:00:00 UTC ～ 末日 23:59:59 UTC が対象になります。
    -DaysBack より優先されます。

.EXAMPLE
    .\Get-BedrockCost.ps1
    .\Get-BedrockCost.ps1 -DaysBack 7
    .\Get-BedrockCost.ps1 -Month "2026-03"
    .\Get-BedrockCost.ps1 -Month "2025-12" -Regions "us-west-2"
    .\Get-BedrockCost.ps1 -Regions "us-west-2" -DaysBack 30
    .\Get-BedrockCost.ps1 -Regions "us-west-2","ap-northeast-1" -DaysBack 7

.NOTES
    前提条件:
    - AWS CLI がインストールされ、認証情報が設定されていること
    - Bedrock モデル呼び出しログが CloudWatch Logs に送信されていること
      (Bedrock コンソール > Settings > Model invocation logging で設定)
    - logs:StartQuery, logs:GetQueryResults の IAM 権限が必要です

    料金について:
    - スクリプト内の $ModelPricing の値は参考値です
    - 正確な料金は https://aws.amazon.com/bedrock/pricing/ を確認してください
#>

param(
    [string]  $LogGroupName    = "/aws/bedrock/model-invocations",
    [string[]]$Regions         = @("ap-northeast-1"),
    [int]     $DaysBack        = 30,
    [string]  $Month           = "",
    [double]  $AlertThreshold  = 0.0,
    [string]  $TeamsWebhookUrl = ""
)

# -----------------------------------------------------------------------
# AWS CLI の確認
# -----------------------------------------------------------------------
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error "AWS CLI が見つかりません。"
    exit 1
}

# -----------------------------------------------------------------------
# Claude モデルの料金テーブル (USD / 1M トークン)
# 最新料金: https://aws.amazon.com/bedrock/pricing/
# -----------------------------------------------------------------------
$ModelPricing = @{
    # 出典: https://platform.claude.com/docs/en/about-claude/pricing
    # CacheWrite は 5 分キャッシュの料金 (Input * 1.25)、CacheRead は Input * 0.1
    # Claude Opus 4.7
    "claude-opus-4-7"   = @{ Input =  5.00; Output = 25.00; CacheWrite =  6.25; CacheRead = 0.50 }
    # Claude Opus 4.6
    "claude-opus-4-6"   = @{ Input =  5.00; Output = 25.00; CacheWrite =  6.25; CacheRead = 0.50 }
    # Claude Opus 4.1
    "claude-opus-4-1"   = @{ Input = 15.00; Output = 75.00; CacheWrite = 18.75; CacheRead = 1.50 }
    # Claude Sonnet 4.6
    "claude-sonnet-4-6" = @{ Input =  3.00; Output = 15.00; CacheWrite =  3.75; CacheRead = 0.30 }
    # Claude Sonnet 4.5
    "claude-sonnet-4-5" = @{ Input =  3.00; Output = 15.00; CacheWrite =  3.75; CacheRead = 0.30 }
    # Claude Haiku 4.5
    "claude-haiku-4-5"  = @{ Input =  1.00; Output =  5.00; CacheWrite =  1.25; CacheRead = 0.10 }
}
# 料金テーブルに一致しないモデルに適用するデフォルト料金
$DefaultPricing = @{ Input = 3.00; Output = 15.00; CacheWrite = 3.75; CacheRead = 0.30 }

# -----------------------------------------------------------------------
# 集計期間の設定 (Unix タイムスタンプ秒)
# -----------------------------------------------------------------------
if ($Month -ne "") {
    if ($Month -notmatch '^\d{4}-\d{2}$') {
        Write-Error "-Month は 'YYYY-MM' 形式で指定してください (例: '2026-03')"
        exit 1
    }
    $ParsedMonth = [datetime]::ParseExact($Month, "yyyy-MM", $null)
    $StartTime   = [DateTimeOffset]::new($ParsedMonth.Year, $ParsedMonth.Month, 1, 0, 0, 0, [TimeSpan]::Zero)
    $EndTime     = $StartTime.AddMonths(1).AddSeconds(-1)
} else {
    $EndTime   = [DateTimeOffset]::UtcNow
    $StartTime = $EndTime.AddDays(-$DaysBack)
}
$EndUnix   = $EndTime.ToUnixTimeSeconds()
$StartUnix = $StartTime.ToUnixTimeSeconds()

Write-Host "CloudWatch Logs Insights クエリを実行中..."
Write-Host "  ロググループ : $LogGroupName"
Write-Host "  リージョン   : $($Regions -join ', ')"
Write-Host "  集計期間     : $($StartTime.ToString('yyyy-MM-dd')) ~ $($EndTime.ToString('yyyy-MM-dd'))"
Write-Host ""

# -----------------------------------------------------------------------
# CloudWatch Logs Insights クエリ文字列
# -----------------------------------------------------------------------
$QueryString = 'fields identity.arn, modelId, input.inputTokenCount, input.cacheReadInputTokenCount, input.cacheWriteInputTokenCount, output.outputTokenCount | filter schemaType = "ModelInvocationLog" | stats sum(input.inputTokenCount) as totalInputTokens, sum(input.cacheReadInputTokenCount) as totalCacheReadTokens, sum(input.cacheWriteInputTokenCount) as totalCacheWriteTokens, sum(output.outputTokenCount) as totalOutputTokens by identity.arn, modelId'

# -----------------------------------------------------------------------
# ユーザーごとのコスト集計 (全リージョン合算)
# -----------------------------------------------------------------------
$UserCosts = @{}

foreach ($Region in $Regions) {
    Write-Host "[$Region] クエリ開始..."

    # クエリ開始
    $StartJson = aws logs start-query `
        --log-group-name $LogGroupName `
        --start-time     $StartUnix `
        --end-time       $EndUnix `
        --query-string   $QueryString `
        --region         $Region 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "[$Region] クエリの開始に失敗しました:`n$StartJson"
        exit 1
    }

    $QueryId = ($StartJson | ConvertFrom-Json).queryId

    # 結果をポーリング (Complete になるまで待機)
    $Dots = 0
    do {
        Start-Sleep -Seconds 2
        $ResultJson = aws logs get-query-results --query-id $QueryId --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Error "[$Region] クエリ結果の取得に失敗しました:`n$ResultJson"
            exit 1
        }

        $Result = $ResultJson | ConvertFrom-Json
        Write-Host -NoNewline "."
        $Dots++
    } while ($Result.status -in @("Running", "Scheduled"))

    if ($Dots -gt 0) { Write-Host "" }

    if ($Result.status -ne "Complete") {
        Write-Error "[$Region] クエリが完了しませんでした (Status: $($Result.status))"
        exit 1
    }

    # CWL Insights の stats コマンドは最大 10,000 グループを返します
    if ($Result.results.Count -ge 10000) {
        Write-Warning "[$Region] 集計結果のグループ数が 10,000 件に達しています。集計が不完全な場合があります。-DaysBack を短くして再実行するか、期間を分割してください。"
    }

    foreach ($Row in $Result.results) {
        # [{field, value}, ...] をハッシュテーブルに変換
        $Fields = @{}
        foreach ($Entry in $Row) {
            $Fields[$Entry.field] = $Entry.value
        }

        $Arn               = $Fields["identity.arn"]
        $ModelId           = $Fields["modelId"]
        $InputTokens       = [double]($Fields["totalInputTokens"]      -replace "[^\d.]")
        $CacheReadTokens   = [double]($Fields["totalCacheReadTokens"]  -replace "[^\d.]")
        $CacheWriteTokens  = [double]($Fields["totalCacheWriteTokens"] -replace "[^\d.]")
        $OutputTokens      = [double]($Fields["totalOutputTokens"]     -replace "[^\d.]")

        # IAM ARN からユーザー名を抽出
        # 例: arn:aws:iam::123456789012:user/john.doe -> john.doe
        $UserName = if ($Arn -match ":user/(.+)$") { $Matches[1] } else { $Arn }

        # モデル ID を部分一致で料金テーブルと照合
        $Pricing = $DefaultPricing
        foreach ($Key in $ModelPricing.Keys) {
            if ($ModelId -like "*$Key*") {
                $Pricing = $ModelPricing[$Key]
                break
            }
        }

        $Cost = ($InputTokens      / 1000000 * $Pricing.Input) +
                ($CacheReadTokens  / 1000000 * $Pricing.CacheRead) +
                ($CacheWriteTokens / 1000000 * $Pricing.CacheWrite) +
                ($OutputTokens     / 1000000 * $Pricing.Output)

        if (-not $UserCosts.ContainsKey($UserName)) {
            $UserCosts[$UserName] = 0.0
        }
        $UserCosts[$UserName] += $Cost
    }
}

# -----------------------------------------------------------------------
# 結果出力
# -----------------------------------------------------------------------
if ($UserCosts.Count -eq 0) {
    Write-Host "対象期間にログが見つかりませんでした。"
    exit 0
}

$TotalCost = ($UserCosts.Values | Measure-Object -Sum).Sum

Write-Host ("Total Cost:`${0:F2}" -f $TotalCost)
foreach ($User in ($UserCosts.Keys | Sort-Object)) {
    Write-Host ("- {0}:`${1:F2}" -f $User, $UserCosts[$User])
}

# -----------------------------------------------------------------------
# Teams アラート通知
# -----------------------------------------------------------------------
if ($AlertThreshold -gt 0 -and $TeamsWebhookUrl -ne "") {
    if ($TotalCost -gt $AlertThreshold) {
        Write-Host ""
        Write-Host "アラート: 合計コスト (`$$($TotalCost.ToString('F2'))) が閾値 (`$$($AlertThreshold.ToString('F2'))) を超えました。Teams に通知します..."

        $SummaryFacts = @(
            @{ title = "集計月";          value = if ($Month -ne "") { $Month } else { "直近 $DaysBack 日" } },
            @{ title = "現在の合計コスト"; value = "`$$($TotalCost.ToString('F2'))" }
        )

        $UserFacts = @()
        foreach ($User in ($UserCosts.Keys | Sort-Object)) {
            if ($UserCosts[$User] -lt 0.005) { continue }
            $UserFacts += @{ title = $User; value = "`$$($UserCosts[$User].ToString('F2'))" }
        }

        $ThresholdFacts = @(
            @{ title = "閾値（合計コスト）"; value = "`$$($AlertThreshold.ToString('F2'))" }
        )

        $Body = @{
            type        = "message"
            attachments = @(
                @{
                    contentType = "application/vnd.microsoft.card.adaptive"
                    content     = @{
                        '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                        type      = "AdaptiveCard"
                        version   = "1.2"
                        body      = @(
                            @{
                                type   = "TextBlock"
                                size   = "Medium"
                                weight = "Bolder"
                                text   = "Bedrock コスト超過アラート"
                                color  = "Attention"
                            },
                            @{
                                type  = "FactSet"
                                facts = $SummaryFacts
                            },
                            @{
                                type   = "TextBlock"
                                weight = "Bolder"
                                text   = "ユーザ毎のコスト"
                            },
                            @{
                                type  = "FactSet"
                                facts = $UserFacts
                            },
                            @{
                                type  = "FactSet"
                                facts = $ThresholdFacts
                            }
                        )
                    }
                }
            )
        } | ConvertTo-Json -Depth 10

        try {
            Invoke-RestMethod -Uri $TeamsWebhookUrl -Method Post -Body $Body -ContentType "application/json" | Out-Null
            Write-Host "Teams への通知が完了しました。"
        } catch {
            Write-Error "Teams への通知に失敗しました: $_"
        }
    }
}

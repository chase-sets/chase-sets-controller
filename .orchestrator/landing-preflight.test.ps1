[CmdletBinding()]
param(
  [ValidateSet(
    "All",
    "BreakerClearOnly",
    "DeployResolverOnly",
    "DeployCompletionOnly",
    "ExecutedUnrecognizedStaging",
    "SensitivityRequired",
    "BreakerRepairFrontierOnly",
    "Decision7643AdapterOnly",
    "ScopeAwareBreakerOnly",
    "RequiredCheckReducerOnly",
    "ContinuationOnly"
  )]
  [string]$RegressionOnly = "All"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope

$preflight = Join-Path $PSScriptRoot "landing-preflight.ps1"
$fixture = Join-Path $PSScriptRoot "landing-preflight.fixture.json"
Import-Module (Join-Path $PSScriptRoot "review-head-contract.psm1") -Force -DisableNameChecking
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("landing-preflight-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$headA = "a" * 40
$headB = "b" * 40
$repairHead = "c" * 40
$repairBase = "d" * 40

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function New-Pass([string]$Head) {
  [pscustomobject][ordered]@{
    ts = [datetimeoffset]::UtcNow.AddMinutes(-5).ToString("o")
    kind = "review-complete"
    pr = 6254
    receiptSchema = "exact-head-review-receipt/v1"
    reviewedHead = $Head
    reviewerAttempt = "review-6254-current"
    authorAttempt = "author-6254-current"
    reviewContract = "review-contract/v2"
    completeSweep = $true
    outcome = "PASS"
    model = "gpt-5.6-sol"
    authorModel = "gpt-5.6-sol"
    findingIds = [object[]]@()
    findings = [ordered]@{ blocking = 0; candidates = 0; nonBlocking = 0 }
  }
}

function New-History([object[]]$Rows) {
  $path = Join-Path $testRoot ("history-" + [guid]::NewGuid().ToString("N") + ".jsonl")
  $lines = @($Rows | ForEach-Object {
      if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Compress -Depth 6 }
    })
  [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
  $path
}

function Write-JsonFixture([string]$Name, $Value) {
  $path = Join-Path $testRoot $Name
  [IO.File]::WriteAllText(
    $path,
    ($Value | ConvertTo-Json -Compress -Depth 20),
    [Text.UTF8Encoding]::new($false)
  )
  $path
}

function New-BreakerEvent(
  [string]$Kind,
  [int]$Issue,
  [int]$PullRequest,
  [datetimeoffset]$Instant,
  [string]$Scope = "pipeline"
) {
  [pscustomobject][ordered]@{
    ts = $Instant.ToString("o")
    kind = $Kind
    issue = $Issue
    pr = $PullRequest
    breakerScope = $Scope
  }
}

function New-ProductionGraphFixture {
  [ordered]@{
    data = [ordered]@{
      repository = [ordered]@{
        pullRequest = [ordered]@{
          id = "PR_fixture_6254"
          number = 6254
          state = "OPEN"
          isDraft = $false
          headRefOid = $headA
          baseRefName = "main"
          mergeQueueEntry = $null
          baseRef = [ordered]@{
            name = "main"
            branchProtectionRule = [ordered]@{
              requiresStatusChecks = $true
              requiredStatusCheckContexts = @("PR Required")
            }
          }
          commits = [ordered]@{
            totalCount = 1
            nodes = @([ordered]@{
                commit = [ordered]@{
                  oid = $headA
                  statusCheckRollup = [ordered]@{
                    state = "SUCCESS"
                    contexts = [ordered]@{
                      totalCount = 1
                      pageInfo = [ordered]@{ hasNextPage = $false; endCursor = $null }
                      nodes = @([ordered]@{
                          __typename = "CheckRun"
                          name = "PR Required"
                          status = "COMPLETED"
                          conclusion = "SUCCESS"
                          databaseId = [long]9007199254740001
                          detailsUrl = "https://github.com/chase-sets/chase-sets/actions/runs/9007199254740001/job/9007199254740001"
                          completedAt = "2030-01-01T00:00:00Z"
                          checkSuite = [ordered]@{
                            app = [ordered]@{ databaseId = [long]9007199254740002 }
                            workflowRun = [ordered]@{
                              workflow = [ordered]@{ databaseId = [long]9007199254740003 }
                            }
                          }
                        })
                    }
                  }
                }
              })
          }
          closingIssuesReferences = [ordered]@{
            totalCount = 1
            pageInfo = [ordered]@{ hasNextPage = $false; endCursor = $null }
            nodes = @([ordered]@{
                number = 6254
                state = "OPEN"
                blockedBy = [ordered]@{
                  totalCount = 0
                  pageInfo = [ordered]@{ hasNextPage = $false; endCursor = $null }
                  nodes = @()
                }
              })
          }
        }
      }
    }
  }
}

function New-Captured7730ProductionGraphFixture {
  @'
{"data":{"repository":{"pullRequest":{"id":"PR_kwDORKgVcc8AAAABCkZIcQ","number":7730,"state":"OPEN","isDraft":false,"headRefOid":"47c44ad0235c7d0e8843974eee7583e90c9aab01","baseRefName":"main","mergeQueueEntry":null,"baseRef":{"name":"main","branchProtectionRule":{"requiresStatusChecks":true,"requiredStatusCheckContexts":["PR Required"]}},"commits":{"totalCount":3,"nodes":[{"commit":{"oid":"47c44ad0235c7d0e8843974eee7583e90c9aab01","statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":61,"pageInfo":{"hasNextPage":false,"endCursor":"NjE"},"nodes":[{"__typename":"CheckRun","name":"PR Scope (Advisory)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101864356548,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161586687/job/101864356548","completedAt":"2026-09-07T21:01:41Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":318645295}}}},{"__typename":"CheckRun","name":"PR Scope (Advisory)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101877501243,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163667768/job/101877501243","completedAt":"2026-09-07T22:17:43Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":318645295}}}},{"__typename":"CheckRun","name":"PR Scope (Advisory)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870407942,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671092/job/101870407942","completedAt":"2026-09-07T21:35:28Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":318645295}}}},{"__typename":"CheckRun","name":"Known Failure Guard","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101864470903,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864470903","completedAt":"2026-09-07T21:02:12Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Known Failure Guard","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870397977,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870397977","completedAt":"2026-09-07T21:35:17Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Discover Preview Cleanup","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870392148,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163669055/job/101870392148","completedAt":"2026-09-07T21:35:38Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":276835693}}}},{"__typename":"CheckRun","name":"Risk Review (Advisory)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101864356353,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161586696/job/101864356353","completedAt":"2026-09-07T21:01:38Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":318560891}}}},{"__typename":"CheckRun","name":"Risk Review (Advisory)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101877503285,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163667769/job/101877503285","completedAt":"2026-09-07T22:17:41Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":318560891}}}},{"__typename":"CheckRun","name":"Risk Review (Advisory)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870406602,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163670953/job/101870406602","completedAt":"2026-09-07T21:35:23Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":318560891}}}},{"__typename":"CheckRun","name":"Release Qualification Scope Advisory","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101864471708,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864471708","completedAt":"2026-09-07T21:02:08Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Release Qualification Scope Advisory","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870399023,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870399023","completedAt":"2026-09-07T21:35:13Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Discover Stale Verification Namespaces","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870392721,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163669055/job/101870392721","completedAt":"2026-09-07T21:35:11Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":276835693}}}},{"__typename":"CheckRun","name":"Scope Policy Check","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101864356250,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161586687/job/101864356250","completedAt":"2026-09-07T21:01:36Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":318645295}}}},{"__typename":"CheckRun","name":"Scope Policy Check","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101877501412,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163667768/job/101877501412","completedAt":"2026-09-07T22:17:40Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":318645295}}}},{"__typename":"CheckRun","name":"Scope Policy Check","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870407807,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671092/job/101870407807","completedAt":"2026-09-07T21:35:25Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":318645295}}}},{"__typename":"CheckRun","name":"Discover Stale Verification Webhooks","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870392758,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163669055/job/101870392758","completedAt":"2026-09-07T21:35:11Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":276835693}}}},{"__typename":"CheckRun","name":"Change Scope","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101864485563,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864485563","completedAt":"2026-09-07T21:02:29Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Change Scope","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870411028,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870411028","completedAt":"2026-09-07T21:35:39Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Discover Stale Gate Namespaces","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870392941,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163669055/job/101870392941","completedAt":"2026-09-07T21:35:11Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":276835693}}}},{"__typename":"CheckRun","name":"Static Checks","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101864538753,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864538753","completedAt":"2026-09-07T21:07:43Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Static Checks","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478303,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478303","completedAt":"2026-09-07T21:39:22Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Typecheck","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101864538791,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864538791","completedAt":"2026-09-07T21:03:22Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Typecheck","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478267,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478267","completedAt":"2026-09-07T21:36:27Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Destroy Preview (7730, main, 47c44ad0235c7d0e8843974eee7583e90c9aab01, chase-sets-pr-7730-postgres)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870475837,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163669055/job/101870475837","completedAt":"2026-09-07T21:36:26Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":276835693}}}},{"__typename":"CheckRun","name":"Destroy Stale Verification Namespace","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870393051,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163669055/job/101870393051","completedAt":"2026-09-07T21:35:11Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":276835693}}}},{"__typename":"CheckRun","name":"Unit Tests","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101864538829,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864538829","completedAt":"2026-09-07T21:11:37Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Unit Tests","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478369,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478369","completedAt":"2026-09-07T21:45:49Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Delete Stale Verification Webhooks","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870392956,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163669055/job/101870392956","completedAt":"2026-09-07T21:35:11Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":276835693}}}},{"__typename":"CheckRun","name":"DB Profile Tests","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101864538824,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864538824","completedAt":"2026-09-07T21:17:37Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"DB Profile Tests","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478292,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478292","completedAt":"2026-09-07T21:51:53Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"E2E Tests (${{ matrix.suite_batch }})","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101864539519,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864539519","completedAt":"2026-09-07T21:02:30Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Destroy Stale Gate Namespace","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870393332,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163669055/job/101870393332","completedAt":"2026-09-07T21:35:11Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":276835693}}}},{"__typename":"CheckRun","name":"E2E Tests (catalog_admin_integrations,admin_auth)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478367,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478367","completedAt":"2026-09-07T21:40:41Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"E2E Tests (catalog_admin_modeling,admin_platform)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478383,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478383","completedAt":"2026-09-07T21:41:57Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"E2E Tests (marketplace_checkout,admin_support)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478378,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478378","completedAt":"2026-09-07T21:41:24Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"E2E Tests (marketplace_browse,marketplace_account)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478349,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478349","completedAt":"2026-09-07T21:41:39Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"E2E Tests (admin_commerce,admin_access)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478414,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478414","completedAt":"2026-09-07T21:41:22Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"E2E Tests (marketplace_seller,admin_growth)","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478373,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478373","completedAt":"2026-09-07T21:40:23Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101864539441,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864539441","completedAt":"2026-09-07T21:02:30Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Report Gate Sweep Totals","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870393486,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163669055/job/101870393486","completedAt":"2026-09-07T21:35:11Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":276835693}}}},{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478398,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478398","completedAt":"2026-09-07T21:36:33Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Docker Image Build","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101864539094,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864539094","completedAt":"2026-09-07T21:02:30Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Docker Image Build","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101870478493,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870478493","completedAt":"2026-09-07T21:37:33Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Workflow Lint","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101864539098,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864539098","completedAt":"2026-09-07T21:02:30Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Workflow Lint","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870479455,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870479455","completedAt":"2026-09-07T21:35:39Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Terraform Preview Plan","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101864539393,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864539393","completedAt":"2026-09-07T21:02:30Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Terraform Preview Plan","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870479192,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870479192","completedAt":"2026-09-07T21:35:39Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Terraform Production Plan","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101864539126,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864539126","completedAt":"2026-09-07T21:02:30Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Terraform Production Plan","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870479111,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870479111","completedAt":"2026-09-07T21:35:39Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Terraform Staging Plan","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101864539616,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864539616","completedAt":"2026-09-07T21:02:30Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Terraform Staging Plan","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870479314,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870479314","completedAt":"2026-09-07T21:35:39Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Terraform Observability Plan","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101864539487,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101864539487","completedAt":"2026-09-07T21:02:30Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Terraform Observability Plan","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101870479357,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101870479357","completedAt":"2026-09-07T21:35:39Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Compose Boot Smoke / Compose Boot Smoke | target=74f2efc22acc342228301385640279759fddf711 | base=3890ed724d52fec9deab2f7cc9ff64ebfd447042 | event=pull_request | ref=refs/pull/7730/merge | trigger=74f2efc22acc342228301385640279759fddf711","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101866220037,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101866220037","completedAt":"2026-09-07T21:17:51Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Compose Boot Smoke / Compose Boot Smoke | target=74f2efc22acc342228301385640279759fddf711 | base=3890ed724d52fec9deab2f7cc9ff64ebfd447042 | event=pull_request | ref=refs/pull/7730/merge | trigger=74f2efc22acc342228301385640279759fddf711","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101872166467,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101872166467","completedAt":"2026-09-07T21:50:33Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Deploy Preview and Smoke","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101867323205,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101867323205","completedAt":"2026-09-07T21:17:38Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"Deploy Preview and Smoke","status":"COMPLETED","conclusion":"SKIPPED","databaseId":101873180823,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101873180823","completedAt":"2026-09-07T21:51:53Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"PR Required","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101867362343,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101867362343","completedAt":"2026-09-07T21:17:58Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"PR Required","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101873180043,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101873180043","completedAt":"2026-09-07T21:51:57Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"PR Release Status","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101867382518,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34161589249/job/101867382518","completedAt":"2026-09-07T21:18:09Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}},{"__typename":"CheckRun","name":"PR Release Status","status":"COMPLETED","conclusion":"SUCCESS","databaseId":101873192943,"detailsUrl":"https://github.com/chase-sets/chase-sets/actions/runs/34163671068/job/101873192943","completedAt":"2026-09-07T21:52:09Z","checkSuite":{"app":{"databaseId":15368},"workflowRun":{"workflow":{"databaseId":274293632}}}}]}}}}]},"closingIssuesReferences":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":"MQ"},"nodes":[{"number":7182,"state":"OPEN","blockedBy":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":"MQ"},"nodes":[{"number":7179,"state":"CLOSED"}]}}]}}}}}
'@ | ConvertFrom-Json -AsHashtable -DateKind String
}

function New-RealDeployRunFixture {
  # Every fact below was measured from the immutable GitHub run on 2026-07-29.
  @(
    [ordered]@{ conclusion = "success"; createdAt = "2026-07-29T03:40:44Z"; databaseId = [long]30420209472; headSha = "15296711f65048549bf29ad86255d4b8032e774a"; status = "completed" }
    [ordered]@{ conclusion = "success"; createdAt = "2026-07-29T03:40:35Z"; databaseId = [long]30420203201; headSha = "15296711f65048549bf29ad86255d4b8032e774a"; status = "completed" }
    [ordered]@{ conclusion = "failure"; createdAt = "2026-07-29T02:24:53Z"; databaseId = [long]30416763775; headSha = "27b0e1277cffe9a02be84dc633ac2ec92283b44e"; status = "completed" }
    [ordered]@{ conclusion = "failure"; createdAt = "2026-07-29T02:24:05Z"; databaseId = [long]30416729203; headSha = "27b0e1277cffe9a02be84dc633ac2ec92283b44e"; status = "completed" }
    [ordered]@{ conclusion = "failure"; createdAt = "2026-07-29T00:24:35Z"; databaseId = [long]30411058671; headSha = "1fa28b8f485b9ffe13c07bf3839896c1ac0ed06f"; status = "completed" }
    [ordered]@{ conclusion = "failure"; createdAt = "2026-07-29T00:16:22Z"; databaseId = [long]30410644170; headSha = "1fa28b8f485b9ffe13c07bf3839896c1ac0ed06f"; status = "completed" }
    [ordered]@{ conclusion = "failure"; createdAt = "2026-07-28T23:21:51Z"; databaseId = [long]30407738821; headSha = "1fa28b8f485b9ffe13c07bf3839896c1ac0ed06f"; status = "completed" }
    [ordered]@{ conclusion = "failure"; createdAt = "2026-07-28T20:26:20Z"; databaseId = [long]30396324956; headSha = "be16f0104c8648cd62d9be3b7ff4cbb0f3a6e350"; status = "completed" }
    [ordered]@{ conclusion = "success"; createdAt = "2026-07-28T18:37:11Z"; databaseId = [long]30388252580; headSha = "c0bd688d64bd5140fcbd2790489717a042e5432b"; status = "completed" }
    [ordered]@{ conclusion = "success"; createdAt = "2026-07-28T16:57:22Z"; databaseId = [long]30380662449; headSha = "699ab487a4bf1f63446ef885d84515978e95cd7a"; status = "completed" }
  )
}

function New-MinimizedJob([string]$Name) {
  [ordered]@{ name = $Name }
}

function New-SyntheticDeployRun(
  [long]$RunId,
  [string]$CreatedAt,
  [string]$Status = "completed",
  [AllowNull()][string]$Conclusion = "success"
) {
  [ordered]@{
    conclusion = $Conclusion
    createdAt = $CreatedAt
    databaseId = $RunId
    headSha = "9999999999999999999999999999999999999999"
    status = $Status
  }
}

function New-SyntheticStagingJobs(
  [long]$JobId,
  [string]$Status,
  [AllowNull()][string]$Conclusion,
  [int]$StepCount
) {
  [ordered]@{
    total_count = 1
    jobs = @([ordered]@{
        id = $JobId
        name = "Deploy Staging"
        status = $Status
        conclusion = $Conclusion
        steps = @($(if ($StepCount -gt 0) {
              1..$StepCount | ForEach-Object { [ordered]@{ number = $_ } }
            }))
      })
  }
}

function Set-DeployFixtures($Runs, [hashtable]$JobsByRun) {
  $env:LANDING_PREFLIGHT_MOCK_RUNS = Write-JsonFixture `
    ("runs-" + [guid]::NewGuid().ToString("N") + ".json") $Runs
  foreach ($entry in $JobsByRun.GetEnumerator()) {
    $name = "LANDING_PREFLIGHT_MOCK_JOBS_$($entry.Key)"
    $value = if ($entry.Value -is [string] -and $entry.Value -ceq "FAIL") {
      "FAIL"
    } else {
      Write-JsonFixture ("jobs-$($entry.Key)-" + [guid]::NewGuid().ToString("N") + ".json") $entry.Value
    }
    [Environment]::SetEnvironmentVariable($name, $value, "Process")
  }
}

function Set-RealDeployJobFixtures {
  $resolverOnlyNames = @(
    "Resolve Release",
    "App Platform Decommission Live Plans",
    "Build Release Image",
    'Preflight Deployment Contract (${{ matrix.environment }})',
    "Deploy Production",
    "Notify Staging Advisory Dispatch Failure",
    "Close Resolved Production Deploy Incidents",
    "Notify Production Rollback Incident",
    "Record Staging Release Health",
    "Notify Production Deploy Incident"
  )
  $resolverJobs = @($resolverOnlyNames | ForEach-Object { New-MinimizedJob $_ })
  $resolverJobs += [ordered]@{
    id = [long]90477275397
    name = "Deploy Staging"
    status = "completed"
    conclusion = "skipped"
    started_at = "2026-07-29T03:56:10Z"
    completed_at = "2026-07-29T03:56:10Z"
    steps = @()
  }
  $env:LANDING_PREFLIGHT_MOCK_JOBS_30420209472 = Write-JsonFixture "jobs-30420209472.json" ([ordered]@{
      total_count = 11
      jobs = @($resolverJobs)
    })

  $deployNames = @(
    "Resolve Release",
    "App Platform Decommission Live Plans",
    "Preflight Deployment Contract (production)",
    "Preflight Deployment Contract (staging)",
    "Build Release Image",
    "Deploy Production",
    "Notify Staging Advisory Dispatch Failure",
    "Close Resolved Production Deploy Incidents",
    "Notify Production Rollback Incident",
    "Record Staging Release Health",
    "Notify Production Deploy Incident"
  )
  $deployJobs = @($deployNames | ForEach-Object { New-MinimizedJob $_ })
  $measuredStepNumbers = @(1..54) + @(105..109)
  $deployJobs += [ordered]@{
    id = [long]90475766694
    name = "Deploy Staging"
    status = "completed"
    conclusion = "success"
    started_at = "2026-07-29T03:44:35Z"
    completed_at = "2026-07-29T03:50:38Z"
    steps = @($measuredStepNumbers | ForEach-Object { [ordered]@{ number = $_ } })
  }
  $env:LANDING_PREFLIGHT_MOCK_JOBS_30420203201 = Write-JsonFixture "jobs-30420203201.json" ([ordered]@{
      total_count = 12
      jobs = @($deployJobs)
    })
}

function Set-ScopeProviderFixtures(
  [long]$JobId,
  [long]$RunId,
  [string]$Head,
  [bool]$Deploy,
  [string[]]$ChangedFiles,
  [AllowNull()][object]$JobRunAttempt = 1,
  [AllowNull()][object]$RunAttempt = 1
) {
  $job = [ordered]@{
    id = $JobId
    run_id = $RunId
    name = "Change Scope"
    status = "completed"
    conclusion = "success"
    head_sha = $Head
    started_at = '2030-01-01T00:00:00Z'
    completed_at = '2030-01-01T00:00:01Z'
    steps = @([ordered]@{
        name = 'Resolve changed surface'; number = 4; status = 'completed'; conclusion = 'success'
        started_at = '2030-01-01T00:00:00Z'; completed_at = '2030-01-01T00:00:00Z'
      })
    html_url = "https://github.com/chase-sets/chase-sets/actions/runs/$RunId/job/$JobId"
  }
  if ($null -ne $JobRunAttempt) { $job.run_attempt = $JobRunAttempt }
  $run = [ordered]@{
    id = $RunId
    event = "pull_request"
    status = "completed"
    conclusion = "success"
    path = ".github/workflows/platform-pr.yml"
    run_attempt = $RunAttempt
    head_sha = $Head
    pull_requests = @([ordered]@{
        number = 6254
        head = [ordered]@{ sha = $Head }
      })
  }
  $output = [ordered]@{
    changed_files_json = ConvertTo-Json -InputObject ([object[]]$ChangedFiles) -Compress
    affected_workspaces = ""
    affected_workspaces_json = "[]"
    directly_affected_workspaces_json = "[]"
    docs_only = "true"
    local_checks = "true"
    unit_tests = "false"
    db_tests = "false"
    e2e_tests = "false"
    e2e_suites = ""
    e2e_suites_json = "[]"
    e2e_suite_batches_json = "[]"
    integration_risk_required = "false"
    integration_risk_reason = "No integration-risk change detected"
    build = "false"
    docker_image = "false"
    terraform = "false"
    workflow_lint = "false"
    deploy = $(if ($Deploy) { "true" } else { "false" })
    cluster_preview = "false"
    compose_smoke = "false"
    exposure_posture_changed = "false"
    exposure_posture_categories = ""
    exposure_posture_categories_json = "[]"
  }
  $outputLines = ($output | ConvertTo-Json -Depth 10) -split "`r?`n"
  $log = @($outputLines | ForEach-Object { "2030-01-01T00:00:00.0000000Z $_" }) -join "`n"
  $jobPath = Write-JsonFixture "scope-job-$JobId.json" $job
  $runPath = Write-JsonFixture "scope-run-$RunId.json" $run
  $logPath = Join-Path $testRoot "scope-log-$JobId.txt"
  [IO.File]::WriteAllText($logPath, $log, [Text.UTF8Encoding]::new($false))
  [Environment]::SetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_SCOPE_JOB_$JobId", $jobPath, "Process")
  [Environment]::SetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_SCOPE_RUN_$RunId", $runPath, "Process")
  [Environment]::SetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_SCOPE_LOG_$JobId", $logPath, "Process")
}

function ConvertTo-ScopeTestLog($Map) {
  ConvertTo-Json -InputObject $Map -Depth 32
}

function Get-ScopeTestFunction([string]$Name) {
  $definitions = @($productionAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
      }, $true))
  Assert-True ($definitions.Count -eq 1) "scope function inventory $Name"
  $definitions[0].Extent.Text
}

function Invoke-ScopeParserMutant([string]$Name, [string]$Function, [string]$Before, [string]$After, [string]$Log, [int]$ExpectedCount) {
  $original = Get-ScopeTestFunction $Function
  Assert-True ($original.Contains($Before, [StringComparison]::Ordinal)) "mutant $Name reaches its intended source clause"
  & {
    . ([scriptblock]::Create($original.Replace($Before, $After)))
    $maps = [object[]]@(Get-ChangeScopeOutputMaps $Log)
    Assert-True ($maps.Count -eq $ExpectedCount) "named mutant $Name must expose the bypass (actual=$($maps.Count))"
  }
  Write-Output "KILLED scope mutant=$Name intended-clause=$Function"
}

function Test-NativeCurrentScopeOutput {
  # Replay byte-identical historical captures, never the live controller fleet.
  $captureRoot = Join-Path $PSScriptRoot 'fixtures/landing-preflight-native-scope'
  $nativePath = Join-Path $captureRoot 'goal-7969-change-scope-native-r1.log'
  $journalPath = Join-Path $captureRoot 'goal-7969-direct-enqueue-r1.json'
  Assert-True ((Get-FileHash $nativePath -Algorithm SHA256).Hash -ieq 'd22668fb8401274cf5921464d7269fcb0e58c94ad22947673178b43ca856203d') 'untouched native log hash'
  Assert-True ((Get-FileHash $journalPath -Algorithm SHA256).Hash -ieq 'a2c737287e6b0b06f5f1fb5d24d7e306ca4eb74ff447f80a0565a3c8ef75bcba') 'untouched native journal hash'
  $nativeLog = [IO.File]::ReadAllText($nativePath)
  $native = [object[]]@(Get-ChangeScopeOutputMaps $nativeLog)
  Assert-True ($native.Count -eq 1 -and $native[0].value.deploy -ceq 'false' -and
    $native[0].changedFiles -is [string[]] -and $native[0].changedFiles.Count -eq 2 -and
    $native[0].changedFiles[0] -ceq 'scripts/verify-ci-local.mjs' -and
    $native[0].changedFiles[1] -ceq 'scripts/verify-ci-local.test.mjs') 'native-current-and-legacy-output: native exact map'
  $journal = Get-Content $journalPath -Raw | ConvertFrom-Json -DateKind String
  $nativeSteps = @($journal.scopeJob.steps | Where-Object name -CEQ 'Resolve changed surface')
  Assert-True ($nativeSteps.Count -eq 1 -and $nativeSteps[0].status -ceq 'completed' -and
    $nativeSteps[0].conclusion -ceq 'success' -and $nativeSteps[0].number -eq 4 -and
    $nativeSteps[0].started_at -ceq '2026-09-13T11:14:24Z' -and
    $nativeSteps[0].completed_at -ceq $nativeSteps[0].started_at) 'untouched native equal-second job facts; full collector NOT_RETAINED'
  foreach ($retired in @('Get-ChangeScopeSuiteBatches', 'Test-CurrentChangeScopeMap', 'Test-ChangeScopeOwningStep')) {
    $nodes = @($productionAst.FindAll({ param($node)
        ($node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $retired) -or
        ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $retired)
      }, $true))
    Assert-True ($nodes.Count -eq 0) "retired one-caller helper absent: $retired"
  }
  Write-Output 'PASS scope-owner-AST retiredHelpers=3 definitions=0 productionCalls=0'
  $current = $native[0].value
  $legacy = Copy-TestValue $current
  $legacy.Remove('scope_json')
  $legacyLog = ConvertTo-ScopeTestLog $legacy
  Assert-True (@(Get-ChangeScopeOutputMaps $legacyLog).Count -eq 1) 'legacy map retained'
  # Exact governing F1 reproduction, using only the untouched native parser input.
  $malformedRaw = '{"\u0073cope_json": broken}'
  $observed = @(Get-ChangeScopeOutputMaps ($malformedRaw + "`n" + $legacyLog))
  Assert-True ($legacy.Count -eq 24 -and $observed.Count -eq 0) 'F1 native-derived escaped malformed key cannot downgrade'
  Write-Output (ConvertTo-Json -Compress -InputObject ([ordered]@{
      probe='escaped-scope-key-malformed-candidate-plus-native-derived-legacy'
      nativeSha256=(Get-FileHash $nativePath -Algorithm SHA256).Hash.ToLowerInvariant()
      nativeMapCount=$native.Count; legacyKeyCount=$legacy.Count; malformedRaw=$malformedRaw
      observedMapCount=$observed.Count; requiredMapCount=0
    }))
  $escapedKeys = @('\u0073cope_json', 'sco\u0070e_jso\u006e', 'scope\u005Fjson')
  foreach ($key in $current.Keys) {
    $escapedKeys += (@($key.ToCharArray() | ForEach-Object { '\u{0:x4}' -f [int]$_ }) -join '')
  }
  foreach ($escapedKey in $escapedKeys) {
    foreach ($valid in @($legacyLog, (ConvertTo-ScopeTestLog $current))) {
      $malformed = '{"' + $escapedKey + '": broken}'
      Assert-True (@(Get-ChangeScopeOutputMaps ($malformed + "`n" + $valid)).Count -eq 0) "escaped malformed key before valid legacy/current: $escapedKey"
    }
  }
  Assert-True (@(Get-ChangeScopeOutputMaps ('{"plan_json":"{}"}' + "`n" + $legacyLog)).Count -eq 1) 'F1 unrelated native-derived legacy control'
  Write-Output "PASS malformed-escaped-scope-keys keySpellings=$($escapedKeys.Count) formatPairs=2 maps=0 benignPlanMaps=1"

  $legacyOdd = Copy-TestValue $legacy
  $legacyOdd.docs_only = 'legacy accepted arbitrary string'
  $legacyOdd.e2e_suites_json = 'legacy accepted non-JSON string'
  Assert-True (@(Get-ChangeScopeOutputMaps (ConvertTo-ScopeTestLog $legacyOdd)).Count -eq 1) 'legacy accepted value rules are unchanged'

  # Execute the exact pinned producer functions inside this admitted carrier.
  # No checkout dependency, provider call, classifier guess, or alternate gate.
  $pin = '2d77c295802c06eb73543a2010babe5d02392fb7'
  $mapperPath = Join-Path $captureRoot 'change-scope.mjs'
  $batcherPath = Join-Path $captureRoot 'e2e-suites.mjs'
  $mapperBlob = & git hash-object --no-filters -- $mapperPath
  Assert-True ($LASTEXITCODE -eq 0 -and $mapperBlob -ceq 'bb07241ebd9865a9753e057f652a514bf3c38fbe') 'pinned mapper fixture matches source object'
  $batcherBlob = & git hash-object --no-filters -- $batcherPath
  Assert-True ($LASTEXITCODE -eq 0 -and $batcherBlob -ceq '8053964a17a554f2c52e9c046f44b84299deaf05') 'pinned batching fixture matches source object'
  $mapper = [IO.File]::ReadAllText($mapperPath)
  $batcher = [IO.File]::ReadAllText($batcherPath)
  $parts = [Collections.Generic.List[string]]::new()
  $parts.Add('import fs from "node:fs";')
  foreach ($name in @('toOutputMap', 'toGithubOutputMap')) {
    $match = [regex]::Match($mapper, "(?ms)^export function $name\(.*?^}")
    Assert-True $match.Success "exact producer function $name"
    $parts.Add($match.Value)
  }
  $registry = [regex]::Match($batcher, '(?ms)^export const e2eSuites = Object.freeze\(\[.*?^\]\);')
  Assert-True $registry.Success 'exact producer suite registry'
  $parts.Add($registry.Value)
  foreach ($name in @('suiteOrder', 'suitesById', 'defaultSuiteBatchSize', 'fallbackEstimatedSuiteDurationSeconds')) {
    $match = [regex]::Match($batcher, "(?m)^const $name = .*;$")
    Assert-True $match.Success "exact batching dependency $name"
    $parts.Add($match.Value)
  }
  foreach ($name in @('orderE2eSuiteIds', 'batchE2eSuiteIds', 'e2eSuiteById', 'estimatedE2eSuiteDurationSeconds')) {
    $match = [regex]::Match($batcher, "(?ms)^export function $name\(.*?^}")
    Assert-True $match.Success "exact producer function $name"
    $parts.Add($match.Value)
  }
  $inputPath = Write-JsonFixture 'scope-producer-input.json' (ConvertFrom-Json -InputObject $current.scope_json -AsHashtable)
  $parts.Add(@'
const seed = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const cases = [];
for (const size of [0, 1, 3]) {
  const scope = structuredClone(seed);
  for (const key of Object.keys(scope)) {
    if (Array.isArray(scope[key])) scope[key] = Array.from({length:size}, (_, i) => `${key}-${i}-é\\quote\"`);
    else if (typeof scope[key] === "boolean") scope[key] = size !== 0;
    else scope[key] = "synthetic reason é";
  }
  scope.e2eSuiteIds = e2eSuites.slice(0, size).map(s => s.id);
  cases.push(toGithubOutputMap(scope));
}
const batches = [];
for (let mask = 0; mask < (1 << e2eSuites.length); mask += 37) {
  const ids = e2eSuites.filter((_, i) => mask & (1 << i)).map(s => s.id).reverse();
  batches.push({ids, expected:batchE2eSuiteIds(ids), map:toGithubOutputMap({...seed,e2eSuiteIds:ids})});
}
for (const ids of [e2eSuites.map(s=>s.id), ["unknown-z","admin_growth","unknown-a","marketplace_seller","unknown-z"], ["admin_support","admin_platform"], ["marketplace_browse"]]) {
  batches.push({ids, expected:batchE2eSuiteIds(ids), map:toGithubOutputMap({...seed,e2eSuiteIds:ids})});
}
console.log(JSON.stringify({cases,batches,fields:Object.keys(seed),outputs:Object.keys(toOutputMap(seed))}));
'@)
  $producerPath = Join-Path $testRoot 'scope-producer-parity.mjs'
  [IO.File]::WriteAllText($producerPath, ($parts -join "`n"), [Text.UTF8Encoding]::new($false))
  $producerRaw = & node $producerPath $inputPath
  Assert-True ($LASTEXITCODE -eq 0) 'source-derived mapper/batch parity process exit zero'
  $producer = $producerRaw | ConvertFrom-Json -AsHashtable -Depth 32
  $classifyReturn = [regex]::Match($mapper, '(?ms)^  return \{\n    changedFiles: normalizedFiles,.*?^  \};')
  Assert-True $classifyReturn.Success 'source-derived classifyChanges return inventory'
  $fields = @([regex]::Matches($classifyReturn.Value, '(?m)^    ([A-Za-z][A-Za-z0-9]*)(?=[:,])') | ForEach-Object { $_.Groups[1].Value })
  Assert-True ((@($fields | Sort-Object) -join ',') -ceq (@($producer.fields | Sort-Object) -join ',')) 'full classifyChanges field partition matches scope schema'
  Assert-True ($producer.outputs.Count -eq $legacy.Count) 'all producer output members retained'
  foreach ($map in $producer.cases) {
    $parsed = @(Get-ChangeScopeOutputMaps (ConvertTo-ScopeTestLog $map))
    $scope = ConvertFrom-Json -InputObject $map.scope_json -AsHashtable
    Assert-True ($parsed.Count -eq 1 -and $parsed[0].changedFiles -is [string[]] -and
      $parsed[0].changedFiles.Count -eq $scope.changedFiles.Count) 'current deploy true/false and typed 0/1/N source-derived map'
  }
  foreach ($case in $producer.batches) {
    $parsed = @(Get-ChangeScopeOutputMaps (ConvertTo-ScopeTestLog $case.map))
    Assert-True ($parsed.Count -eq 1 -and
      (ConvertTo-CanonicalJson (ConvertFrom-Json -InputObject $parsed[0].value.e2e_suite_batches_json -NoEnumerate)) -ceq
      (ConvertTo-CanonicalJson $case.expected)) 'source-derived e2e batch order/duration/size/tie/dedup/fallback parity through parser'
    $wrongBatch = Copy-TestValue $case.map; $wrongBatch.e2e_suite_batches_json = '["synthetic-wrong-batch"]'
    Assert-True (@(Get-ChangeScopeOutputMaps (ConvertTo-ScopeTestLog $wrongBatch)).Count -eq 0) 'source-derived batch mismatch refused through parser'
  }
  Write-Output "PASS native-current-and-legacy-output source=$pin mappingFields=$($fields.Count) mappedOutputs=$($producer.outputs.Count) batchVectors=$($producer.batches.Count) native-full-run=NOT_RETAINED"

  $current = Copy-TestValue $producer.cases[0]
  $legacy = Copy-TestValue $current
  $legacy.Remove('scope_json')
  $legacyLog = ConvertTo-ScopeTestLog $legacy
  $negativeLogs = [Collections.Generic.List[object]]::new()
  foreach ($key in $legacy.Keys) {
    $missingLegacy = Copy-TestValue $legacy; $missingLegacy.Remove($key)
    Assert-True (@(Get-ChangeScopeOutputMaps (ConvertTo-ScopeTestLog $missingLegacy)).Count -eq 0) "legacy required member $key"
  }
  foreach ($key in $current.Keys) {
    $missing = Copy-TestValue $current; $missing.Remove($key)
    if ($key -cne 'scope_json') { $negativeLogs.Add(@{name="missing-output-$key"; log=(ConvertTo-ScopeTestLog $missing)}) }
    $wrong = Copy-TestValue $current; $wrong[$key] = 42
    $negativeLogs.Add(@{name="wrong-output-type-$key"; log=(ConvertTo-ScopeTestLog $wrong)})
    $mismatch = Copy-TestValue $current; $mismatch[$key] = 'mismatch'
    $negativeLogs.Add(@{name="mapped-equality-$key"; log=(ConvertTo-ScopeTestLog $mismatch)})
  }
  $scopeSeed = ConvertFrom-Json -InputObject $current.scope_json -AsHashtable
  foreach ($key in $scopeSeed.Keys) {
    foreach ($mode in @('missing', 'null', 'wrong-type')) {
      $scope = Copy-TestValue $scopeSeed
      if ($mode -ceq 'missing') { $scope.Remove($key) }
      elseif ($mode -ceq 'null') { $scope[$key] = $null }
      else { $scope[$key] = $(if ($scopeSeed[$key] -is [string]) { 42 } else { 'wrong' }) }
      $map = Copy-TestValue $current; $map.scope_json = ConvertTo-Json -InputObject $scope -Depth 32 -Compress
      $negativeLogs.Add(@{name="$mode-scope-$key"; log=(ConvertTo-ScopeTestLog $map)})
    }
    if ($scopeSeed[$key] -is [Array]) {
      foreach ($badItem in @(42, $true, @{ nested = 'bad' })) {
        $scope = Copy-TestValue $scopeSeed; $scope[$key] = @($badItem)
        $map = Copy-TestValue $current; $map.scope_json = ConvertTo-Json -InputObject $scope -Depth 32 -Compress
        $negativeLogs.Add(@{name="array-element-scope-$key"; log=(ConvertTo-ScopeTestLog $map)})
      }
    }
  }
  $extra = Copy-TestValue $current; $extra.unknown = 'extra'
  $extraLog = ConvertTo-ScopeTestLog $extra
  $invalidScope = Copy-TestValue $current; $invalidScope.scope_json = '{'
  $invalidLog = ConvertTo-ScopeTestLog $invalidScope
  $scopeExtra = Copy-TestValue $current; $scopeExtra.scope_json = $current.scope_json.Insert(1, '"unknown":true,')
  $scopeDuplicate = Copy-TestValue $current; $scopeDuplicate.scope_json = $current.scope_json.Insert(1, '"deployRequired":false,')
  $duplicateLog = (ConvertTo-ScopeTestLog $current).Insert(1, '"deploy":"false",')
  foreach ($entry in @(
      @{name='extra-output';log=$extraLog}, @{name='invalid-scope-json';log=$invalidLog},
      @{name='unknown-scope';log=(ConvertTo-ScopeTestLog $scopeExtra)},
      @{name='duplicate-scope';log=(ConvertTo-ScopeTestLog $scopeDuplicate)},
      @{name='duplicate-output';log=$duplicateLog},
      @{name='invalid-json';log=(ConvertTo-ScopeTestLog $current).Replace('"deploy": "false"', '"deploy": false broken')},
      @{name='truncated';log=(ConvertTo-ScopeTestLog $current).TrimEnd().TrimEnd('}')}
    )) { $negativeLogs.Add($entry) }
  foreach ($entry in $negativeLogs) {
    Assert-True (@(Get-ChangeScopeOutputMaps $entry.log).Count -eq 0) "closed-current-scope-consistency $($entry.name)"
    Assert-True (@(Get-ChangeScopeOutputMaps ($entry.log + "`n" + $legacyLog)).Count -eq 0) "invalidcandidate-not-hidden $($entry.name)"
  }
  Assert-True (@(Get-ChangeScopeOutputMaps ($legacyLog + "`n" + (ConvertTo-ScopeTestLog $current))).Count -eq 2) 'mixed legacy/current remains ambiguous'
  Assert-True (@(Get-ChangeScopeOutputMaps ((ConvertTo-ScopeTestLog $current) + "`n" + (ConvertTo-ScopeTestLog $current))).Count -eq 2) 'duplicate current maps remain ambiguous'
  Assert-True (@(Get-ChangeScopeOutputMaps ('{"plan_json":"{}"}' + "`n" + $legacyLog)).Count -eq 1) 'unrelated gate plan benign'
  Invoke-ScopeParserMutant 'legacy-only-keyset' 'Get-ChangeScopeOutputMaps' "if (`$current) { `$expectedKeys += 'scope_json' }" 'if ($false) { $expectedKeys += ''scope_json'' }' $nativeLog 0
  Invoke-ScopeParserMutant 'drop-legacy-shape' 'Get-ChangeScopeOutputMaps' "if (`$current) { `$expectedKeys += 'scope_json' }" "`$expectedKeys += 'scope_json'" $legacyLog 0
  Invoke-ScopeParserMutant 'allow-extra-key' 'Get-ChangeScopeOutputMaps' 'Test-ExactKeys $candidate $expectedKeys' '$true' $extraLog 1
  Invoke-ScopeParserMutant 'ignore-scope-json' 'Get-ChangeScopeOutputMaps' 'if ($current -eq $true) {' 'if ($false) {' $invalidLog 1
  Invoke-ScopeParserMutant 'last-key-wins' 'ConvertFrom-ClosedJson' '-not (Test-JsonTokenClosure $document.RootElement)' '$false' $duplicateLog 1
  $mismatch = Copy-TestValue $current; $mismatch.local_checks = 'true'
  Assert-True (@(Get-ChangeScopeOutputMaps (ConvertTo-ScopeTestLog $mismatch)).Count -eq 0) 'mapped equality mutant negative reaches current-map equality'
  Invoke-ScopeParserMutant 'skip-mapped-field-equality' 'Get-ChangeScopeOutputMaps' '$candidate[$key] -cne $expected[$key]' '$false' (ConvertTo-ScopeTestLog $mismatch) 1
  Invoke-ScopeParserMutant 'discard-invalid-scope-candidate' 'Get-ChangeScopeOutputMaps' 'if ($invalidCandidate)' 'if ($false)' ($invalidLog + "`n" + $legacyLog) 1
  Write-Output "PASS closed-current-scope-consistency one-variable-negatives=$($negativeLogs.Count) malformed-current-no-downgrade invalidcandidate-not-hidden"
  $script:scopeParityMaps = $producer.cases
}

function Invoke-ScopeCollectorControl($Job, $Run, $Check, [string]$Log, [string]$Function = '', [string]$Before = '', [string]$After = '') {
  & {
    $Pr = 9007972
    $Repository = 'synthetic-7972/synthetic-7972'
    if ($Function) {
      $original = Get-ScopeTestFunction $Function
      Assert-True ($original.Contains($Before, [StringComparison]::Ordinal)) "collector mutant reaches intended $Function clause"
      . ([scriptblock]::Create($original.Replace($Before, $After)))
    }
    function Invoke-GhRestJson([string[]]$Arguments) {
      $value = if ($Arguments[0] -like '*/jobs/*') { $Job } else { $Run }
      [pscustomobject]@{ complete = $true; value = $value }
    }
    function Invoke-ExternalProcess($Command, $Arguments) {
      [pscustomobject]@{ exitCode = 0; stdout = $Log; stderr = '' }
    }
    Get-HostedChangeScopeObservation $headA @($Check)
  }
}

function Test-SyntheticScopeCollector {
  $jobId = [long]8007199254797972
  $runId = [long]9007199254797972
  $url = "https://github.com/synthetic-7972/synthetic-7972/actions/runs/$runId/job/$jobId"
  $check = [pscustomobject]@{ databaseId = $jobId; status = 'COMPLETED'; conclusion = 'SUCCESS'; detailsUrl = $url }
  $job = [ordered]@{
    id = $jobId; run_id = $runId; name = 'Change Scope'; status = 'completed'; conclusion = 'success'
    html_url = $url; head_sha = $headA; run_attempt = 1
    started_at = '2030-01-01T00:00:00Z'; completed_at = '2030-01-01T00:00:02Z'
    steps = @([ordered]@{ name = 'Resolve changed surface'; number = 4; status = 'completed'; conclusion = 'success'
        started_at = '2030-01-01T00:00:01Z'; completed_at = '2030-01-01T00:00:01Z' })
  }
  $run = [pscustomobject]@{ id = $runId; event = 'pull_request'; status = 'completed'; conclusion = 'success'
    path = '.github/workflows/platform-pr.yml'; head_sha = $headA; run_attempt = 1
    pull_requests = @([pscustomobject]@{number=9007972;head=[pscustomobject]@{sha=$headA}}) }
  $log = ConvertTo-ScopeTestLog $script:scopeParityMaps[0]
  $positive = Invoke-ScopeCollectorControl $job $run $check $log
  Assert-True ($positive.proven -eq $true -and $positive.classification -ceq 'non-deployable' -and
    $positive.evidence.changedFiles -is [string[]] -and $positive.evidence.changedFiles.Count -eq 0) 'owning-scope-step-required synthetic full collector positive'
  $cases = @(
    @{name='missing-steps';change={param($j,$r,$c) $j.Remove('steps')};reason='STEP_INCOMPLETE'},
    @{name='object-steps';change={param($j,$r,$c) $j.steps=$j.steps[0]};reason='STEP_INCOMPLETE'},
    @{name='absent-owning';change={param($j,$r,$c) $j.steps=@()};reason='STEP_INCOMPLETE'},
    @{name='duplicate-owning';change={param($j,$r,$c) $j.steps+=Copy-TestValue $j.steps[0]};reason='STEP_INCOMPLETE'},
    @{name='wrong-name';change={param($j,$r,$c) $j.steps[0].name='resolve changed surface'};reason='STEP_INCOMPLETE'},
    @{name='skipped';change={param($j,$r,$c) $j.steps[0].conclusion='skipped'};reason='STEP_INCOMPLETE'},
    @{name='red';change={param($j,$r,$c) $j.steps[0].conclusion='failure'};reason='STEP_INCOMPLETE'},
    @{name='unexecuted';change={param($j,$r,$c) $j.steps[0].status='queued'};reason='STEP_INCOMPLETE'},
    @{name='number-string';change={param($j,$r,$c) $j.steps[0].number='4'};reason='STEP_INCOMPLETE'},
    @{name='number-zero';change={param($j,$r,$c) $j.steps[0].number=0};reason='STEP_INCOMPLETE'},
    @{name='missing-time';change={param($j,$r,$c) $j.steps[0].Remove('started_at')};reason='STEP_INCOMPLETE'},
    @{name='unbounded-time';change={param($j,$r,$c) $j.steps[0].completed_at='2030-01-01T00:00:03Z'};reason='STEP_INCOMPLETE'},
    @{name='reversed-time';change={param($j,$r,$c) $j.steps[0].started_at='2030-01-01T00:00:02Z'};reason='STEP_INCOMPLETE'},
    @{name='unzoned-time';change={param($j,$r,$c) $j.steps[0].started_at='2030-01-01T00:00:01'};reason='STEP_INCOMPLETE'},
    @{name='date-only';change={param($j,$r,$c) $j.steps[0].started_at='2030-01-01'};reason='STEP_INCOMPLETE'},
    @{name='malformed-time';change={param($j,$r,$c) $j.steps[0].completed_at='2030-19-01T00:00:01Z'};reason='STEP_INCOMPLETE'},
    @{name='job-time-null';change={param($j,$r,$c) $j.started_at=$null};reason='STEP_INCOMPLETE'},
    @{name='job-head';change={param($j,$r,$c) $j.head_sha=$headB};reason='HEAD_MISMATCH'},
    @{name='run-head';change={param($j,$r,$c) $r.head_sha=$headB};reason='HEAD_MISMATCH'},
    @{name='attempt';change={param($j,$r,$c) $j.run_attempt=2};reason='ATTEMPT_MISMATCH'},
    @{name='run-attempt';change={param($j,$r,$c) $r.run_attempt=2};reason='ATTEMPT_MISMATCH'},
    @{name='run-pr';change={param($j,$r,$c) $r.pull_requests[0].number=9007973};reason='HEAD_MISMATCH'},
    @{name='pr-head';change={param($j,$r,$c) $r.pull_requests[0].head.sha=$headB};reason='HEAD_MISMATCH'},
    @{name='post-merge-empty';change={param($j,$r,$c) $r.pull_requests=@()};reason='PULL_REQUEST_COUNT_MISMATCH'},
    @{name='duplicate-pr';change={param($j,$r,$c) $r.pull_requests+=Copy-TestValue $r.pull_requests[0]};reason='PULL_REQUEST_COUNT_MISMATCH'},
    @{name='malformed-pr';change={param($j,$r,$c) $r.pull_requests=$null};reason='PULL_REQUESTS_MALFORMED'},
    @{name='job-id';change={param($j,$r,$c) $j.id++};reason='JOB_MISMATCH'},
    @{name='run-id';change={param($j,$r,$c) $r.id++};reason='RUN_MISMATCH'},
    @{name='check-id';change={param($j,$r,$c) $c.databaseId++};reason='CHECK_IDENTITY_INVALID'},
    @{name='check-status';change={param($j,$r,$c) $c.status='IN_PROGRESS'};reason='CHECK_INCOMPLETE'}
  )
  foreach ($case in $cases) {
    $j = Copy-TestValue $job
    $r = $run | ConvertTo-Json -Depth 32 | ConvertFrom-Json -DateKind String
    $c = Copy-TestValue $check
    & $case.change $j $r $c
    $negative = Invoke-ScopeCollectorControl $j $r $c $log
    Assert-True ($negative.proven -eq $false -and $negative.reason -ceq "CHANGE_SCOPE_$($case.reason)") "owning-scope-step-required $($case.name) intended reason actual=$($negative.reason)"
  }
  $mutants = @(
    @{name='ignore-owning-step';case='absent-owning';fn='Get-HostedChangeScopeObservation';before='-not $owningStepComplete';after='$false'},
    @{name='workflow-success-is-scope';case='red';fn='Get-HostedChangeScopeObservation';before='-not $owningStepComplete';after="(Get-ObjectValue `$run 'conclusion') -cne 'success'"},
    @{name='ignore-step-time';case='reversed-time';fn='Get-HostedChangeScopeObservation';before='$owningStepComplete = $jobStart -le $stepStart -and $stepStart -le $stepEnd -and $stepEnd -le $jobEnd';after='$owningStepComplete = $true'},
    @{name='ignore-attempt-binding';case='attempt';fn='Get-HostedChangeScopeObservation';before='[long]$jobRunAttempt -ne [long]$workflowRunAttempt';after='$false'},
    @{name='ignore-head-binding';case='job-head';fn='Get-HostedChangeScopeObservation';before='[string](Get-ObjectValue $job "head_sha") -cne $PullHead';after='$false'}
  )
  foreach ($mutant in $mutants) {
    $j = Copy-TestValue $job
    $r = $run | ConvertTo-Json -Depth 32 | ConvertFrom-Json -DateKind String
    $c = Copy-TestValue $check
    $case = @($cases | Where-Object { $_.name -ceq $mutant.case })[0]
    & $case.change $j $r $c
    $bypass = Invoke-ScopeCollectorControl $j $r $c $log $mutant.fn $mutant.before $mutant.after
    Assert-True ($bypass.proven -eq $true) "mutant $($mutant.name) bypasses intended clause with all other facts valid"
    Write-Output "KILLED scope mutant=$($mutant.name) intended-clause=$($case.reason)"
  }
  $double = $log + "`n" + $log
  $ambiguous = Invoke-ScopeCollectorControl $job $run $check $double
  Assert-True ($ambiguous.reason -ceq 'CHANGE_SCOPE_OUTPUT_AMBIGUOUS') 'collector duplicate maps refused'
  $first = Invoke-ScopeCollectorControl $job $run $check $double 'Get-HostedChangeScopeObservation' '$outputs.Count -ne 1' '$outputs.Count -lt 1'
  Assert-True ($first.proven -eq $true) 'first-map-wins bypass reaches output-count clause'
  Write-Output 'KILLED scope mutant=first-map-wins intended-clause=CHANGE_SCOPE_OUTPUT_AMBIGUOUS'
  Write-Output "PASS owning-scope-step-required full-synthetic-provider controls=$($cases.Count) exact-head/run/attempt/PR and native precision"
}

function New-MockGh {
  $source = @'
using System;
using System.IO;
using System.Text.RegularExpressions;

public static class LandingPreflightMockGh
{
    public static int Main(string[] args)
    {
        var log = Environment.GetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_LOG");
        if (!String.IsNullOrWhiteSpace(log))
            File.AppendAllText(log, String.Join("\u001f", args) + Environment.NewLine);

        string fixture = null;
        bool isRunList = false;
        if (args.Length >= 2 && args[0] == "api" && args[1] == "graphql")
            fixture = Environment.GetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_GRAPH");
        else if (args.Length >= 2 && args[0] == "run" && args[1] == "list")
        {
            isRunList = true;
            fixture = Environment.GetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_RUNS");
        }
        else if (args.Length >= 2 && args[0] == "api")
        {
            var scopeLog = Regex.Match(args[1], @"actions/jobs/(\d+)/logs$");
            var scopeJob = Regex.Match(args[1], @"actions/jobs/(\d+)$");
            var scopeRun = Regex.Match(args[1], @"actions/runs/(\d+)$");
            var deployJobs = Regex.Match(args[1], @"actions/runs/(\d+)/jobs");
            if (scopeLog.Success)
                fixture = Environment.GetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_SCOPE_LOG_" + scopeLog.Groups[1].Value);
            else if (scopeJob.Success)
                fixture = Environment.GetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_SCOPE_JOB_" + scopeJob.Groups[1].Value);
            else if (scopeRun.Success)
                fixture = Environment.GetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_SCOPE_RUN_" + scopeRun.Groups[1].Value);
            else if (deployJobs.Success)
                fixture = Environment.GetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_JOBS_" + deployJobs.Groups[1].Value);
        }

        if (String.IsNullOrWhiteSpace(fixture) || fixture == "FAIL" || !File.Exists(fixture))
            return 2;
        Console.Write(File.ReadAllText(fixture));
        if (isRunList)
        {
            var exitValue = Environment.GetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_RUNS_EXIT");
            int exitCode;
            if (Int32.TryParse(exitValue, out exitCode) && exitCode != 0)
                return exitCode;
        }
        return 0;
    }
}
'@
  $path = Join-Path $testRoot "mock-gh.exe"
  $sourcePath = Join-Path $testRoot "mock-gh.cs"
  [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
  $compiler = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "test fixture compiler is unavailable"
  }
  & $compiler /nologo /target:exe "/out:$path" $sourcePath
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "unable to compile the test-only gh fixture"
  }
  $path
}

function Invoke-ProductionPreflight([string]$History, [int]$PullRequest = 6254) {
  & $preflight -Pr $PullRequest -Action Report -MutationDisabled `
    -HistoryPath $History -GhCommand $mockGh |
    ConvertFrom-Json -DateKind String
}

function Invoke-RawRequiredCheckProductionFixture(
  [object[]]$Nodes,
  [string]$Label,
  [string]$History
) {
  $graph = New-ProductionGraphFixture
  $connection = $graph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts
  $connection.totalCount = [long]$Nodes.Count
  $connection.nodes = [object[]]@($Nodes)
  $path = Write-JsonFixture "raw-required-check-$Label.json" $graph
  $before = [IO.File]::ReadAllText($path)
  $env:LANDING_PREFLIGHT_MOCK_GRAPH = $path
  $result = Invoke-ProductionPreflight $History
  $after = [IO.File]::ReadAllText($path)
  [pscustomobject][ordered]@{
    result = $result
    inputUnchanged = $before -ceq $after
    inputSha256 = Get-TestSha256 $before
  }
}

function Invoke-LoggedProductionPreflight([string]$History) {
  [IO.File]::WriteAllText($env:LANDING_PREFLIGHT_MOCK_LOG, "")
  $result = Invoke-ProductionPreflight $History
  [pscustomobject][ordered]@{
    result = $result
    calls = @(Get-Content -LiteralPath $env:LANDING_PREFLIGHT_MOCK_LOG)
  }
}

function Get-JobQueryCount($Control, [long]$RunId) {
  @($Control.calls | Where-Object { $_ -match "actions/runs/$RunId/jobs" }).Count
}

function Invoke-Preflight(
  [string]$Scenario,
  [string]$History,
  [string]$Action = "Apply",
  [switch]$MutationDisabled,
  [switch]$ControllerCandidate,
  [int]$MaxHistoryRows = 50000,
  [string]$FixturePath = $fixture
) {
  $arguments = @{
    Pr = 6254
    Action = $Action
    HistoryPath = $History
    MaxHistoryRows = $MaxHistoryRows
    AuthorityFixture = $FixturePath
    AuthorityScenario = $Scenario
  }
  if ($MutationDisabled) { $arguments.MutationDisabled = $true }
  if ($ControllerCandidate) { $arguments.ControllerCandidate = $true }
  & $preflight @arguments | ConvertFrom-Json -DateKind String
}

function ConvertTo-TestCanonicalJson($Value) {
  if ($null -eq $Value) { return "null" }
  if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }
  if ($Value -is [string]) { return [System.Text.Json.JsonSerializer]::Serialize([string]$Value, [System.Text.Json.JsonSerializerOptions]::new()) }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long]) {
    return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
  }
  if ($Value -is [Collections.IDictionary]) {
    $keys = [string[]]@($Value.Keys); [Array]::Sort($keys, [StringComparer]::Ordinal)
    $members = foreach ($key in $keys) { ([System.Text.Json.JsonSerializer]::Serialize($key, [System.Text.Json.JsonSerializerOptions]::new())) + ":" + (ConvertTo-TestCanonicalJson $Value[$key]) }
    return "{" + ($members -join ",") + "}"
  }
  if ($Value -is [pscustomobject]) {
    $keys = [string[]]@($Value.PSObject.Properties.Name); [Array]::Sort($keys, [StringComparer]::Ordinal)
    $members = foreach ($key in $keys) { ([System.Text.Json.JsonSerializer]::Serialize($key, [System.Text.Json.JsonSerializerOptions]::new())) + ":" + (ConvertTo-TestCanonicalJson $Value.$key) }
    return "{" + ($members -join ",") + "}"
  }
  if ($Value -is [Collections.IEnumerable]) {
    $items = foreach ($item in $Value) { ConvertTo-TestCanonicalJson $item }
    return "[" + ($items -join ",") + "]"
  }
  throw "unsupported test canonical value"
}

function Get-TestSha256([string]$Text) {
  ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant()
}

function Copy-TestValue($Value) {
  if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
  if ($Value -is [Collections.IDictionary]) {
    $copy = [ordered]@{}; foreach ($key in $Value.Keys) { $copy[$key] = Copy-TestValue $Value[$key] }; return $copy
  }
  if ($Value -is [pscustomobject]) {
    $copy = [ordered]@{}; foreach ($property in $Value.PSObject.Properties) { $copy[$property.Name] = Copy-TestValue $property.Value }; return $copy
  }
  if ($Value -is [Array]) { return ,@($Value | ForEach-Object { Copy-TestValue $_ }) }
  return $Value
}

function New-SyntheticRequiredCheckProjection(
  [long]$DatabaseId,
  [string]$CompletedAt,
  [string]$Status = 'COMPLETED',
  [AllowNull()][string]$Conclusion = 'SUCCESS',
  [long]$AppDatabaseId = 9000000000000001,
  [long]$WorkflowDatabaseId = 9000000000000002
) {
  [ordered]@{
    schemaVersion = 'required-check-observation/v1'
    valid = $true
    reason = 'REQUIRED_CHECK_IDENTITY_VALID'
    nodeType = 'CheckRun'
    name = 'PR Required'
    databaseId = $DatabaseId
    status = $Status
    conclusion = $Conclusion
    completedAt = $CompletedAt
    producer = [ordered]@{
      appDatabaseId = $AppDatabaseId
      workflowDatabaseId = $WorkflowDatabaseId
    }
  }
}

function New-SyntheticRequiredCheckRawNode(
  [long]$DatabaseId,
  [string]$CompletedAt,
  [string]$Conclusion = 'SUCCESS',
  [long]$AppDatabaseId = 9007199254740401,
  [long]$WorkflowDatabaseId = 9007199254740402
) {
  [ordered]@{
    __typename = 'CheckRun'
    name = 'PR Required'
    status = 'COMPLETED'
    conclusion = $Conclusion
    databaseId = $DatabaseId
    detailsUrl = "https://github.com/synthetic-required-check-7739/actions/runs/$DatabaseId/job/$DatabaseId"
    completedAt = $CompletedAt
    checkSuite = [ordered]@{
      app = [ordered]@{ databaseId = $AppDatabaseId }
      workflowRun = [ordered]@{
        workflow = [ordered]@{ databaseId = $WorkflowDatabaseId }
      }
    }
  }
}

function New-SyntheticStatusContextProjection([string]$State = 'SUCCESS') {
  [ordered]@{
    schemaVersion = 'required-check-observation/v1'
    valid = $true
    reason = 'REQUIRED_STATUS_CONTEXT_VALID'
    nodeType = 'StatusContext'
    name = 'PR Required'
    databaseId = $null
    status = $State
    conclusion = $null
    completedAt = $null
    producer = $null
  }
}

function Invoke-RequiredCheckFixture(
  [object[]]$InitialChecks,
  [object[]]$FinalChecks = $null,
  [string]$Action = 'Report'
) {
  $source = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json -AsHashtable -DateKind String
  $initial = Copy-TestValue $source.scenarios.eligible.observations[0]
  $initial.pr.checks = [object[]]@($InitialChecks)
  $observations = [Collections.Generic.List[object]]::new()
  $observations.Add($initial)
  if ($Action -ceq 'Apply') {
    $final = if ($null -eq $FinalChecks) { Copy-TestValue $initial } else {
      $copy = Copy-TestValue $initial
      $copy.pr.checks = [object[]]@($FinalChecks)
      $copy
    }
    $observations.Add($final)
  }
  $control = [ordered]@{
    schema = 'landing-preflight-fixture/v1'
    scenarios = [ordered]@{
      'required-check-control' = [ordered]@{
        observations = [object[]]@($observations)
        mutation = [ordered]@{ complete = $true; entryId = 'MQE_SYNTHETIC_REQUIRED_CHECK' }
      }
    }
  }
  $controlPath = Write-JsonFixture ('required-check-' + [guid]::NewGuid().ToString('N') + '.json') $control
  Invoke-Preflight 'required-check-control' (New-History @((New-Pass $headA))) $Action -FixturePath $controlPath
}

function New-SyntheticChangeScope(
  [string]$Classification,
  [string]$EvaluatedHead = $headA,
  [long]$CandidateCount = 1,
  [long]$WorkflowRunId = 7101
) {
  $candidates = [object[]]@()
  if ($CandidateCount -gt 0) {
    $candidates = [object[]]@(1..$CandidateCount | ForEach-Object {
        [ordered]@{
          databaseId = 8100 + $_
          detailsUrl = "https://github.com/chase-sets/chase-sets/actions/runs/$WorkflowRunId/job/$(8100 + $_)"
          name = "Change Scope"
          status = "COMPLETED"
          conclusion = "SUCCESS"
        }
      })
  }
  [ordered]@{
    schemaVersion = "pr-change-scope-observation/v1"
    classification = $Classification
    proven = $true
    reason = if ($Classification -ceq "non-deployable") { "CHANGE_SCOPE_EXACT_HEAD_NON_DEPLOYABLE" } else { "CHANGE_SCOPE_EXACT_HEAD_DEPLOYABLE" }
    requestedHead = $EvaluatedHead
    evaluatedHead = $EvaluatedHead
    checkCandidateCount = $CandidateCount
    checkCandidates = $candidates
    evidence = [ordered]@{
      workflowRunId = $WorkflowRunId
      pr = 6254
      head = $EvaluatedHead
      deploy = $Classification -ceq "deployable"
      changedFilesCount = 1
      changedFiles = @("docs/synthetic-scope-control.md")
    }
    sourceReason = $null
  }
}

function New-ScopeBreakerObservation(
  [AllowNull()]$ChangeScope,
  [string]$Head = $headA
) {
  $baseFixture = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json -DateKind String
  $observation = Copy-TestValue $baseFixture.scenarios.eligible.observations[0]
  $observation.pr.head = $Head
  $observation.breaker = [ordered]@{
    complete = $true
    healthy = $false
    reason = "PIPELINE_BREAKER_OPEN"
    open = @("9001/9002")
    openRows = @([ordered]@{
        key = "9001/9002"
        openTs = "2030-01-01T00:00:00Z"
        line = 9003
        rowSha256 = "9" * 64
        byteLength = 321
      })
    unpairedClears = 0
  }
  if ($null -ne $ChangeScope) { $observation["changeScope"] = Copy-TestValue $ChangeScope }
  $observation
}

function Invoke-ScopeBreakerFixture(
  [object[]]$Observations,
  [string]$History,
  [string]$Action = "Apply"
) {
  $value = [ordered]@{
    schema = "landing-preflight-fixture/v1"
    scenarios = [ordered]@{
      scope = [ordered]@{
        observations = $Observations
        mutation = [ordered]@{ complete = $true; entryId = "MQE_scope_fixture_6254" }
      }
    }
  }
  $scopeFixture = Write-JsonFixture ("scope-fixture-" + [guid]::NewGuid().ToString("N") + ".json") $value
  Invoke-Preflight "scope" $History -Action $Action -FixturePath $scopeFixture
}

function New-FrontierConfiguration {
  $value = [ordered]@{
    schemaVersion = "admission-configuration/v1"
    repository = [ordered]@{ autoMergeAllowed = $false; mergeCommitAllowed = $true; rebaseMergeAllowed = $true; squashMergeAllowed = $true; viewerPermission = "ADMIN" }
    mergeQueue = [ordered]@{ mergeMethod = "SQUASH"; maximumEntriesToBuild = 2; maximumEntriesToMerge = 2; minimumEntriesToMerge = 1; minimumEntriesToMergeWaitTime = 0; checkResponseTimeout = 3600; mergingStrategy = "ALLGREEN" }
    applicableRulesetCount = 1
    applicableRulesets = @([ordered]@{
        id = 17097957; name = "SYNTHETIC exact main queue"; target = "branch"; enforcement = "active"
        include = @("refs/heads/main"); exclude = @(); bypassActors = @()
        rules = @(
          [ordered]@{ type = "merge_queue"; mergeMethod = "SQUASH"; maximumEntriesToBuild = 2; maximumEntriesToMerge = 2; minimumEntriesToMerge = 1; minimumEntriesToMergeWaitMinutes = 0; groupingStrategy = "ALLGREEN"; checkResponseTimeoutMinutes = 60 },
          [ordered]@{ type = "non_fast_forward" },
          [ordered]@{ type = "required_linear_history" },
          [ordered]@{ type = "required_status_checks"; strict = $true; doNotEnforceOnCreate = $false; checks = @([ordered]@{ context = "PR Required"; integrationId = 15368 }) }
        )
      })
    classicProtection = [ordered]@{
      enforceAdmins = $true
      requiredStatusChecks = [ordered]@{ strict = $true; contexts = @("PR Required"); checks = @([ordered]@{ context = "PR Required"; appId = 15368 }) }
      requiredSignatures = $false; requiredLinearHistory = $true; requiredConversationResolution = $true
      allowForcePushes = $false; allowDeletions = $false; blockCreations = $false; lockBranch = $false; allowForkSyncing = $false
    }
    writers = [ordered]@{
      automatedEnqueueWriters = @(".orchestrator/landing-preflight.ps1")
      openAutoMergeRequestCount = 0
      collaboratorCount = 1
      collaborators = @([ordered]@{ login = "synthetic-admin"; id = 9001; nodeId = "U_SYNTHETIC_ADMIN"; role = "admin"; permissions = [ordered]@{ admin = $true; maintain = $true; push = $true; triage = $true; pull = $true } })
      authorityBoundary = "manual administrator enqueue is detected, never prevented"
    }
  }
  $roundTrip = ($value | ConvertTo-Json -Compress -Depth 50) | ConvertFrom-Json -Depth 50 -DateKind String
  [ordered]@{ complete = $true; value = $value; sha256 = Get-TestSha256 ($roundTrip | ConvertTo-Json -Compress -Depth 50) }
}

function Set-FrontierAuthorityRaw($Observation, [switch]$ExtraRoot) {
  $record = [ordered]@{
    schemaVersion = "breaker-repair-frontier-authority/v1"
    createdAt = "2026-08-25T11:00:00Z"
    expiresAt = "2026-08-25T13:00:00Z"
    authority = [ordered]@{ issue = 7476; bodySha256 = "2b81a8235e359fa61c9b58d87c61ce97cb15cf952abca77034afdacaa0b33f21" }
    breaker = [ordered]@{ key = "7171/7428"; openTs = "2026-08-24T17:00:56.433Z"; line = 11594; rowSha256 = "5d6d5ad8afcdfd3119f7ae19a6f2d601c21bc84e1ef47598ba1811d1a58a9879" }
    repair = [ordered]@{ rootIssue = 7468; issue = 7470; bodySha256 = "3be40dd2e99d9142a60989463ed1601577ec9d8e08f44a79c198ed09449ffb89" }
    candidate = [ordered]@{ pr = 7470; headOid = $repairHead; baseOid = $repairBase }
    configurationSha256 = [string]$Observation.admission.configuration.sha256
  }
  if ($ExtraRoot) { $record.extra = $true }
  $Observation.admission.authorityRecord.raw = $record | ConvertTo-Json -Compress -Depth 50
}

function New-FrontierObservation([switch]$Audit) {
  $configuration = New-FrontierConfiguration
  $entry = [ordered]@{
    id = "MQE_SYNTHETIC_REPAIR"; position = 1; state = "QUEUED"; solo = $false; jump = $false
    baseCommit = [ordered]@{ oid = $repairBase }; headCommit = [ordered]@{ oid = $repairHead }
    pullRequest = [ordered]@{ id = "PR_SYNTHETIC_7470"; number = 7470; headRefOid = $repairHead }
  }
  $entryObservation = ConvertTo-QueueEntryObservation $entry
  $observation = [ordered]@{
    complete = $true; reason = "OBSERVATION_COMPLETE"
    pr = [ordered]@{
      id = "PR_SYNTHETIC_7470"; number = 7470; state = "OPEN"; isDraft = $false; head = $repairHead; baseRefName = "main"; mergeQueueEntryId = $(if ($Audit) { $entry.id } else { $null })
      branchProtectionObserved = $true; requiresStatusChecks = $true; requiredContexts = @("PR Required"); statusRollupState = "SUCCESS"
      checks = @([ordered]@{ name = "PR Required"; outcome = "success" })
      closingIssues = @([ordered]@{ number = 7470; state = "OPEN"; blockersComplete = $true; blockers = @() })
    }
    deploy = [ordered]@{ complete = $true; status = "completed"; conclusion = "success"; runId = 32752273315; jobId = 97515153704; headSha = $repairBase }
    breaker = [ordered]@{
      complete = $true; healthy = $false; reason = "PIPELINE_BREAKER_OPEN"; open = @("7171/7428"); unpairedClears = 0
      openRows = @([ordered]@{ key = "7171/7428"; openTs = "2026-08-24T17:00:56.433Z"; line = 11594; rowSha256 = "5d6d5ad8afcdfd3119f7ae19a6f2d601c21bc84e1ef47598ba1811d1a58a9879"; byteLength = 346 })
    }
    admission = [ordered]@{
      complete = $true; reason = "FRONTIER_OBSERVATION_COMPLETE"; observedAt = "2026-08-25T12:00:00Z"
      authorityRecord = [ordered]@{ present = $true; complete = $true; reason = "AUTHORITY_RECORD_READ"; raw = "" }
      authorityIssue = [ordered]@{ id = "I_kwDORKgVcc8AAAABOK7jjA"; number = 7476; state = "OPEN"; bodySha256 = "2b81a8235e359fa61c9b58d87c61ce97cb15cf952abca77034afdacaa0b33f21"; type = "Bug"; milestone = [ordered]@{ number = 136; state = "OPEN" }; labels = @("area:ops", "kind:ops", "priority:p0", "risk:semantic-authority") }
      root = [ordered]@{ issue = [ordered]@{ id = "I_SYNTHETIC_7468"; number = 7468; state = "OPEN"; bodySha256 = "0" * 64; type = "Issue"; milestone = $null }; closureComplete = $true; closure = @([ordered]@{ parent = 7468; id = "I_SYNTHETIC_7470"; number = 7470; state = "OPEN" }) }
      repair = [ordered]@{ issue = [ordered]@{ id = "I_SYNTHETIC_7470"; number = 7470; state = "OPEN"; bodySha256 = "3be40dd2e99d9142a60989463ed1601577ec9d8e08f44a79c198ed09449ffb89"; type = "Bug"; milestone = [ordered]@{ number = 136; state = "OPEN" } }; labels = @("area:infrastructure", "kind:ops", "priority:p0"); blockersComplete = $true; blockers = @() }
      candidate = [ordered]@{ id = "PR_SYNTHETIC_7470"; number = 7470; headOid = $repairHead; baseOid = $repairBase; mergeBaseOid = $repairBase; comparisonStatus = "ahead"; filesComplete = $true; files = @("scripts/digitalocean-platform-config.test.mjs", "scripts/synthetic-repair.mjs"); closingIssuesComplete = $true; closingIssues = @(7470) }
      defaultOid = $repairBase
      openPullRequests = [ordered]@{ complete = $true; pullRequests = @([ordered]@{ id = "PR_SYNTHETIC_7470"; number = 7470; isDraft = $false; headOid = $repairHead; autoMerge = $false; files = @("scripts/digitalocean-platform-config.test.mjs", "scripts/synthetic-repair.mjs") }) }
      collisions = @()
      queue = [ordered]@{ complete = $true; totalCount = 0; entries = @() }
      configuration = $configuration
      breaker = $null
    }
  }
  if ($Audit) { $observation.admission.queue.totalCount = 1; $observation.admission.queue.entries = @($entryObservation) }
  $observation.admission.breaker = $observation.breaker
  Set-FrontierAuthorityRaw $observation
  return $observation
}

function New-RepairPass {
  $pass = New-Pass $repairHead
  $pass.pr = 7470
  $pass.reviewerAttempt = "synthetic-review-7470"
  $pass.authorAttempt = "synthetic-author-7470"
  $pass
}

function Invoke-FrontierFixture(
  $Observations,
  [string]$Action = "Report",
  [bool]$DequeueComplete = $true,
  $EnqueueOverride = $null,
  [string]$DequeueEntryId = "",
  $RemoteConsumption = $null
) {
  $entry = [ordered]@{
    id = "MQE_SYNTHETIC_REPAIR"; position = 1; state = "QUEUED"; solo = $false; jump = $false
    baseCommit = [ordered]@{ oid = $repairBase }; headCommit = [ordered]@{ oid = $repairHead }
    pullRequest = [ordered]@{ id = "PR_SYNTHETIC_7470"; number = 7470; headRefOid = $repairHead }
  }
  $enqueue = if ($null -ne $EnqueueOverride) { $EnqueueOverride } else { [ordered]@{ complete = $true; entryId = $entry.id; entry = $entry } }
  $value = [ordered]@{
    schema = "landing-preflight-fixture/v1"
    scenarios = [ordered]@{ frontier = [ordered]@{
        observations = @($Observations)
        mutation = [ordered]@{
          enqueue = $enqueue
          dequeue = [ordered]@{ complete = $DequeueComplete; entryId = $(if ($DequeueComplete) { $(if ($DequeueEntryId) { $DequeueEntryId } else { $entry.id }) } else { $null }) }
        }
        remoteConsumption = $RemoteConsumption
      } }
  }
  $path = Write-JsonFixture ("frontier-" + [guid]::NewGuid().ToString("N") + ".json") $value
  & $preflight -Pr 7470 -Action $Action -HistoryPath (New-History @((New-RepairPass))) -AuthorityFixture $path -AuthorityScenario frontier -GhCommand (Join-Path $testRoot "provider-sentinel-must-not-run.exe") |
    ConvertFrom-Json -Depth 100 -DateKind String
}

$decision7643Head = "d3175a021e5fd958b60eda1500b5e1d072bbf195"
$decision7643OtherHead = "e" * 40

function New-Decision7643Pass([string]$Head = $decision7643Head) {
  $pass = New-Pass $Head
  $pass.pr = 7641
  $pass.reviewerAttempt = "synthetic-review-7641"
  $pass.authorAttempt = "synthetic-author-7641"
  $pass
}

function New-Decision7643Observation([switch]$Audit) {
  $configuration = New-FrontierConfiguration
  $entry = [ordered]@{
    id = "MQE_SYNTHETIC_7641"; position = 1; state = "QUEUED"; solo = $false; jump = $false
    baseCommit = [ordered]@{ oid = "d" * 40 }; headCommit = [ordered]@{ oid = $decision7643Head }
    pullRequest = [ordered]@{ id = "PR_SYNTHETIC_7641"; number = 7641; headRefOid = $decision7643Head }
  }
  $entryObservation = ConvertTo-QueueEntryObservation $entry
  $breaker = [ordered]@{
    complete = $true; healthy = $false; reason = "PIPELINE_BREAKER_OPEN"; open = @("7558/7631"); unpairedClears = 0
    openRows = @([ordered]@{ key = "7558/7631"; openTs = "2026-09-03T21:47:13.444Z"; line = 14530; rowSha256 = "2b35a27c6cdf5cd2d68e54a8f27fd526586a22c5c0eae52bfaa3e373dfbbfb60"; byteLength = 804 })
  }
  $observation = [ordered]@{
    complete = $true; reason = "OBSERVATION_COMPLETE"
    pr = [ordered]@{
      id = "PR_SYNTHETIC_7641"; number = 7641; state = "OPEN"; isDraft = $false; head = $decision7643Head; baseRefName = "main"; mergeQueueEntryId = $(if ($Audit) { $entry.id } else { $null })
      branchProtectionObserved = $true; requiresStatusChecks = $true; requiredContexts = @("PR Required"); statusRollupState = "SUCCESS"
      checks = @([ordered]@{ name = "PR Required"; outcome = "success" })
      closingIssues = @([ordered]@{ number = 7421; state = "OPEN"; blockersComplete = $true; blockers = @() })
    }
    deploy = [ordered]@{ complete = $true; status = "completed"; conclusion = "success"; runId = 33808501347; jobId = 100824895413; headSha = "d" * 40 }
    breaker = $breaker
    decision7643Adapter = [ordered]@{
      complete = $true; reason = "DECISION_7643_OBSERVATION_COMPLETE"; observedAt = "2026-09-04T14:00:00Z"
      decision = [ordered]@{
        complete = $true; reason = "DECISION_7643_AUTHORITY_COMPLETE"
        decision = [ordered]@{
          id = "I_kwDORKgVcc8AAAABPn7EAw"; number = 7643; state = "CLOSED"; stateReason = "COMPLETED"; type = "Decision"
          bodySha256 = "0f86990a051007d816b2604a17316793ff3a891281f9126e6e751fc4c56ed966"
          updatedAt = "2026-09-04T13:40:31Z"; closedAt = "2026-09-04T13:40:31Z"; closedBy = "todd-skelton"
        }
        commentsComplete = $true
        comments = @([ordered]@{
            id = [long]5541242254; url = "https://github.com/chase-sets/chase-sets/issues/7643#issuecomment-5541242254"
            author = [ordered]@{ login = "todd-skelton"; id = [long]17231123; nodeId = "MDQ6VXNlcjE3MjMxMTIz" }
            authorAssociation = "MEMBER"; bodySha256 = "559aead08264d5795d3909718cdd05abd49572e84fe55590eef31a88a08fdffd"
            createdAt = "2026-09-04T13:37:30Z"; updatedAt = "2026-09-04T13:37:30Z"
          })
      }
      breakerAuthority = [ordered]@{
        complete = $true; reason = "DECISION_7643_BREAKER_OBSERVED"; current = $breaker
        row = [ordered]@{
          line = 14530; rowSha256 = "2b35a27c6cdf5cd2d68e54a8f27fd526586a22c5c0eae52bfaa3e373dfbbfb60"; byteLength = 804
          kind = "breaker-open"; ts = "2026-09-03T21:47:13.444Z"; issue = 7558; pr = 7631
          outcome = "HOSTED_E2E_REQUIRED_FAILURE"; breakerScope = "pipeline"
        }
      }
      candidate = [ordered]@{ id = "PR_SYNTHETIC_7641"; number = 7641; headOid = $decision7643Head; filesComplete = $true; files = @("deployables/platform-api/src/auth/synthetic.ts") }
      openPullRequests = [ordered]@{ complete = $true; pullRequests = @([ordered]@{ id = "PR_SYNTHETIC_7641"; number = 7641; isDraft = $false; headOid = $decision7643Head; autoMerge = $false; files = @("deployables/platform-api/src/auth/synthetic.ts") }) }
      collisions = @()
      queue = [ordered]@{ complete = $true; totalCount = 0; entries = @() }
      configuration = $configuration
      breaker = $breaker
    }
  }
  if ($Audit) {
    $observation.decision7643Adapter.queue.totalCount = 1
    $observation.decision7643Adapter.queue.entries = @($entryObservation)
  }
  $observation
}

function Invoke-Decision7643ProductionShapeControl($Observation) {
  $source = Get-Content -Raw -LiteralPath $preflight
  $mainMarker = '$script:currentAdmission = $null'
  $mainIndex = $source.IndexOf($mainMarker, [StringComparison]::Ordinal)
  Assert-True ($mainIndex -gt 0) "Decision #7643 production-shape control could not isolate the production reducer"
  $prefix = $source.Substring(0, $mainIndex)
  $quotedRoot = "'" + $PSScriptRoot.Replace("'", "''") + "'"
  $prefix = $prefix.Replace('$PSScriptRoot', $quotedRoot)
  $script:decision7643ProductionShapeObservation = $Observation
  try {
    $control = @'
$controlResult = Test-Decision7643LandingAdapter $script:decision7643ProductionShapeObservation
[pscustomobject][ordered]@{
  admitted = $controlResult.admitted
  exactRuling = $controlResult.admission.conjuncts.exactRuling
  exactRetainedBreaker = $controlResult.admission.conjuncts.exactRetainedBreaker
  collisionFree = $controlResult.admission.conjuncts.collisionFree
}
'@
    & ([scriptblock]::Create($prefix + $control)) -Pr 7641 -Action Report -HistoryPath (Join-Path $testRoot "production-shape-unused-history.jsonl")
  } finally {
    Remove-Variable -Scope Script -Name decision7643ProductionShapeObservation -ErrorAction SilentlyContinue
  }
}

function Invoke-Decision7643Fixture(
  $Observations,
  [string]$Action = "Report",
  [string]$History = "",
  [switch]$MutationDisabled,
  [bool]$DequeueComplete = $true
) {
  $entry = [ordered]@{
    id = "MQE_SYNTHETIC_7641"; position = 1; state = "QUEUED"; solo = $false; jump = $false
    baseCommit = [ordered]@{ oid = "d" * 40 }; headCommit = [ordered]@{ oid = $decision7643Head }
    pullRequest = [ordered]@{ id = "PR_SYNTHETIC_7641"; number = 7641; headRefOid = $decision7643Head }
  }
  $value = [ordered]@{
    schema = "landing-preflight-fixture/v1"
    scenarios = [ordered]@{ decision7643 = [ordered]@{
        observations = @($Observations)
        mutation = [ordered]@{
          enqueue = [ordered]@{ complete = $true; entryId = $entry.id; entry = $entry }
          dequeue = [ordered]@{ complete = $DequeueComplete; entryId = $(if ($DequeueComplete) { $entry.id } else { $null }) }
        }
      } }
  }
  $path = Write-JsonFixture ("decision-7643-" + [guid]::NewGuid().ToString("N") + ".json") $value
  if ([string]::IsNullOrWhiteSpace($History)) { $History = New-History @((New-Decision7643Pass)) }
  $arguments = @{
    Pr = 7641; Action = $Action; HistoryPath = $History; AuthorityFixture = $path; AuthorityScenario = "decision7643"
    GhCommand = (Join-Path $testRoot "provider-sentinel-must-not-run.exe")
  }
  if ($MutationDisabled) { $arguments.MutationDisabled = $true }
  & $preflight @arguments | ConvertFrom-Json -Depth 100 -DateKind String
}

# Execute the exact production function bodies without running the script's
# command entrypoint. Provider responses below are closed synthetic controls or
# immutable live captures identified explicitly at their owning head/issue.
$productionTokens = $null
$productionErrors = $null
$productionAst = [Management.Automation.Language.Parser]::ParseFile(
  $preflight,
  [ref]$productionTokens,
  [ref]$productionErrors
)
Assert-True ($productionErrors.Count -eq 0) "landing-preflight production functions do not parse"
foreach ($functionName in @(
    "Get-Sha256", "Get-ObjectKeys", "Get-ObjectValue", "Test-ExactKeys", "Test-ObjectProperty",
    "Test-JsonTokenClosure", "ConvertFrom-ClosedJson", "Get-ChangeScopeOutputMaps",
    "Test-RequiredCheckInstant", "New-FailClosedChangeScopeObservation", "Get-HostedChangeScopeObservation",
    "ConvertTo-CanonicalJson", "Get-ObservedType", "New-FieldEvidence", "Get-ScalarFieldEvidence",
    "Get-NestedObjectFieldEvidence", "ConvertTo-QueueEntryObservation", "Get-StableEntryConjuncts",
    "New-EnqueueMutationResult", "Get-RetryConsumptionRefName", "Test-RetryAttemptPolicy", "ConvertTo-RemoteRefObservation",
    "Invoke-RetryConsumptionProtocol", "Get-ConfigurationSha256",
    "Invoke-GhRestJson", "Get-RestCollection", "Get-PagedGraphConnection",
    "Get-FrontierIssueLabels", "Get-FrontierIssueBlockers", "Get-FrontierClosure",
    "Get-FrontierPullRequestFiles", "Get-FrontierConfiguration"
  )) {
  $definitions = @($productionAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
      }, $true))
  Assert-True ($definitions.Count -eq 1) "production function inventory has exactly one $functionName"
  . ([scriptblock]::Create($definitions[0].Extent.Text))
}

$Repository = "chase-sets/chase-sets"
$GhCommand = "synthetic-gh-must-not-execute"
$fixtureScenario = $null
$frontierAuthorityIssue = 900200
$frontierConsumptionNamespace = "refs/tags/orchestrator-consumption/"
$script:collectionGraphResponder = $null
$script:collectionRestResponses = @{}

function New-SyntheticStableEntry(
  [string]$EntryId = "MQE_SYNTHETIC_STABLE",
  [long]$Position = 0,
  [string]$State = "QUEUED",
  [bool]$Solo = $false,
  [bool]$Jump = $false,
  $BaseCommit = $null,
  $HeadCommit = $null,
  $PullRequest = $null
) {
  if ($null -eq $PullRequest) {
    $PullRequest = [ordered]@{ id = "PR_SYNTHETIC_STABLE"; number = 900100; headRefOid = "a" * 40 }
  }
  [ordered]@{
    id = $EntryId
    position = $Position
    state = $State
    solo = $Solo
    jump = $Jump
    baseCommit = $BaseCommit
    headCommit = $HeadCommit
    pullRequest = $PullRequest
  }
}

function New-SyntheticMutationGraph(
  $Entry,
  [string]$RequestedClientMutationId = "CMID_SYNTHETIC_STABLE",
  [int]$ExitCode = 0,
  [object[]]$Errors = @(),
  [bool]$IncludeErrors = $false
) {
  $payload = [ordered]@{
    data = [ordered]@{ enqueuePullRequest = [ordered]@{ clientMutationId = $RequestedClientMutationId; mergeQueueEntry = $Entry } }
  }
  if ($IncludeErrors) { $payload.errors = [object[]]@($Errors) }
  [pscustomobject][ordered]@{
    complete = $ExitCode -eq 0 -and @($Errors).Count -eq 0
    reason = "SYNTHETIC_GRAPHQL"
    payload = $payload
    process = [ordered]@{
      exitCode = $ExitCode
      stdout = $payload | ConvertTo-Json -Compress -Depth 100
      stderr = $(if ($ExitCode -eq 0) { "" } else { "synthetic partial-success stderr" })
    }
  }
}

function Test-FieldEvidenceClosed($Evidence) {
  if (-not (Test-ExactKeys $Evidence @("present", "explicitNull", "type", "value", "predicate", "unexpectedKeys", "fields"))) { return $false }
  foreach ($child in $Evidence.fields.Values) { if (-not (Test-FieldEvidenceClosed $child)) { return $false } }
  return $true
}

function Test-EntryObservationClosed($Observation) {
  if (-not (Test-ExactKeys $Observation @("schemaVersion", "valid", "unexpectedKeys", "fields", "stable", "transient")) -or
      [string]$Observation.schemaVersion -cne "merge-queue-entry-observation/v1" -or
      -not (Test-ExactKeys $Observation.fields @("id", "position", "state", "solo", "jump", "baseCommit", "headCommit", "pullRequest")) -or
      -not (Test-ExactKeys $Observation.stable @("entryId", "jump", "pullRequest")) -or
      -not (Test-ExactKeys $Observation.transient @("position", "state", "solo", "baseOid", "headOid"))) { return $false }
  foreach ($field in $Observation.fields.Values) { if (-not (Test-FieldEvidenceClosed $field)) { return $false } }
  return $true
}

function Test-TerminalAdmissionClosed($Admission, [bool]$ExpectNonPass) {
  $required = @(
    "schemaVersion", "decision", "conjuncts", "queuePredicates", "configurationSha256",
    "configurationComputedSha256", "collisions", "authorityBoundary", "seed",
    "preMutation", "mutation", "audit"
  )
  if ($ExpectNonPass) { $required += "nonPass" }
  if (-not (Test-ExactKeys $Admission $required) -or
      -not (Test-ExactKeys $Admission.mutation @("schemaVersion", "reason", "entryId", "clientMutationId", "entry", "graphql")) -or
      -not (Test-ExactKeys $Admission.mutation.graphql @("schemaVersion", "process", "data", "errors")) -or
      -not (Test-ExactKeys $Admission.mutation.graphql.process @("exitCode", "stdout", "stderr")) -or
      -not (Test-FieldEvidenceClosed $Admission.mutation.clientMutationId) -or
      -not (Test-FieldEvidenceClosed $Admission.mutation.graphql.data) -or
      -not (Test-FieldEvidenceClosed $Admission.mutation.graphql.errors) -or
      -not (Test-ExactKeys $Admission.audit @(
          "schemaVersion", "decision", "entryShape", "stableAuthority", "immediateQueue",
          "observation", "conjuncts", "queuePredicates", "failedPredicates"
        )) -or
      -not (Test-ExactKeys $Admission.audit.immediateQueue @("complete", "totalCount", "entries"))) { return $false }
  if ($null -ne $Admission.mutation.entry -and -not (Test-EntryObservationClosed $Admission.mutation.entry)) { return $false }
  foreach ($entry in @($Admission.audit.immediateQueue.entries)) { if (-not (Test-EntryObservationClosed $entry)) { return $false } }
  return @($Admission.audit.failedPredicates | Sort-Object -Unique).Count -eq @($Admission.audit.failedPredicates).Count
}

function Invoke-GhGraphQl([string]$Query, [hashtable]$Variables) {
  if ($null -eq $script:collectionGraphResponder) {
    return [pscustomobject][ordered]@{ complete = $false; reason = "SYNTHETIC_GRAPH_UNCONFIGURED"; payload = $null }
  }
  & $script:collectionGraphResponder $Query $Variables
}

function Invoke-ExternalProcess([string]$Command, [string[]]$Arguments) {
  $endpoint = if ($Arguments.Count -ge 2 -and $Arguments[0] -ceq "api") { [string]$Arguments[1] } else { "" }
  if (-not $script:collectionRestResponses.ContainsKey($endpoint)) {
    return [pscustomobject][ordered]@{ exitCode = 2; stdout = ""; stderr = "synthetic endpoint absent" }
  }
  $value = $script:collectionRestResponses[$endpoint]
  if ($value -ceq "SYNTHETIC_PROVIDER_FAILURE") {
    return [pscustomobject][ordered]@{ exitCode = 2; stdout = "[]"; stderr = "synthetic provider failure" }
  }
  [pscustomobject][ordered]@{ exitCode = 0; stdout = [string]$value; stderr = "" }
}

function New-SyntheticGraphResult([string]$CollectionName, $Connection) {
  $issue = [ordered]@{}
  $issue[$CollectionName] = $Connection
  [pscustomobject][ordered]@{
    complete = $true
    reason = "SYNTHETIC_GRAPH_COMPLETE"
    payload = [ordered]@{ data = [ordered]@{ repository = [ordered]@{ issue = $issue; pullRequest = $issue } } }
  }
}

function New-SyntheticConnection([object[]]$Nodes, [long]$TotalCount = $Nodes.Count, [bool]$HasNextPage = $false, $EndCursor = $null) {
  [ordered]@{
    totalCount = $TotalCount
    pageInfo = [ordered]@{ hasNextPage = $HasNextPage; endCursor = $EndCursor }
    nodes = [object[]]@($Nodes)
  }
}

function Test-FrontierCollectionBoundaries {
  # GetNewClosure creates a module that cannot resolve this script's helpers.
  # REST collection preserves 0/1/N array token kind.
  foreach ($case in @(
      [ordered]@{ name = "zero"; json = '[]'; count = 0 },
      [ordered]@{ name = "one"; json = '[{"id":"SYNTHETIC_REST_ONE"}]'; count = 1 },
      [ordered]@{ name = "many"; json = '[{"id":"SYNTHETIC_REST_N_1"},{"id":"SYNTHETIC_REST_N_2"}]'; count = 2 }
    )) {
    $endpoint = "repos/synthetic/collections-$($case.name)"
    $pagedEndpoint = "${endpoint}?per_page=100&page=1"
    $script:collectionRestResponses = @{ $pagedEndpoint = $case.json }
    $direct = Invoke-GhRestJson @($pagedEndpoint)
    $collection = Get-RestCollection $endpoint
    Assert-True ($direct.complete -eq $true -and $direct.value -is [Array] -and @($direct.value).Count -eq $case.count -and
      $collection.complete -eq $true -and @($collection.values).Count -eq $case.count) `
      "REST collection preserves $($case.name) array token kind"
  }
  $objectEndpoint = "repos/synthetic/top-level-object"
  $script:collectionRestResponses = @{ "$objectEndpoint`?per_page=100&page=1" = '{"id":"SYNTHETIC_NOT_A_COLLECTION"}' }
  $objectNegative = Get-RestCollection $objectEndpoint
  Assert-True ($objectNegative.complete -eq $false -and @($objectNegative.values).Count -eq 0) `
    "REST collection rejects a top-level object"
  $failureEndpoint = "repos/synthetic/provider-failure"
  $script:collectionRestResponses = @{ "$failureEndpoint`?per_page=100&page=1" = "SYNTHETIC_PROVIDER_FAILURE" }
  Assert-True ((Get-RestCollection $failureEndpoint).complete -eq $false) `
    "REST provider failure remains bounded unreadable"
  Write-Output "PASS REST collection preserves 0/1/N array token kind and rejects top-level objects"

  # The current live #7468/#7470 capture: #7468 has five complete edges and
  # every reached node is a complete zero-blocker leaf at the captured instant.
  $capturedBlockers = @{
    7468 = New-SyntheticConnection @(
      [ordered]@{ id = "I_kwDORKgVcc8AAAABOQplEA"; number = 7490; state = "OPEN" },
      [ordered]@{ id = "I_kwDORKgVcc8AAAABOK7jjA"; number = 7476; state = "OPEN" },
      [ordered]@{ id = "I_kwDORKgVcc8AAAABOHc9LQ"; number = 7475; state = "CLOSED" },
      [ordered]@{ id = "I_kwDORKgVcc8AAAABOFTNqg"; number = 7470; state = "OPEN" },
      [ordered]@{ id = "I_kwDORKgVcc8AAAABOEF7Mw"; number = 7469; state = "OPEN" }
    )
    7469 = New-SyntheticConnection @()
    7470 = New-SyntheticConnection @()
    7475 = New-SyntheticConnection @()
    7476 = New-SyntheticConnection @()
    7490 = New-SyntheticConnection @()
  }
  $capturedBlockerResults=@{}
  foreach($key in $capturedBlockers.Keys){$capturedBlockerResults[$key]=New-SyntheticGraphResult 'blockedBy' $capturedBlockers[$key]}
  $script:collectionGraphResponder = {
    param($Query, $Variables)
    $capturedBlockerResults[[int]$Variables.issue]
  }.GetNewClosure()
  $emptyBlockers = Get-FrontierIssueBlockers 7470
  Assert-True ($null -ne $emptyBlockers -and $emptyBlockers -is [object[]] -and $emptyBlockers.Count -eq 0) `
    "frontier dependency collection preserves a complete zero-element connection"
  $emptyCollapseMutant = & { [object[]]@() }
  Assert-True ($null -eq $emptyCollapseMutant) "empty-array-collapse mutant must reproduce the escaped null boundary"
  $closure = Get-FrontierClosure 7468
  Assert-True ($closure.complete -eq $true -and @($closure.rows).Count -eq 5 -and
    @($closure.rows | Where-Object { $_.parent -eq 7468 -and $_.number -eq 7470 }).Count -eq 1) `
    "repair closure preserves zero-blocker leaves"

  $script:collectionGraphResponder = {
    param($Query, $Variables)
    New-SyntheticGraphResult "labels" (New-SyntheticConnection @())
  }
  $emptyLabels = Get-FrontierIssueLabels 900001
  Assert-True ($null -ne $emptyLabels -and $emptyLabels -is [string[]] -and $emptyLabels.Count -eq 0) `
    "frontier label collection preserves a complete zero-element connection"
  Write-Output "PASS repair closure preserves zero-blocker leaves and zero-element label/blocker boundaries"

  # Dependency authority distinguishes empty from unreadable. Each row changes
  # only its named connection variable and compares the production candidate to
  # an explicit bypass that would incorrectly treat the shape as empty.
  $dependencyMutants = @(
    [ordered]@{ name = "unreadable"; responder = { param($q, $v) [pscustomobject][ordered]@{ complete = $false; reason = "SYNTHETIC_UNREADABLE"; payload = $null } } },
    [ordered]@{ name = "malformed-node"; responder = { param($q, $v) New-SyntheticGraphResult "blockedBy" (New-SyntheticConnection @([ordered]@{ id = "I_SYNTHETIC_ONLY"; number = 900002 })) } },
    [ordered]@{ name = "count-mismatch"; responder = { param($q, $v) New-SyntheticGraphResult "blockedBy" (New-SyntheticConnection @() 1) } },
    [ordered]@{ name = "pagination-incomplete"; responder = { param($q, $v) New-SyntheticGraphResult "blockedBy" (New-SyntheticConnection @() 0 $true $null) } },
    [ordered]@{ name = "moving-total"; responder = {
        param($q, $v)
        if ($v.cursor) { New-SyntheticGraphResult "blockedBy" (New-SyntheticConnection @([ordered]@{ id = "I_SYNTHETIC_2"; number = 900004; state = "OPEN" }) 3) }
        else { New-SyntheticGraphResult "blockedBy" (New-SyntheticConnection @([ordered]@{ id = "I_SYNTHETIC_1"; number = 900003; state = "OPEN" }) 2 $true "SYNTHETIC_CURSOR") }
      } }
  )
  foreach ($mutant in $dependencyMutants) {
    $script:collectionGraphResponder = $mutant.responder
    $candidate = Get-FrontierIssueBlockers 900000
    $bypass = [object[]]@()
    Assert-True ($null -eq $candidate -and $null -ne $bypass -and $bypass.Count -eq 0) `
      "dependency authority mutant $($mutant.name) was not distinguished from the empty bypass"
  }
  Write-Output "PASS dependency authority distinguishes empty from unreadable mutant table"

  # Exact live #7487 capture at its immutable head plus a separate, unmistakably
  # synthetic one-file control. Mutants never reuse the live PR identity.
  $captured7487Paths = @(
    ".github/workflows/platform-production.yml",
    "scripts/change-scope.mjs",
    "scripts/change-scope.test.mjs",
    "scripts/digitalocean-platform-config.test.mjs",
    "scripts/managed-postgres-authority-manifest.json",
    "scripts/platform-kubernetes-deployment.mjs",
    "scripts/platform-kubernetes-deployment.test.mjs"
  )
  $capturedFileResult=New-SyntheticGraphResult 'files' (New-SyntheticConnection @($captured7487Paths | ForEach-Object { [ordered]@{ path = $_ } }) 7)
  $script:collectionGraphResponder = {
    param($Query, $Variables)
    $capturedFileResult
  }.GetNewClosure()
  $capturedFiles = Get-FrontierPullRequestFiles 7487
  $capturedSet = [Collections.Generic.HashSet[string]]::new([Collections.Generic.IEnumerable[string]]$capturedFiles, [StringComparer]::Ordinal)
  Assert-True ($capturedFiles -is [string[]] -and $capturedSet.Count -eq 7 -and
    $capturedSet.Contains("scripts/platform-kubernetes-deployment.test.mjs")) `
    "live #7487 head 840a6ec66e70ec429cb674a1197977c9cef655e6 did not construct a seven-file ordinal typed set"

  $script:collectionGraphResponder = {
    param($Query, $Variables)
    New-SyntheticGraphResult "files" (New-SyntheticConnection @([ordered]@{ path = "synthetic/control/one-file.txt" }) 1)
  }
  $singleFiles = Get-FrontierPullRequestFiles 900010
  $singleSet = [Collections.Generic.HashSet[string]]::new([Collections.Generic.IEnumerable[string]]$singleFiles, [StringComparer]::Ordinal)
  Assert-True ($singleFiles -is [string[]] -and $singleSet.Count -eq 1 -and $singleSet.Contains("synthetic/control/one-file.txt")) `
    "synthetic single-file control did not construct an ordinal typed set"

  $fileMutants = @(
    [ordered]@{ name = "duplicate-canonical"; connection = New-SyntheticConnection @([ordered]@{ path = "synthetic/a.txt" }, [ordered]@{ path = "synthetic/a.txt" }) },
    [ordered]@{ name = "invalid-path"; connection = New-SyntheticConnection @([ordered]@{ path = "synthetic/../a.txt" }) },
    [ordered]@{ name = "normalization-bypass"; connection = New-SyntheticConnection @([ordered]@{ path = "synthetic\a.txt" }) },
    [ordered]@{ name = "ordinal-collision"; connection = New-SyntheticConnection @([ordered]@{ path = "Synthetic/A.txt" }, [ordered]@{ path = "synthetic/a.txt" }) },
    [ordered]@{ name = "count-mismatch"; connection = New-SyntheticConnection @([ordered]@{ path = "synthetic/a.txt" }) 2 },
    [ordered]@{ name = "pagination-incomplete"; connection = New-SyntheticConnection @() 0 $true $null }
  )
  foreach ($mutant in $fileMutants) {
    $connection = $mutant.connection
    $graphResult = New-SyntheticGraphResult "files" $connection
    $script:collectionGraphResponder = { param($Query, $Variables) $graphResult }.GetNewClosure()
    Assert-True ($null -eq (Get-FrontierPullRequestFiles 900011)) `
      "candidate file mutant $($mutant.name) did not fail closed"
  }
  Write-Output "PASS candidate files construct an ordinal typed set for live seven-file and synthetic single-file controls"

  # Drive the real configuration builder through the synthetic collaborators
  # REST lifecycle so 1-element token preservation is proven at its consumer.
  $rulesetSummary = '[{"id":17097957}]'
  $rulesetDetail = @{
    id = 17097957; name = "SYNTHETIC exact main queue"; target = "branch"; enforcement = "active"
    conditions = @{ ref_name = @{ include = @("refs/heads/main"); exclude = @() } }
    bypass_actors = @()
    rules = @(
      @{ type = "required_linear_history" },
      @{ type = "non_fast_forward" },
      @{ type = "required_status_checks"; parameters = @{ strict_required_status_checks_policy = $true; do_not_enforce_on_create = $false; required_status_checks = @(@{ context = "PR Required"; integration_id = 15368 }) } },
      @{ type = "merge_queue"; parameters = @{ merge_method = "SQUASH"; max_entries_to_build = 2; min_entries_to_merge = 1; max_entries_to_merge = 2; min_entries_to_merge_wait_minutes = 0; grouping_strategy = "ALLGREEN"; check_response_timeout_minutes = 60 } }
    )
  } | ConvertTo-Json -Compress -Depth 20
  $protection = @{
    enforce_admins = @{ enabled = $true }
    required_status_checks = @{ strict = $true; contexts = @("PR Required"); checks = @(@{ context = "PR Required"; app_id = 15368 }) }
    required_signatures = @{ enabled = $false }; required_linear_history = @{ enabled = $true }
    required_conversation_resolution = @{ enabled = $true }; allow_force_pushes = @{ enabled = $false }
    allow_deletions = @{ enabled = $false }; block_creations = @{ enabled = $false }
    lock_branch = @{ enabled = $false }; allow_fork_syncing = @{ enabled = $false }
  } | ConvertTo-Json -Compress -Depth 20
  $script:collectionRestResponses = @{
    "repos/chase-sets/chase-sets/rulesets?per_page=100&page=1" = $rulesetSummary
    "repos/chase-sets/chase-sets/collaborators?affiliation=all&per_page=100&page=1" = '[{"login":"synthetic-admin","id":9001,"node_id":"U_SYNTHETIC_ADMIN","role_name":"admin","permissions":{"admin":true,"maintain":true,"push":true,"triage":true,"pull":true}}]'
    "repos/chase-sets/chase-sets/branches/main/protection" = $protection
    "repos/chase-sets/chase-sets/rulesets/17097957" = $rulesetDetail
  }
  $repositoryCore = [ordered]@{
    autoMergeAllowed = $false; mergeCommitAllowed = $true; rebaseMergeAllowed = $true; squashMergeAllowed = $true; viewerPermission = "ADMIN"
    mergeQueue = [ordered]@{ mergeMethod = "SQUASH"; maximumEntriesToBuild = 2; maximumEntriesToMerge = 2; minimumEntriesToMerge = 1; minimumEntriesToMergeWaitTime = 0; checkResponseTimeout = 3600; mergingStrategy = "ALLGREEN" }
  }
  $configuration = Get-FrontierConfiguration $repositoryCore ([ordered]@{ complete = $true; pullRequests = @() })
  Assert-True ($configuration.complete -eq $true -and $configuration.value.writers.collaboratorCount -eq 1 -and
    $configuration.value.writers.collaborators[0].login -ceq "synthetic-admin" -and
    [string]$configuration.sha256 -cmatch '^[a-f0-9]{64}$') `
    "collaborators lifecycle did not produce a complete frontier configuration"
  Write-Output "PASS collaborators REST lifecycle reaches complete frontier configuration"
}

try {
  $mockGh = New-MockGh
  $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture "graph.json" (New-ProductionGraphFixture)
  $env:LANDING_PREFLIGHT_MOCK_RUNS = Write-JsonFixture "runs.json" (New-RealDeployRunFixture)
  $env:LANDING_PREFLIGHT_MOCK_LOG = Join-Path $testRoot "mock-gh.log"
  Set-RealDeployJobFixtures

  # #8526: synthetic queued, pre-merge observation through the real Report adapter.
  $queuedGraph=New-ProductionGraphFixture
  $queuedGraph.data.repository.pullRequest.mergeQueueEntry=@{id='MQE_SYNTHETIC_8526'}
  $env:LANDING_PREFLIGHT_MOCK_GRAPH=Write-JsonFixture 'queued-8526.json' $queuedGraph
  $queuedReport=Invoke-ProductionPreflight (New-History @((New-Pass $headA)))
  Assert-True ($queuedReport.reason -ceq 'PR_ALREADY_ENQUEUED' -and $queuedReport.mutationCount -eq 0) 'queued refusal remains intact'
  Assert-True ($null -ne $queuedReport.velocityLanding -and $queuedReport.velocityLanding.nonHoldPrerequisites.status -ceq 'eligible') 'queued-landing-capture: queued green Report must expose canonical non-hold reductions'
  $env:LANDING_PREFLIGHT_MOCK_GRAPH=Write-JsonFixture 'graph.json' (New-ProductionGraphFixture)

  if ($RegressionOnly -in @('All', 'RequiredCheckReducerOnly')) {
    $requiredHistory = New-History @((New-Pass $headA))
    $singletonProduction = Invoke-ProductionPreflight $requiredHistory
    Assert-True ($null -ne $singletonProduction.observations.initial.pr.requiredCheckReductions) `
      "the production singleton did not reach required-check reduction (observed=$($singletonProduction | ConvertTo-Json -Compress -Depth 20))"
    $singletonReduction = $singletonProduction.observations.initial.pr.requiredCheckReductions[0]
    Assert-True ($singletonProduction.status -ceq 'eligible' -and
      $singletonProduction.mutationCount -eq 0 -and
      $singletonProduction.observations.initial.pr.checkCollection.complete -eq $true -and
      $singletonProduction.observations.initial.pr.checkCollection.exactHead -ceq $headA -and
      $singletonProduction.observations.initial.pr.checkCollection.totalCount -eq 1 -and
      $singletonProduction.observations.initial.pr.checkCollection.returnedCount -eq 1 -and
      $singletonProduction.observations.initial.pr.checks[0].schemaVersion -ceq 'required-check-observation/v1' -and
      $singletonProduction.observations.initial.pr.checks[0].valid -eq $true -and
      $singletonReduction.schemaVersion -ceq 'required-check-reducer/v1' -and
      $singletonReduction.status -ceq 'eligible' -and
      $singletonReduction.selected.databaseId -eq [long]9007199254740001 -and
      $singletonReduction.superseded.Count -eq 0) `
      'the production reader did not retain the closed singleton CheckRun identity, exact-head collection proof, and reducer provenance'

    $captured7730Head = '47c44ad0235c7d0e8843974eee7583e90c9aab01'
    $captured7730Pass = New-Pass $captured7730Head
    $captured7730Pass.pr = 7730
    $captured7730History = New-History @($captured7730Pass)
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture 'captured-7730-production-graph.json' (New-Captured7730ProductionGraphFixture)
    $captured7730 = Invoke-ProductionPreflight $captured7730History 7730
    $captured7730Reduction = $captured7730.observations.initial.pr.requiredCheckReductions[0]
    Assert-True ($captured7730.status -ceq 'eligible' -and
      $captured7730.mutationCount -eq 0 -and
      $captured7730.observations.initial.pr.checkCollection.exactHead -ceq $captured7730Head -and
      $captured7730.observations.initial.pr.checkCollection.totalCount -eq 61 -and
      $captured7730.observations.initial.pr.checkCollection.returnedCount -eq 61 -and
      $captured7730.observations.initial.pr.checkCollection.complete -eq $true -and
      $captured7730Reduction.matchCount -eq 2 -and
      $captured7730Reduction.selected.databaseId -eq [long]101873180043 -and
      $captured7730Reduction.selected.completedAt -ceq '2026-09-07T21:51:57Z' -and
      $captured7730Reduction.selected.producer.appDatabaseId -eq 15368 -and
      $captured7730Reduction.selected.producer.workflowDatabaseId -eq 274293632 -and
      $captured7730Reduction.superseded.Count -eq 1 -and
      $captured7730Reduction.superseded[0].databaseId -eq [long]101867362343 -and
      $captured7730Reduction.superseded[0].completedAt -ceq '2026-09-07T21:17:58Z') `
      "the unchanged complete 61/61 real #7730 capture did not select its newest same-producer terminal success (observed=$($captured7730 | ConvertTo-Json -Compress -Depth 20))"
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture 'graph-after-captured-7730.json' (New-ProductionGraphFixture)

    $rawProductionCases = @(
      [ordered]@{
        name = 'ordinary-success'
        nodes = @(
          (New-SyntheticRequiredCheckRawNode 9007199254741001 '2030-02-01T00:00:00Z'),
          (New-SyntheticRequiredCheckRawNode 9007199254741002 '2030-02-02T00:00:00Z')
        )
        status = 'eligible'; reason = 'REPORT_ONLY_ELIGIBLE'
        selected = [long]9007199254741002; superseded = [long]9007199254741001
      },
      [ordered]@{
        name = 'success-id-time-disagreement'
        nodes = @(
          (New-SyntheticRequiredCheckRawNode 9007199254742002 '2030-03-01T00:00:00Z'),
          (New-SyntheticRequiredCheckRawNode 9007199254742001 '2030-03-02T00:00:00Z')
        )
        status = 'eligible'; reason = 'REPORT_ONLY_ELIGIBLE'
        selected = [long]9007199254742001; superseded = [long]9007199254742002
      },
      [ordered]@{
        name = 'success-equal-timestamp'
        nodes = @(
          (New-SyntheticRequiredCheckRawNode 9007199254743001 '2030-04-01T00:00:00Z'),
          (New-SyntheticRequiredCheckRawNode 9007199254743002 '2030-04-01T00:00:00Z')
        )
        status = 'eligible'; reason = 'REPORT_ONLY_ELIGIBLE'
        selected = [long]9007199254743002; superseded = [long]9007199254743001
      },
      [ordered]@{
        name = 'newest-failure'
        nodes = @(
          (New-SyntheticRequiredCheckRawNode 9007199254744001 '2030-05-01T00:00:00Z'),
          (New-SyntheticRequiredCheckRawNode 9007199254744002 '2030-05-02T00:00:00Z' 'FAILURE')
        )
        status = 'refused'; reason = 'REQUIRED_CHECK_NOT_GREEN'
        selected = [long]9007199254744002; superseded = [long]9007199254744001
      },
      [ordered]@{
        name = 'newest-cancelled'
        nodes = @(
          (New-SyntheticRequiredCheckRawNode 9007199254745001 '2030-05-01T00:00:00Z'),
          (New-SyntheticRequiredCheckRawNode 9007199254745002 '2030-05-02T00:00:00Z' 'CANCELLED')
        )
        status = 'refused'; reason = 'REQUIRED_CHECK_NOT_GREEN'
        selected = [long]9007199254745002; superseded = [long]9007199254745001
      },
      [ordered]@{
        name = 'newest-timed-out'
        nodes = @(
          (New-SyntheticRequiredCheckRawNode 9007199254746001 '2030-05-01T00:00:00Z'),
          (New-SyntheticRequiredCheckRawNode 9007199254746002 '2030-05-02T00:00:00Z' 'TIMED_OUT')
        )
        status = 'refused'; reason = 'REQUIRED_CHECK_NOT_GREEN'
        selected = [long]9007199254746002; superseded = [long]9007199254746001
      }
    )
    foreach ($rawCase in $rawProductionCases) {
      foreach ($orderIndex in 0..1) {
        $orderedNodes = if ($orderIndex -eq 0) {
          [object[]]@($rawCase.nodes[0], $rawCase.nodes[1])
        } else {
          [object[]]@($rawCase.nodes[1], $rawCase.nodes[0])
        }
        $control = Invoke-RawRequiredCheckProductionFixture $orderedNodes "$($rawCase.name)-order-$orderIndex" $requiredHistory
        $observed = $control.result
        $reduction = $observed.observations.initial.pr.requiredCheckReductions[0]
        Assert-True ($control.inputUnchanged -eq $true -and
          $observed.status -ceq $rawCase.status -and $observed.reason -ceq $rawCase.reason -and
          $observed.mutationCount -eq 0 -and
          $observed.observations.initial.pr.checkCollection.complete -eq $true -and
          $observed.observations.initial.pr.checkCollection.exactHead -ceq $headA -and
          $observed.observations.initial.pr.checkCollection.totalCount -eq 2 -and
          $observed.observations.initial.pr.checkCollection.returnedCount -eq 2 -and
          @($observed.observations.initial.pr.checks | Where-Object { $_.valid -ne $true }).Count -eq 0 -and
          $reduction.status -ceq $rawCase.status -and
          $reduction.selected.databaseId -eq $rawCase.selected -and
          $reduction.superseded.Count -eq 1 -and
          $reduction.superseded[0].databaseId -eq $rawCase.superseded) `
          "raw production required-check case $($rawCase.name) order $orderIndex changed input, mutated, or selected inconsistently"
      }
    }
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture 'graph-after-raw-required-checks.json' (New-ProductionGraphFixture)

    $olderGreen = New-SyntheticRequiredCheckProjection 9000000000000101 '2030-01-01T00:00:00Z'
    $newerGreen = New-SyntheticRequiredCheckProjection 9000000000000102 '2030-01-02T00:00:00Z'
    $pair = Invoke-RequiredCheckFixture @($olderGreen, $newerGreen)
    $pairReduction = $pair.observations.initial.pr.requiredCheckReductions[0]
    Assert-True ($pair.status -ceq 'eligible' -and $pair.mutationCount -eq 0 -and
      $pairReduction.selected.databaseId -eq [long]9000000000000102 -and
      $pairReduction.superseded.Count -eq 1 -and
      $pairReduction.superseded[0].databaseId -eq [long]9000000000000101) `
      'same-producer terminal success observations did not select newest before outcome with bounded provenance'

    foreach ($newestConclusion in @('FAILURE', 'CANCELLED', 'TIMED_OUT')) {
      $newest = New-SyntheticRequiredCheckProjection 9000000000000102 '2030-01-02T00:00:00Z' 'COMPLETED' $newestConclusion
      $newestRefusal = Invoke-RequiredCheckFixture @($newest, $olderGreen)
      $newestReduction = $newestRefusal.observations.initial.pr.requiredCheckReductions[0]
      Assert-True ($newestRefusal.status -ceq 'refused' -and
        $newestRefusal.reason -ceq 'REQUIRED_CHECK_NOT_GREEN' -and
        $newestRefusal.mutationCount -eq 0 -and
        $newestReduction.selected.databaseId -eq [long]9000000000000102 -and
        $newestReduction.selected.conclusion -ceq $newestConclusion -and
        $newestReduction.superseded[0].databaseId -eq [long]9000000000000101) `
        "an older green overrode newest $newestConclusion or input order influenced selection"
    }

    $nonterminal = New-SyntheticRequiredCheckProjection 9000000000000102 '' 'IN_PROGRESS' $null
    $nonterminalResult = Invoke-RequiredCheckFixture @($olderGreen, $nonterminal)
    Assert-True ($nonterminalResult.status -ceq 'refused' -and
      $nonterminalResult.reason -ceq 'REQUIRED_CHECK_NONTERMINAL' -and
      $nonterminalResult.mutationCount -eq 0 -and
      $null -eq $nonterminalResult.observations.initial.pr.requiredCheckReductions[0].selected) `
      'nonterminal required authority was ordered or selected'

    $differentProducer = Copy-TestValue $newerGreen
    $differentProducer.producer.workflowDatabaseId = [long]9000000000000999
    $mixed = New-SyntheticStatusContextProjection
    $duplicateStatus = Copy-TestValue $mixed
    $malformed = Copy-TestValue $newerGreen
    $malformed.valid = $false
    $malformed.reason = 'REQUIRED_CHECK_IDENTITY_MALFORMED'
    $contradictory = Copy-TestValue $newerGreen
    $contradictory.databaseId = [long]9000000000000100
    $contradictory.conclusion = 'FAILURE'
    $duplicateId = Copy-TestValue $newerGreen
    $duplicateId.databaseId = [long]9000000000000101
    $tie = Copy-TestValue $newerGreen
    $tie.completedAt = '2030-01-01T00:00:00Z'
    $tie.conclusion = 'FAILURE'
    $negativeCases = [ordered]@{
      differentProducer = [ordered]@{ checks = @($olderGreen, $differentProducer); reason = 'REQUIRED_CHECK_PRODUCER_MISMATCH' }
      mixedShapes = [ordered]@{ checks = @($olderGreen, $mixed); reason = 'REQUIRED_CHECK_MIXED_NODE_TYPES' }
      duplicateStatusContext = [ordered]@{ checks = @($mixed, $duplicateStatus); reason = 'REQUIRED_STATUS_CONTEXT_DUPLICATE' }
      malformedKnownIdentity = [ordered]@{ checks = @($olderGreen, $malformed); reason = 'REQUIRED_CHECK_IDENTITY_MALFORMED' }
      idTimeContradiction = [ordered]@{ checks = @($olderGreen, $contradictory); reason = 'REQUIRED_CHECK_ORDER_CONTRADICTION' }
      duplicateCheckRunId = [ordered]@{ checks = @($olderGreen, $duplicateId); reason = 'REQUIRED_CHECK_DUPLICATE_ID' }
      unresolvedTie = [ordered]@{ checks = @($olderGreen, $tie); reason = 'REQUIRED_CHECK_ORDER_TIE' }
    }
    foreach ($entry in $negativeCases.GetEnumerator()) {
      $negative = Invoke-RequiredCheckFixture ([object[]]$entry.Value.checks)
      Assert-True ($negative.status -ceq 'unknown' -and
        $negative.reason -ceq $entry.Value.reason -and
        $negative.mutationCount -eq 0) `
        "one-variable required-check negative $($entry.Key) did not fail closed distinctly"
    }

    $statusSingleton = Invoke-RequiredCheckFixture @($mixed)
    Assert-True ($statusSingleton.status -ceq 'eligible' -and
      $statusSingleton.observations.initial.pr.requiredCheckReductions[0].selected.nodeType -ceq 'StatusContext') `
      'singleton StatusContext compatibility was not preserved'

    $finalAmbiguous = Invoke-RequiredCheckFixture @($olderGreen, $newerGreen) @($olderGreen, $differentProducer) 'Apply'
    Assert-True ($finalAmbiguous.status -ceq 'unknown' -and
      $finalAmbiguous.reason -ceq 'REQUIRED_CHECK_PRODUCER_MISMATCH' -and
      $finalAmbiguous.mutationCount -eq 0) `
      'Apply did not re-read a final ambiguous required-check producer before mutation'

    $invalidGraph = New-ProductionGraphFixture
    $invalidGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].checkSuite.app.syntheticUnknown = 'forbidden'
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture 'required-check-nested-unknown.json' $invalidGraph
    $nestedUnknown = Invoke-ProductionPreflight $requiredHistory
    Assert-True ($nestedUnknown.status -ceq 'unknown' -and
      $nestedUnknown.reason -ceq 'REQUIRED_CHECK_IDENTITY_MALFORMED' -and
      $nestedUnknown.mutationCount -eq 0) `
      'the production projection accepted a nested unknown producer key'

    $invalidGraph = New-ProductionGraphFixture
    [void]$invalidGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].checkSuite.workflowRun.Remove('workflow')
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture 'required-check-omitted-workflow.json' $invalidGraph
    $omittedWorkflow = Invoke-ProductionPreflight $requiredHistory
    Assert-True ($omittedWorkflow.status -ceq 'unknown' -and
      $omittedWorkflow.reason -ceq 'REQUIRED_CHECK_IDENTITY_MALFORMED' -and
      $omittedWorkflow.mutationCount -eq 0) `
      'the production projection accepted omitted workflow producer identity'

    $invalidGraph = New-ProductionGraphFixture
    $invalidGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].checkSuite.app.databaseId = '9007199254740002'
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture 'required-check-string-app-id.json' $invalidGraph
    $stringAppId = Invoke-ProductionPreflight $requiredHistory
    Assert-True ($stringAppId.status -ceq 'unknown' -and
      $stringAppId.reason -ceq 'REQUIRED_CHECK_IDENTITY_MALFORMED' -and
      $stringAppId.mutationCount -eq 0) `
      'the production projection accepted a string-coerced app database identity'

    $invalidGraph = New-ProductionGraphFixture
    $invalidGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].completedAt = '2030-01-01'
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture 'required-check-date-only.json' $invalidGraph
    $dateOnly = Invoke-ProductionPreflight $requiredHistory
    Assert-True ($dateOnly.status -ceq 'unknown' -and
      $dateOnly.reason -ceq 'REQUIRED_CHECK_IDENTITY_MALFORMED' -and
      $dateOnly.mutationCount -eq 0) `
      'the production projection accepted a date-only completion instant'

    $invalidGraph = New-ProductionGraphFixture
    $invalidGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount = 2
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture 'required-check-incomplete-page.json' $invalidGraph
    $incompletePage = Invoke-ProductionPreflight $requiredHistory
    Assert-True ($incompletePage.status -ceq 'unknown' -and
      $incompletePage.reason -ceq 'CHECK_PAGINATION_INCOMPLETE' -and
      $incompletePage.mutationCount -eq 0) `
      'an incomplete required-check collection reached the reducer'

    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture 'graph-required-restored.json' (New-ProductionGraphFixture)
    Write-Output 'PASS required-check raw production projection, all-success ordering, input-order independence, no mutation, newest-red refusal, provenance, refusal matrix, pagination, final reread, and closed nested identity'
    if ($RegressionOnly -eq 'RequiredCheckReducerOnly') { return }
  }

  if ($RegressionOnly -in @("All", "Decision7643AdapterOnly")) {
    $productionShape = New-Decision7643Observation
    Assert-True ($productionShape.decision7643Adapter.decision.comments -is [object[]] -and
      $productionShape.decision7643Adapter.decision.comments.Count -eq 1 -and
      $productionShape.decision7643Adapter.decision.comments[0] -is [Collections.Specialized.OrderedDictionary] -and
      $productionShape.decision7643Adapter.breakerAuthority.current.openRows -is [object[]] -and
      $productionShape.decision7643Adapter.breakerAuthority.current.openRows.Count -eq 1 -and
      $productionShape.decision7643Adapter.breakerAuthority.current.openRows[0] -is [Collections.Specialized.OrderedDictionary] -and
      $productionShape.decision7643Adapter.openPullRequests.pullRequests -is [object[]] -and
      $productionShape.decision7643Adapter.openPullRequests.pullRequests.Count -eq 1 -and
      $productionShape.decision7643Adapter.openPullRequests.pullRequests[0] -is [Collections.Specialized.OrderedDictionary]) `
      "Decision #7643 production-shape control did not retain singleton OrderedDictionary collections"
    $productionShapeResult = Invoke-Decision7643ProductionShapeControl $productionShape
    Assert-True ($productionShapeResult.admitted -eq $true -and
      $productionShapeResult.exactRuling -eq $true -and
      $productionShapeResult.exactRetainedBreaker -eq $true -and
      $productionShapeResult.collisionFree -eq $true) `
      "Decision #7643 production reducer rejected singleton OrderedDictionary authority collections"

    # Keep the subprocess JSON fixture as a separate serialization-boundary control.
    $positive = New-Decision7643Observation
    $report = Invoke-Decision7643Fixture @($positive) "Report"
    Assert-True ($report.status -ceq "eligible" -and $report.reason -ceq "REPORT_ONLY_ELIGIBLE" -and
      $report.mutationCount -eq 0 -and $report.enqueueAttempts -eq 0 -and $report.dequeueAttempts -eq 0 -and
      $report.admission.schemaVersion -ceq "decision-7643-pr-7641-landing-adapter-admission/v1" -and
      $report.admission.decision -ceq "DECISION_7643_PR_7641_ADAPTER_ADMITTED" -and
      -not ([string]$report.admission.schemaVersion).Contains("frontier", [StringComparison]::OrdinalIgnoreCase)) `
      "Decision #7643 Report did not expose the exact PR #7641 adapter as a distinct mutation-free admission"

    $apply = Invoke-Decision7643Fixture @(
      (New-Decision7643Observation),
      (New-Decision7643Observation),
      (New-Decision7643Observation -Audit)
    ) "Apply"
    Assert-True ($apply.status -ceq "enqueued" -and $apply.reason -ceq "ENQUEUE_CONFIRMED" -and
      $apply.mutationCount -eq 1 -and $apply.enqueueAttempts -eq 1 -and $apply.dequeueAttempts -eq 0 -and
      $apply.admission.preMutation.reason -ceq "DECISION_7643_PR_7641_ADAPTER_ADMITTED" -and
      $apply.admission.mutation.schemaVersion -ceq "decision-7643-pr-7641-landing-adapter-mutation/v1" -and
      $apply.admission.audit.schemaVersion -ceq "decision-7643-pr-7641-landing-adapter-audit/v1" -and
      $apply.admission.audit.decision -ceq "confirmed") `
      "Decision #7643 adapter did not retain the one-enqueue exact-head enforcing audit"

    $hardDisabled = Invoke-Decision7643Fixture @((New-Decision7643Observation)) "Apply" "" -MutationDisabled
    Assert-True ($hardDisabled.status -ceq "refused" -and $hardDisabled.reason -ceq "MUTATION_HARD_DISABLED" -and
      $hardDisabled.mutationCount -eq 0 -and $hardDisabled.enqueueAttempts -eq 0 -and $hardDisabled.dequeueAttempts -eq 0) `
      "Decision #7643 adapter crossed the mutation-disabled Apply fuse"

    $authorityNearMisses = [ordered]@{
      wrongPr = { param($o) $o.pr.number = 7642 }
      wrongHead = { param($o) $o.decision7643Adapter.candidate.headOid = $decision7643OtherHead }
      wrongBreakerTs = { param($o) $o.decision7643Adapter.breakerAuthority.row.ts = "2026-09-03T21:47:13.445Z" }
      wrongBreakerIssue = { param($o) $o.decision7643Adapter.breakerAuthority.row.issue = 7559 }
      wrongBreakerPr = { param($o) $o.decision7643Adapter.breakerAuthority.row.pr = 7632 }
      wrongBreakerOutcome = { param($o) $o.decision7643Adapter.breakerAuthority.row.outcome = "SYNTHETIC_OTHER_OUTCOME" }
      wrongBreakerScope = { param($o) $o.decision7643Adapter.breakerAuthority.row.breakerScope = "artifact" }
      wrongBreakerDigest = { param($o) $o.decision7643Adapter.breakerAuthority.row.rowSha256 = "f" * 64 }
      wrongBreakerLine = { param($o) $o.decision7643Adapter.breakerAuthority.row.line = 14531 }
      missingDecisionComment = { param($o) $o.decision7643Adapter.decision.comments = @() }
      extraDecisionComment = {
        param($o)
        $extra = Copy-TestValue $o.decision7643Adapter.decision.comments[0]
        $extra.id = [long]5541242255
        $extra.url = "https://github.com/chase-sets/chase-sets/issues/7643#issuecomment-5541242255"
        $o.decision7643Adapter.decision.comments += $extra
      }
      changedDecisionComment = { param($o) $o.decision7643Adapter.decision.comments[0].bodySha256 = "f" * 64 }
      nonToddAuthor = { param($o) $o.decision7643Adapter.decision.comments[0].author.login = "synthetic-not-todd" }
      decisionOpen = { param($o) $o.decision7643Adapter.decision.decision.state = "OPEN" }
      decisionNotCompleted = { param($o) $o.decision7643Adapter.decision.decision.stateReason = "NOT_PLANNED" }
      additionalPipelineBreaker = {
        param($o)
        $extra = [ordered]@{ key = "9000/9001"; openTs = "2026-09-04T14:01:00Z"; line = 14531; rowSha256 = "e" * 64; byteLength = 100 }
        $o.breaker.open += "9000/9001"
        $o.breaker.openRows += $extra
      }
      collision = {
        param($o)
        $o.decision7643Adapter.openPullRequests.pullRequests += [ordered]@{ id = "PR_SYNTHETIC_7642"; number = 7642; isDraft = $false; headOid = $decision7643OtherHead; autoMerge = $false; files = @("deployables/platform-api/src/auth/synthetic.ts") }
        $o.decision7643Adapter.collisions = @([ordered]@{ pr = 7642; path = "deployables/platform-api/src/auth/synthetic.ts" })
      }
      nonemptyQueue = { param($o) $o.decision7643Adapter.queue.totalCount = 1; $o.decision7643Adapter.queue.entries = @([ordered]@{ id = "MQE_SYNTHETIC_OTHER" }) }
    }
    $nearMissResults = [ordered]@{}
    foreach ($case in $authorityNearMisses.GetEnumerator()) {
      $observation = New-Decision7643Observation
      & $case.Value $observation
      $result = Invoke-Decision7643Fixture @($observation) "Report"
      $nearMissResults[$case.Key] = $result
      Assert-True ($result.status -in @("refused", "unknown") -and $result.mutationCount -eq 0) `
        "Decision #7643 adapter authority near miss $($case.Key) was admitted"
    }

    $staleReview = Invoke-Decision7643Fixture @((New-Decision7643Observation)) "Report" (New-History @((New-Decision7643Pass $decision7643OtherHead)))
    Assert-True ($staleReview.status -ceq "refused" -and $staleReview.reason -like "REVIEW_STALE_*" -and $staleReview.mutationCount -eq 0) `
      "Decision #7643 adapter accepted stale independent review authority"
    $redCheckObservation = New-Decision7643Observation
    $redCheckObservation.pr.checks[0].outcome = "failure"
    $redCheck = Invoke-Decision7643Fixture @($redCheckObservation) "Report"
    Assert-True ($redCheck.status -ceq "refused" -and $redCheck.reason -ceq "REQUIRED_CHECK_NOT_GREEN" -and $redCheck.mutationCount -eq 0) `
      "Decision #7643 adapter accepted a red required check"
    $redRollupObservation = New-Decision7643Observation
    $redRollupObservation.pr.statusRollupState = "FAILURE"
    $redRollup = Invoke-Decision7643Fixture @($redRollupObservation) "Report"
    Assert-True ($redRollup.status -ceq "refused" -and $redRollup.reason -ceq "CHECK_ROLLUP_NOT_GREEN" -and $redRollup.mutationCount -eq 0) `
      "Decision #7643 adapter accepted a red check rollup"
    $redDeployObservation = New-Decision7643Observation
    $redDeployObservation.deploy.conclusion = "failure"
    $redDeploy = Invoke-Decision7643Fixture @($redDeployObservation) "Report"
    Assert-True ($redDeploy.status -ceq "refused" -and $redDeploy.reason -ceq "DEPLOY_UNHEALTHY" -and $redDeploy.mutationCount -eq 0) `
      "Decision #7643 adapter accepted unhealthy deploy authority"

    $initial = New-Decision7643Observation
    $drifted = New-Decision7643Observation
    $drifted.decision7643Adapter.decision.decision.updatedAt = "2026-09-04T13:40:32Z"
    $betweenReads = Invoke-Decision7643Fixture @($initial, $drifted) "Apply"
    Assert-True ($betweenReads.status -ceq "refused" -and $betweenReads.reason -ceq "PIPELINE_BREAKER_OPEN" -and
      $betweenReads.mutationCount -eq 0 -and $betweenReads.enqueueAttempts -eq 0) `
      "Decision #7643 authority drift between reads reached enqueue"

    $auditDrift = New-Decision7643Observation -Audit
    $auditDrift.decision7643Adapter.decision.comments[0].updatedAt = "2026-09-04T13:37:31Z"
    $recovered = Invoke-Decision7643Fixture @(
      (New-Decision7643Observation),
      (New-Decision7643Observation),
      $auditDrift
    ) "Apply"
    Assert-True ($recovered.status -ceq "refused" -and $recovered.reason -ceq "ADMISSION_COMPROMISE_RECOVERED" -and
      $recovered.mutationCount -eq 2 -and $recovered.enqueueAttempts -eq 1 -and $recovered.dequeueAttempts -eq 1 -and
      $recovered.admission.audit.schemaVersion -ceq "decision-7643-pr-7641-landing-adapter-audit/v1") `
      "Decision #7643 post-enqueue authority drift did not trigger the enforcing one-dequeue recovery"

    $changedComment = $nearMissResults.changedDecisionComment
    $bypassSurvivors = @($changedComment.admission.conjuncts.PSObject.Properties |
      Where-Object { $_.Name -cne "exactRuling" -and $_.Value -ne $true })
    Assert-True ($changedComment.admission.conjuncts.exactRuling -eq $false -and $bypassSurvivors.Count -eq 0) `
      "isolated exact-ruling bypass mutant was not admission-revealing"
    $isolatedBypassMutantWouldAdmit = $bypassSurvivors.Count -eq 0
    Assert-True ($changedComment.status -ceq "refused" -and $isolatedBypassMutantWouldAdmit) `
      "removing the new exact Decision authority check did not demonstrate forbidden admission"

    $source = Get-Content -LiteralPath $preflight -Raw
    foreach ($requiredSource in @(
        "decision-7643-pr-7641-landing-adapter-admission/v1",
        "decision-7643-pr-7641-landing-adapter-mutation/v1",
        "decision-7643-pr-7641-landing-adapter-audit/v1",
        '$decision7643RulingCommentId = 5541242254',
        '$decision7643BreakerLine = 14530',
        '$decision7643CandidateHead = "d3175a021e5fd958b60eda1500b5e1d072bbf195"'
      )) {
      Assert-True ($source.Contains($requiredSource, [StringComparison]::Ordinal)) "Decision #7643 adapter wiring omits $requiredSource"
    }
    Assert-True (@([regex]::Matches($source, 'enqueuePullRequest\(input:')).Count -eq 1 -and
      @([regex]::Matches($source, 'dequeuePullRequest\(input:')).Count -eq 1) `
      "Decision #7643 adapter introduced a second mutation definition"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "decision-7643-authority.json"))) `
      "Decision #7643 tests wrote a mutable authority record"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "provider-sentinel-must-not-run.exe"))) `
      "Decision #7643 fixture path invoked or materialized a provider sentinel"
    Write-Output "PASS Decision #7643/#7641 exact live-authority adapter, one-variable refusal matrix, two-read drift, audit recovery, mutation fuse, and bypass mutant"
    if ($RegressionOnly -eq "Decision7643AdapterOnly") { return }
  }

  if ($RegressionOnly -in @("All", "BreakerRepairFrontierOnly")) {
    $savedProviderEnvironment = [ordered]@{}
    foreach ($name in @("GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR")) {
      $savedProviderEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
      [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    try {
      $positive = New-FrontierObservation
      $report = Invoke-FrontierFixture @($positive) "Report"
      Assert-True ($report.schema -ceq "landing-preflight/v1" -and $report.status -ceq "eligible" -and
        $report.reason -ceq "REPORT_ONLY_ELIGIBLE" -and $report.mutationCount -eq 0 -and
        $report.enqueueAttempts -eq 0 -and $report.dequeueAttempts -eq 0 -and
        $report.admission.decision -ceq "BREAKER_REPAIR_FRONTIER_ADMITTED" -and
        @($report.admission.collisions).Count -eq 0) `
        "Report exposes repair admission only through the additive record (observed=$($report | ConvertTo-Json -Compress -Depth 20))"

      $recordAbsentObservation = New-FrontierObservation
      $recordAbsentObservation.admission.authorityRecord.present = $false
      $recordAbsentObservation.admission.authorityRecord.raw = $null
      $recordAbsent = Invoke-FrontierFixture @($recordAbsentObservation) "Report"
      Assert-True ($recordAbsent.status -ceq "refused" -and $recordAbsent.reason -ceq "PIPELINE_BREAKER_OPEN" -and
        $recordAbsent.mutationCount -eq 0 -and $recordAbsent.enqueueAttempts -eq 0 -and $recordAbsent.dequeueAttempts -eq 0 -and
        $recordAbsent.admission.decision -ceq "BREAKER_REPAIR_FRONTIER_REFUSED" -and
        [int]$recordAbsent.admission.seed.candidate.pr -eq 7470 -and
        [string]$recordAbsent.admission.seed.candidate.headOid -ceq $repairHead -and
        [string]$recordAbsent.admission.seed.candidate.baseOid -ceq $repairBase -and
        [string]$recordAbsent.admission.configurationSha256 -ceq [string]$recordAbsent.admission.configurationComputedSha256) `
        "record-absent Report remains mutation-free PIPELINE_BREAKER_OPEN while publishing the exact seed and configuration fingerprint"
      Write-Output "PASS matching-record REPORT_ONLY_ELIGIBLE versus record-absent mutation-free PIPELINE_BREAKER_OPEN"

      $apply = Invoke-FrontierFixture @((New-FrontierObservation), (New-FrontierObservation), (New-FrontierObservation -Audit)) "Apply"
      Assert-True ($apply.status -ceq "enqueued" -and $apply.reason -ceq "ENQUEUE_CONFIRMED" -and
        $apply.mutationCount -eq 1 -and $apply.enqueueAttempts -eq 1 -and $apply.dequeueAttempts -eq 0 -and
        $apply.admission.preMutation.status -ceq "eligible" -and
        $apply.admission.preMutation.reason -ceq "BREAKER_REPAIR_FRONTIER_ADMITTED" -and
        $apply.admission.audit.decision -ceq "confirmed") `
        "Apply exposes admitted reason before one enqueue and the audit confirms exactly one unchanged repair entry (observed=$($apply | ConvertTo-Json -Compress -Depth 100))"

      $nearMisses = [ordered]@{}
      $nearMisses.absentRecord = { param($o) $o.admission.authorityRecord.present = $false; $o.admission.authorityRecord.raw = $null }
      $nearMisses.extraRecordKey = { param($o) Set-FrontierAuthorityRaw $o -ExtraRoot }
      $nearMisses.duplicateRecordKey = { param($o) $o.admission.authorityRecord.raw = $o.admission.authorityRecord.raw.Replace('{"schemaVersion":', '{"schemaVersion":"breaker-repair-frontier-authority/v1","schemaVersion":') }
      $nearMisses.expiredRecord = { param($o) $o.admission.authorityRecord.raw = $o.admission.authorityRecord.raw.Replace('2026-08-25T13:00:00Z', '2026-08-25T11:30:00Z') }
      $nearMisses.crInclusiveBreaker = { param($o) $o.breaker.openRows[0].rowSha256 = "5037b89d4daee1ab5018ed16d6a29e3d6dbf31f13c0c57821e647021be0ad105"; $o.admission.breaker = $o.breaker }
      $nearMisses.crlfInclusiveBreaker = { param($o) $o.breaker.openRows[0].rowSha256 = "507878b95261a853ea24882b274498d679c63f2c5d4a15fdc0153a749f346dea"; $o.admission.breaker = $o.breaker }
      $nearMisses.secondBreaker = { param($o) $o.breaker.open += "9999/9999"; $o.breaker.openRows += [ordered]@{ key = "9999/9999"; openTs = "2026-08-25T11:30:00Z"; line = 12000; rowSha256 = "e" * 64; byteLength = 100 }; $o.admission.breaker = $o.breaker }
      $nearMisses.changedAuthorityBody = { param($o) $o.admission.authorityIssue.bodySha256 = "e" * 64 }
      $nearMisses.trimmedRepairBody = { param($o) $o.admission.repair.issue.bodySha256 = "ec7353fa5fa467c94bef6419287a0ee1a6353eb6b4d8266fa1b7d0bcd95d047f" }
      $nearMisses.notInClosure = { param($o) $o.admission.root.closure = @() }
      $nearMisses.closedRepair = { param($o) $o.admission.repair.issue.state = "CLOSED" }
      $nearMisses.trackingRepair = { param($o) $o.admission.repair.labels += "status:tracking-only" }
      $nearMisses.differentClosingEdge = { param($o) $o.admission.candidate.closingIssues = @(7469) }
      $nearMisses.staleBase = { param($o) $o.admission.candidate.mergeBaseOid = "f" * 40 }
      $nearMisses.incompleteFiles = { param($o) $o.admission.candidate.filesComplete = $false }
      $nearMisses.nonemptyQueue = { param($o) $o.admission.queue.entries = @([ordered]@{ id = "MQE_OTHER" }) }
      $nearMisses.openSiblingCollision = {
        param($o)
        $o.admission.openPullRequests.pullRequests += [ordered]@{ id = "PR_SYNTHETIC_7471"; number = 7471; isDraft = $true; headOid = "f" * 40; autoMerge = $false; files = @("scripts/digitalocean-platform-config.test.mjs") }
        $o.admission.collisions = @([ordered]@{ pr = 7471; path = "scripts/digitalocean-platform-config.test.mjs" })
      }
      $nearMisses.unknownRule = {
        param($o)
        $o.admission.configuration.value.applicableRulesets[0].rules += [ordered]@{ type = "synthetic_unknown_rule" }
        $o.admission.configuration.sha256 = Get-TestSha256 ($o.admission.configuration.value | ConvertTo-Json -Compress -Depth 50)
        Set-FrontierAuthorityRaw $o
      }
      foreach ($case in $nearMisses.GetEnumerator()) {
        $observation = New-FrontierObservation
        & $case.Value $observation
        $result = Invoke-FrontierFixture @($observation) "Report"
        Assert-True ($result.status -ceq "refused" -and $result.reason -ceq "PIPELINE_BREAKER_OPEN" -and
          $result.mutationCount -eq 0 -and $result.enqueueAttempts -eq 0 -and $result.dequeueAttempts -eq 0 -and
          $result.admission.decision -ceq "BREAKER_REPAIR_FRONTIER_REFUSED") `
          "frontier authority record/default-refuse near miss $($case.Key) was admitted"
      }

      $initial = New-FrontierObservation
      $moved = New-FrontierObservation
      & $nearMisses.openSiblingCollision $moved
      $betweenReads = Invoke-FrontierFixture @($initial, $moved) "Apply"
      Assert-True ($betweenReads.status -ceq "refused" -and $betweenReads.reason -ceq "PIPELINE_BREAKER_OPEN" -and
        $betweenReads.mutationCount -eq 0) "every admission conjunct is re-derived at both observations"

      $auditCompromised = New-FrontierObservation -Audit
      $auditCompromised.admission.queue.totalCount = 2
      $auditCompromised.admission.queue.entries += ConvertTo-QueueEntryObservation ([ordered]@{
          id = "MQE_SYNTHETIC_SECOND"; position = 2; state = "QUEUED"; solo = $false; jump = $false
          baseCommit = [ordered]@{ oid = $repairBase }; headCommit = [ordered]@{ oid = "f" * 40 }
          pullRequest = [ordered]@{ id = "PR_SYNTHETIC_OTHER"; number = 7999; headRefOid = "f" * 40 }
        })
      $recovered = Invoke-FrontierFixture @((New-FrontierObservation), (New-FrontierObservation), $auditCompromised) "Apply" $true
      Assert-True ($recovered.status -ceq "refused" -and $recovered.reason -ceq "ADMISSION_COMPROMISE_RECOVERED" -and
        $recovered.mutationCount -eq 2 -and $recovered.enqueueAttempts -eq 1 -and $recovered.dequeueAttempts -eq 1) `
        "every post-enqueue compromise is recovered with one dequeue attempt"
      $unrecovered = Invoke-FrontierFixture @((New-FrontierObservation), (New-FrontierObservation), $auditCompromised) "Apply" $false
      Assert-True ($unrecovered.status -ceq "unknown" -and $unrecovered.reason -ceq "ADMISSION_COMPROMISE_UNRECOVERED" -and
        $unrecovered.mutationCount -eq 2 -and $unrecovered.enqueueAttempts -eq 1 -and $unrecovered.dequeueAttempts -eq 1) `
        "unconfirmed dequeue is unknown and is never retried"

      # Production field extraction retains presence/null/type/value/predicate
      # recursively. Position origin, server-computed solo, lifecycle state,
      # and nullable generated commits/PR are diagnostic rather than identity.
      foreach ($position in @(0, 1)) {
        foreach ($state in @("QUEUED", "AWAITING_CHECKS", "MERGEABLE", "UNMERGEABLE", "LOCKED")) {
          $raw = New-SyntheticStableEntry -Position $position -State $state -Solo ($position -eq 1)
          $observed = ConvertTo-QueueEntryObservation $raw
          Assert-True ($observed.valid -eq $true -and (Test-EntryObservationClosed $observed) -and
            $observed.transient.position -eq $position -and $observed.transient.state -ceq $state) `
            "position/state/solo diagnostic matrix rejected position=$position state=$state"
        }
      }
      $nullable = New-SyntheticStableEntry
      $nullable.pullRequest = $null
      $nullableObservation = ConvertTo-QueueEntryObservation $nullable
      Assert-True ($nullableObservation.valid -eq $true -and
        $nullableObservation.fields.baseCommit.explicitNull -eq $true -and
        $nullableObservation.fields.headCommit.explicitNull -eq $true -and
        $nullableObservation.fields.pullRequest.explicitNull -eq $true) `
        "nullable mutation fields are not retained as explicit-null evidence"

      $entryShapeMutants = [ordered]@{}
      $entryShapeMutants.missingState = { param($v) [void]$v.Remove("state") }
      $entryShapeMutants.wrongPositionType = { param($v) $v.position = "0" }
      $entryShapeMutants.fractionalPosition = { param($v) $v.position = 0.5 }
      $entryShapeMutants.wrongSoloType = { param($v) $v.solo = 0 }
      $entryShapeMutants.missingJump = { param($v) [void]$v.Remove("jump") }
      $entryShapeMutants.unknownState = { param($v) $v.state = "SYNTHETIC_UNKNOWN" }
      $entryShapeMutants.extraRoot = { param($v) $v.extra = "SYNTHETIC_EXTRA" }
      $entryShapeMutants.extraCommit = { param($v) $v.baseCommit = [ordered]@{ oid = "b" * 40; extra = 0.5 } }
      $entryShapeMutants.extraPull = { param($v) $v.pullRequest.extra = "SYNTHETIC_EXTRA" }
      foreach ($case in $entryShapeMutants.GetEnumerator()) {
        $raw = New-SyntheticStableEntry -BaseCommit ([ordered]@{ oid = "b" * 40 }) -HeadCommit ([ordered]@{ oid = "c" * 40 })
        & $case.Value $raw
        $observed = ConvertTo-QueueEntryObservation $raw
        Assert-True ($observed.valid -ne $true -and (Test-EntryObservationClosed $observed) -and
          @($observed.fields.Values | Where-Object { $_.predicate -ne $true }).Count -gt 0 -or @($observed.unexpectedKeys).Count -gt 0) `
          "entry field mutant $($case.Key) did not retain a named failed predicate"
      }
      $malformedEntry = ConvertTo-QueueEntryObservation "SYNTHETIC_MALFORMED_PROVIDER_ENTRY"
      Assert-True ($malformedEntry.valid -ne $true -and (Test-EntryObservationClosed $malformedEntry) -and
        @($malformedEntry.fields.Values | Where-Object { $_.predicate -ne $true }).Count -eq 8) `
        "malformed provider entry did not fail closed with all selected fields named"
      Write-Output "PASS terminal admission field evidence is recursively closed across position/state/null/type/extra-key matrix"

      $requestedCmid = "CMID_SYNTHETIC_STABLE"
      $mutationRaw = New-SyntheticStableEntry -Position 0 -State "QUEUED" -Solo $false -BaseCommit $null -HeadCommit $null
      $mutationResult = New-EnqueueMutationResult (New-SyntheticMutationGraph $mutationRaw $requestedCmid) $requestedCmid $true
      $candidateIdentity = [ordered]@{ id = "PR_SYNTHETIC_STABLE"; number = 900100; headOid = "a" * 40 }
      $transientCases = @(
        $(New-SyntheticStableEntry -Position 1 -State "LOCKED" -Solo $true -BaseCommit ([ordered]@{ oid = "d" * 40 }) -HeadCommit ([ordered]@{ oid = "e" * 40 }))
        $(New-SyntheticStableEntry -Position 0 -State "MERGEABLE" -Solo $false -BaseCommit $null -HeadCommit ([ordered]@{ oid = "f" * 40 }))
      )
      foreach ($queueRaw in $transientCases) {
        $vector = Get-StableEntryConjuncts $mutationResult (ConvertTo-QueueEntryObservation $queueRaw) $candidateIdentity
        Assert-True (@($vector.Values | Where-Object { $_ -ne $true }).Count -eq 0) `
          "transient-only mutation/queue disagreement changed stable admission"
      }

      $stableMutants = [ordered]@{
        entryId = { param($v) $v.id = "MQE_SYNTHETIC_BYPASS" }
        jump = { param($v) $v.jump = $true }
        prNodeId = { param($v) $v.pullRequest.id = "PR_SYNTHETIC_BYPASS" }
        prNumber = { param($v) $v.pullRequest.number = 900101 }
        prHead = { param($v) $v.pullRequest.headRefOid = "f" * 40 }
      }
      foreach ($case in $stableMutants.GetEnumerator()) {
        $queueRaw = New-SyntheticStableEntry
        & $case.Value $queueRaw
        $vector = Get-StableEntryConjuncts $mutationResult (ConvertTo-QueueEntryObservation $queueRaw) $candidateIdentity
        Assert-True (@($vector.Values | Where-Object { $_ -ne $true }).Count -gt 0) `
          "stable identity bypass mutant $($case.Key) survived"
      }
      $nullableMutationRaw = New-SyntheticStableEntry
      $nullableMutationRaw.pullRequest = $null
      $nullableMutation = New-EnqueueMutationResult (New-SyntheticMutationGraph $nullableMutationRaw $requestedCmid) $requestedCmid $true
      $nullableVector = Get-StableEntryConjuncts $nullableMutation (ConvertTo-QueueEntryObservation (New-SyntheticStableEntry)) $candidateIdentity
      Assert-True (@($nullableVector.Values | Where-Object { $_ -ne $true }).Count -eq 0) `
        "nullable mutation-return pullRequest suppressed an exact queue-read identity"
      Write-Output "PASS stable projection matrix keeps every stable member load-bearing and all transient diagnostics inert"

      $partialErrors = @([ordered]@{ type = "SYNTHETIC_PARTIAL"; message = "synthetic partial success" })
      $partialGraph = New-SyntheticMutationGraph (New-SyntheticStableEntry -EntryId "MQE_SYNTHETIC_REPAIR" -PullRequest ([ordered]@{ id = "PR_SYNTHETIC_7470"; number = 7470; headRefOid = $repairHead })) "CMID_SYNTHETIC_PARTIAL" 1 $partialErrors $true
      $partialEnqueue = [ordered]@{ graphql = [ordered]@{ exitCode = 1; stdout = $partialGraph.process.stdout; stderr = $partialGraph.process.stderr; payload = $partialGraph.payload } }
      $partialResult = Invoke-FrontierFixture @((New-FrontierObservation), (New-FrontierObservation), (New-FrontierObservation -Audit)) "Apply" $true $partialEnqueue
      Assert-True ($partialResult.status -ceq "refused" -and $partialResult.reason -ceq "ADMISSION_COMPROMISE_RECOVERED" -and
        $partialResult.mutationCount -eq 2 -and $partialResult.enqueueAttempts -eq 1 -and $partialResult.dequeueAttempts -eq 1 -and
        $partialResult.admission.mutation.entryId -ceq "MQE_SYNTHETIC_REPAIR" -and
        $partialResult.admission.mutation.graphql.process.exitCode -eq 1 -and
        $partialResult.admission.mutation.graphql.data.present -eq $true -and
        $partialResult.admission.mutation.graphql.errors.present -eq $true -and
        $null -ne $partialResult.admission.audit.conjuncts -and
        @($partialResult.admission.audit.failedPredicates).Count -gt 0 -and
        (Test-TerminalAdmissionClosed $partialResult.admission $true)) `
        "data+errors/nonzero envelope did not preserve the entry ID and run the full enforcing audit"

      $nonzeroGraph = New-SyntheticMutationGraph (New-SyntheticStableEntry -EntryId "MQE_SYNTHETIC_REPAIR" -PullRequest ([ordered]@{ id = "PR_SYNTHETIC_7470"; number = 7470; headRefOid = $repairHead })) "CMID_SYNTHETIC_NONZERO" 1
      $nonzeroEnqueue = [ordered]@{ graphql = [ordered]@{ exitCode = 1; stdout = $nonzeroGraph.process.stdout; stderr = $nonzeroGraph.process.stderr; payload = $nonzeroGraph.payload } }
      $nonzeroResult = Invoke-FrontierFixture @((New-FrontierObservation), (New-FrontierObservation), (New-FrontierObservation -Audit)) "Apply" $true $nonzeroEnqueue
      Assert-True ($nonzeroResult.reason -ceq "ADMISSION_COMPROMISE_RECOVERED" -and $nonzeroResult.dequeueAttempts -eq 1 -and
        $nonzeroResult.admission.audit.queuePredicates.mutationExitZero -eq $false) `
        "nonzero-with-entry-ID did not audit and recover exactly once"

      $noIdPayload = [ordered]@{ data = [ordered]@{ enqueuePullRequest = [ordered]@{ clientMutationId = "CMID_SYNTHETIC_NO_ID"; mergeQueueEntry = $null } } }
      $noIdEnqueue = [ordered]@{ graphql = [ordered]@{ exitCode = 1; stdout = ($noIdPayload | ConvertTo-Json -Compress -Depth 20); stderr = "synthetic no-id"; payload = $noIdPayload } }
      $noId = Invoke-FrontierFixture @((New-FrontierObservation), (New-FrontierObservation), (New-FrontierObservation -Audit)) "Apply" $true $noIdEnqueue
      Assert-True ($noId.status -ceq "unknown" -and $noId.reason -ceq "ENQUEUE_ENTRY_ID_UNCONFIRMED" -and
        $noId.mutationCount -eq 1 -and $noId.enqueueAttempts -eq 1 -and $noId.dequeueAttempts -eq 0 -and
        $noId.admission.decision -ceq "ENQUEUE_UNKNOWN_PARK" -and $noId.admission.nonPass -ceq "PARK" -and
        $noId.admission.audit.immediateQueue.complete -eq $true -and $noId.admission.audit.conjuncts.entryIdConfirmed -eq $false -and
        (Test-TerminalAdmissionClosed $noId.admission $true)) `
        "no-ID enqueue did not close at unknown/PARK 1/0/1 without retry"

      $mismatchDequeue = Invoke-FrontierFixture @((New-FrontierObservation), (New-FrontierObservation), $auditCompromised) "Apply" $true $null "MQE_SYNTHETIC_WRONG_RETURN"
      Assert-True ($mismatchDequeue.status -ceq "unknown" -and $mismatchDequeue.reason -ceq "ADMISSION_COMPROMISE_UNRECOVERED" -and
        $mismatchDequeue.mutationCount -eq 2 -and $mismatchDequeue.dequeueAttempts -eq 1) `
        "dequeue returned-entry-ID mismatch was accepted or retried (observed=$($mismatchDequeue | ConvertTo-Json -Compress -Depth 30))"
      Write-Output "PASS partial-success/no-ID/dequeue-ID matrices preserve the closed 0/0/0, 1/0/1, and 1/1/2 cells"

      foreach ($spend in @(
          [ordered]@{ status = "recorded"; billedUsd = "0.01" },
          [ordered]@{ status = "unavailable"; billedUsd = $null },
          [ordered]@{ status = "recorded"; billedUsd = "999999.99" }
        )) {
        Assert-True (Test-RetryAttemptPolicy ([ordered]@{ ordinal = 2; consumed = 1; absoluteCeiling = 2; nonPass = "PARK" }) $spend) `
          "advisory spend telemetry changed retry policy for $($spend.status)/$($spend.billedUsd)"
      }
      Assert-True (-not (Test-RetryAttemptPolicy ([ordered]@{ ordinal = 3; consumed = 2; absoluteCeiling = 3; nonPass = "PASS" }) ([ordered]@{ status = "recorded"; billedUsd = "0.01" }))) `
        "attempt ceiling/nonPass policy is not enforcing"

      $syntheticAuthorityA = "a" * 64
      $syntheticAuthorityB = "b" * 64
      $syntheticHead = "e" * 40
      $expectedRefA = Get-RetryConsumptionRefName $syntheticHead $syntheticAuthorityA
      $expectedRefB = Get-RetryConsumptionRefName $syntheticHead $syntheticAuthorityB
      Assert-True ($expectedRefA -cne $expectedRefB -and $expectedRefA.Contains("lineage-900200/head-$syntheticHead/attempt-2/authority-$syntheticAuthorityA", [StringComparison]::Ordinal)) `
        "remote ref name is not lineage/head/ordinal/authority bounded"
      $refA = [ordered]@{ valid = $true; ref = $expectedRefA; targetOid = $syntheticHead; objectType = "commit" }
      $protocolFixture = [pscustomobject]@{ remoteConsumption = [pscustomobject][ordered]@{
          preCensus = [ordered]@{ complete = $true; refs = @() }
          create = [ordered]@{ attempted = $true; exitCode = 0; stdout = "synthetic create"; stderr = ""; ref = $refA }
          postCensus = [ordered]@{ complete = $true; refs = @($refA) }
          reread = [ordered]@{ complete = $true; ref = $refA }
        } }
      $fixtureScenario = $protocolFixture
      $remoteRecord = [ordered]@{ remoteConsumption = [ordered]@{ expectedRef = $expectedRefA; targetOid = $syntheticHead } }
      $remotePass = Invoke-RetryConsumptionProtocol $remoteRecord
      Assert-True ($remotePass.complete -eq $true -and $remotePass.reason -ceq "REMOTE_CONSUMPTION_CONFIRMED") `
        "synthetic remote consumption create/re-census/reread did not confirm"
      $remoteCases = @(
        [ordered]@{ name = "existing-second-authority"; expected = $expectedRefB; pre = [ordered]@{ complete = $true; refs = @($refA) }; create = $protocolFixture.remoteConsumption.create; post = $protocolFixture.remoteConsumption.postCensus; reread = $protocolFixture.remoteConsumption.reread; reason = "REMOTE_NAMESPACE_NOT_EMPTY" },
        [ordered]@{ name = "collision"; expected = $expectedRefA; pre = [ordered]@{ complete = $true; refs = @() }; create = [ordered]@{ attempted = $true; exitCode = 422; stdout = ""; stderr = "synthetic collision"; ref = $null }; post = $null; reread = $null; reason = "REMOTE_ATOMIC_CREATE_UNCONFIRMED" },
        [ordered]@{ name = "missing-after-create"; expected = $expectedRefA; pre = [ordered]@{ complete = $true; refs = @() }; create = $protocolFixture.remoteConsumption.create; post = [ordered]@{ complete = $true; refs = @() }; reread = $null; reason = "REMOTE_POST_CREATE_CENSUS_MISMATCH" },
        [ordered]@{ name = "moved"; expected = $expectedRefA; pre = [ordered]@{ complete = $true; refs = @() }; create = $protocolFixture.remoteConsumption.create; post = [ordered]@{ complete = $true; refs = @([ordered]@{ valid = $true; ref = $expectedRefA; targetOid = "f" * 40; objectType = "commit" }) }; reread = $null; reason = "REMOTE_POST_CREATE_CENSUS_MISMATCH" },
        [ordered]@{ name = "malformed"; expected = $expectedRefA; pre = [ordered]@{ complete = $true; refs = @() }; create = $protocolFixture.remoteConsumption.create; post = [ordered]@{ complete = $true; refs = @([ordered]@{ valid = $false; ref = $expectedRefA; targetOid = $syntheticHead; objectType = "tag" }) }; reread = $null; reason = "REMOTE_POST_CREATE_CENSUS_MISMATCH" },
        [ordered]@{ name = "extra"; expected = $expectedRefA; pre = [ordered]@{ complete = $true; refs = @() }; create = $protocolFixture.remoteConsumption.create; post = [ordered]@{ complete = $true; refs = @($refA, $refA) }; reread = $null; reason = "REMOTE_POST_CREATE_CENSUS_MISMATCH" }
      )
      foreach ($case in $remoteCases) {
        $fixtureScenario = [pscustomobject]@{ remoteConsumption = [pscustomobject][ordered]@{ preCensus = $case.pre; create = $case.create; postCensus = $case.post; reread = $case.reread } }
        $remoteRecord.remoteConsumption.expectedRef = $case.expected
        $result = Invoke-RetryConsumptionProtocol $remoteRecord
        Assert-True ($result.complete -ne $true -and $result.reason -ceq $case.reason) `
          "remote consumption case $($case.name) did not fail closed"
        if ($case.name -ceq "existing-second-authority") {
          Assert-True ($result.create.attempted -eq $false) "second locally minted authority reached create after nonempty namespace census"
        }
      }
      $fixtureScenario = $null
      Write-Output "PASS retry authority cost invariance and remote namespace/create/collision/missing/moved/malformed/extra matrix"

      $source = Get-Content -LiteralPath $preflight -Raw
      foreach ($requiredSource in @(
          'expectedHeadOid:$expectedHeadOid', 'jump:$jump', 'dequeuePullRequest(input:{id:$id',
          '$variables.expectedHeadOid = $ExpectedHeadOid', '$variables.jump = "false"',
          'Get-FrontierOpenPullRequests', 'Get-FrontierPullRequestFiles', 'Get-FrontierClosure',
          'Get-FrontierConfiguration', 'Get-FrontierQueue', 'manual administrator enqueue is detected, never prevented',
          'graphql-mutation-envelope/v1', 'merge-queue-entry-observation/v1', 'breaker-repair-frontier-audit/v1',
          'breaker-repair-frontier-retry-authority/v1', 'workflow-tag-activation-census/v1',
          'refs/tags/orchestrator-consumption/', 'REMOTE_NAMESPACE_NOT_EMPTY', 'REMOTE_EXACT_REF_REREAD_MISMATCH',
          'absoluteCeiling -ne 2', 'Attempt.nonPass -cne "PARK"'
        )) {
        Assert-True ($source.Contains($requiredSource, [StringComparison]::Ordinal)) "production observation/mutation wiring omits $requiredSource"
      }
      Assert-True (@([regex]::Matches($source, 'enqueuePullRequest\(input:')).Count -eq 1 -and
        @([regex]::Matches($source, 'dequeuePullRequest\(input:')).Count -eq 1) `
        "frontier keeps exactly one enqueue definition and exactly one dequeue definition"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "breaker-repair-frontier-authority.json"))) `
        "frontier verification wrote the fixed authority record"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "breaker-repair-frontier-retry-authority.json"))) `
        "frontier verification wrote the retry authority record"

      $enqueueDefinition = @($productionAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Invoke-EnqueueMutation" }, $true))
      $queueDefinition = @($productionAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Get-FrontierQueue" }, $true))
      $frontierDefinition = @($productionAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Test-BreakerRepairFrontier" }, $true))
      Assert-True ($enqueueDefinition.Count -eq 1 -and $enqueueDefinition[0].Extent.Text.Contains("New-EnqueueMutationResult", [StringComparison]::Ordinal) -and
        $queueDefinition.Count -eq 1 -and $queueDefinition[0].Extent.Text.Contains("ConvertTo-QueueEntryObservation", [StringComparison]::Ordinal) -and
        $frontierDefinition.Count -eq 1 -and $frontierDefinition[0].Extent.Text.Contains("Get-StableEntryConjuncts", [StringComparison]::Ordinal)) `
        "AST call graph does not connect production mutation, queue collection, and stable projection"
      $enqueueCallIndex = $source.IndexOf('$mutationResult = Invoke-EnqueueMutation', [StringComparison]::Ordinal)
      $immediateQueueIndex = $source.IndexOf('$immediateQueue = Get-ImmediateQueueObservation', $enqueueCallIndex, [StringComparison]::Ordinal)
      $entryDecisionIndex = $source.IndexOf('if ([string]::IsNullOrWhiteSpace([string]$mutationResult.entryId))', $immediateQueueIndex, [StringComparison]::Ordinal)
      $authorityAuditIndex = $source.IndexOf('$auditObservation = Get-AuthorityObservation', $entryDecisionIndex, [StringComparison]::Ordinal)
      Assert-True (0 -le $enqueueCallIndex -and $enqueueCallIndex -lt $immediateQueueIndex -and
        $immediateQueueIndex -lt $entryDecisionIndex -and $entryDecisionIndex -lt $authorityAuditIndex) `
        "post-enqueue call graph does not make complete queue collection the first provider observation"

      $fixtureBlob = (& git -C (Split-Path -Parent $PSScriptRoot) hash-object -- ".orchestrator/landing-preflight.fixture.json" 2>&1 | Out-String).Trim()
      $grandfatheredBlob = (& git -C (Split-Path -Parent $PSScriptRoot) rev-parse "HEAD:.orchestrator/landing-preflight.fixture.json" 2>&1 | Out-String).Trim()
      Assert-True ($LASTEXITCODE -eq 0 -and $fixtureBlob -ceq "c0c3d3841240ebe60101c770870c7ba088cb66c2" -and $fixtureBlob -ceq $grandfatheredBlob) `
        "grandfathered pre-existing real-identity fixture bytes changed"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "provider-sentinel-must-not-run.exe"))) `
        "provider sentinel was invoked or materialized"
      Write-Output "PASS production AST/call-graph seam, first-observation ordering, fixture census, and zero-live-call proof"
      Write-Output "PASS Apply preserves expectedHeadOid, jump:false, post-enqueue audit, one-dequeue recovery, and unrelated-breaker refusal"
      Write-Output "PASS breaker repair frontier exact-instance/default-refuse, collision, repeated observation, expected-head enqueue, audit, recovery, and provider-isolation controls"
    } finally {
      foreach ($name in $savedProviderEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedProviderEnvironment[$name], "Process") }
    }
    Test-FrontierCollectionBoundaries
    if ($RegressionOnly -eq "BreakerRepairFrontierOnly") { return }
  }

  if ($RegressionOnly -in @("All", "BreakerClearOnly", "ScopeAwareBreakerOnly", "ContinuationOnly")) {
    $clearOnlyRows = [Collections.Generic.List[object]]::new()
    $clearOnlyRows.Add((New-Pass $headA))
    foreach ($index in 1..7) {
      $clearOnlyRows.Add((New-BreakerEvent "breaker-clear" (5700 + $index) (5700 + $index) `
            ([datetimeoffset]::Parse("2026-07-28T12:00:00Z").AddMinutes($index))))
    }
    $clearOnlyHistory = New-History @($clearOnlyRows)
    $clearOnly = Invoke-ProductionPreflight $clearOnlyHistory
    Assert-True ($clearOnly.status -eq "eligible" -and
      $clearOnly.reason -eq "REPORT_ONLY_ELIGIBLE" -and
      $clearOnly.mutationCount -eq 0 -and
      $clearOnly.observations.initial.breaker.complete -eq $true -and
      $clearOnly.observations.initial.breaker.healthy -eq $true -and
      @($clearOnly.observations.initial.breaker.open).Count -eq 0 -and
      $clearOnly.observations.initial.breaker.unpairedClears -eq 7) `
      "seven historical clear-only rows are diagnostic, not active pipeline breakers (observed=$($clearOnly | ConvertTo-Json -Compress -Depth 12))"
    if ($RegressionOnly -eq "BreakerClearOnly") {
      Write-Output "PASS breaker clear-only live-failure regression"
      return
    }
  }

  $deployHistory = New-History @((New-Pass $headA))
  if ($RegressionOnly -in @("All", "DeployCompletionOnly")) {
    $activeRun = [long]9007199254740603
    $previousRun = [long]9007199254740602
    $oldGreenRun = [long]9007199254740601
    $completionRuns = @(
      (New-SyntheticDeployRun $activeRun "2030-08-03T00:00:00Z" "in_progress" $null),
      (New-SyntheticDeployRun $previousRun "2030-08-02T00:00:00Z"),
      (New-SyntheticDeployRun $oldGreenRun "2030-08-01T00:00:00Z")
    )
    $completionCases = @(
      @{ name = 'in-progress-after-success'; latest = 'in_progress'; prior = 'success'; status = 'eligible'; reason = 'REPORT_ONLY_ELIGIBLE' },
      @{ name = 'in-progress-after-failure'; latest = 'in_progress'; prior = 'failure'; status = 'refused'; reason = 'DEPLOY_UNHEALTHY' },
      @{ name = 'in-progress-after-cancelled'; latest = 'in_progress'; prior = 'cancelled'; status = 'refused'; reason = 'DEPLOY_UNHEALTHY' },
      @{ name = 'completed-failure'; latest = 'failure'; prior = 'success'; status = 'refused'; reason = 'DEPLOY_UNHEALTHY' },
      @{ name = 'completed-cancelled'; latest = 'cancelled'; prior = 'success'; status = 'refused'; reason = 'DEPLOY_UNHEALTHY' },
      @{ name = 'missing-predecessor'; latest = 'in_progress'; prior = 'missing'; status = 'unknown'; reason = 'DEPLOY_AUTHORITY_UNREADABLE' },
      @{ name = 'unreadable-predecessor'; latest = 'in_progress'; prior = 'unreadable'; status = 'unknown'; reason = 'DEPLOY_AUTHORITY_UNREADABLE' },
      @{ name = 'missing-completion-conclusion'; latest = ''; prior = 'success'; status = 'unknown'; reason = 'DEPLOY_AUTHORITY_UNREADABLE' },
      @{ name = 'unknown-staging-status'; latest = 'unknown'; prior = 'success'; status = 'unknown'; reason = 'DEPLOY_AUTHORITY_UNREADABLE' }
    )
    foreach ($case in $completionCases) {
      $runs = Copy-TestValue $completionRuns
      $activeStatus = if ($case.latest -in @('in_progress', 'unknown')) { $case.latest } else { 'completed' }
      $activeConclusion = if ($activeStatus -ceq 'completed') { $case.latest } else { $null }
      $runs[0].status = $activeStatus
      $runs[0].conclusion = $activeConclusion
      $runs[1].conclusion = $case.prior
      if ($case.prior -ceq 'missing') { $runs = @($runs[0]) }
      Set-DeployFixtures $runs @{
        "$activeRun" = New-SyntheticStagingJobs 8007199254740603 $activeStatus $activeConclusion 1
        "$previousRun" = $(if ($case.prior -ceq 'unreadable') { 'FAIL' } else {
          New-SyntheticStagingJobs 8007199254740602 'completed' $case.prior 1
        })
        "$oldGreenRun" = New-SyntheticStagingJobs 8007199254740601 'completed' 'success' 1
      }
      $control = Invoke-LoggedProductionPreflight $deployHistory
      $result = $control.result
      Assert-True ($result.status -ceq $case.status -and $result.reason -ceq $case.reason -and
        $result.mutationCount -eq 0) "AC12 $($case.name): expected $($case.status)/$($case.reason), got $($result.status)/$($result.reason)"
      Assert-True ((Get-JobQueryCount $control $oldGreenRun) -eq 0) "AC12 $($case.name) never skips a completed or unreadable predecessor for older green"
      if ($case.status -cne 'unknown') {
        $expectedRun = if ($activeStatus -ceq 'in_progress') { $previousRun } else { $activeRun }
        Assert-True ([long]$result.observations.initial.deploy.runId -eq $expectedRun) "AC12 $($case.name) binds completed deploy identity"
      }
      if ($activeStatus -ceq 'in_progress') {
        Assert-True (@($result.observations.initial.deploy.nonAuthority | Where-Object {
          [long]$_.runId -eq $activeRun -and $_.reason -ceq 'DEPLOY_STAGING_IN_PROGRESS'
        }).Count -eq 1) "AC12 $($case.name) retains in-progress evidence without making it health authority"
      }
      Write-Output "PASS AC12 $($case.name) => $($result.status)/$($result.reason)"
    }
    Set-DeployFixtures @() @{}
    $missingDeploy = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($missingDeploy.result.status -ceq 'unknown' -and
      $missingDeploy.result.reason -ceq 'DEPLOY_AUTHORITY_UNREADABLE' -and
      $missingDeploy.result.mutationCount -eq 0) 'AC12 missing deploy authority fails closed'
    Write-Output 'PASS AC12 missing deploy authority => unknown/DEPLOY_AUTHORITY_UNREADABLE'

    # Execute an isolated source mutant through the same mocked provider and
    # admission path: an active deploy alone must not manufacture green health.
    $source = [IO.File]::ReadAllText($preflight)
    $guard = 'if ([string]$staging.status -ceq "in_progress") {'
    Assert-True ([regex]::Matches($source, [regex]::Escape($guard)).Count -eq 1) 'AC12 mutant reaches the exact in-progress resolver clause'
    $mutant = $source.Replace($guard, @'
if ([string]$staging.status -ceq "in_progress") {
      return [pscustomobject]@{
        complete = $true; reason = "DEPLOY_AUTHORITY_OBSERVED"
        status = "completed"; conclusion = "success"
        runId = $runId; jobId = $jobId; headSha = [string]$run.headSha
        createdAt = $created.ToString("o"); nonAuthority = @($nonAuthority)
        unobservableRunId = $null
      }
'@)
    $mutantPath = Join-Path $testRoot 'landing-preflight-always-healthy-mutant.ps1'
    [IO.File]::WriteAllText($mutantPath, $mutant, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Destination $testRoot
    $failedPredecessorRuns = Copy-TestValue $completionRuns
    $failedPredecessorRuns[1].conclusion = 'failure'
    Set-DeployFixtures $failedPredecessorRuns @{
      "$activeRun" = New-SyntheticStagingJobs 8007199254740603 'in_progress' $null 1
      "$previousRun" = New-SyntheticStagingJobs 8007199254740602 'completed' 'failure' 1
      "$oldGreenRun" = New-SyntheticStagingJobs 8007199254740601 'completed' 'success' 1
    }
    $originalPreflight = $preflight
    try {
      $preflight = $mutantPath
      $bypass = Invoke-LoggedProductionPreflight $deployHistory
    } finally { $preflight = $originalPreflight }
    Assert-True ($bypass.result.status -ceq 'eligible' -and
      $bypass.result.reason -ceq 'REPORT_ONLY_ELIGIBLE' -and $bypass.result.mutationCount -eq 0 -and
      (Get-JobQueryCount $bypass $previousRun) -eq 0) 'AC12 always-healthy mutant must expose admission without reading the failed predecessor'
    Write-Output 'KILLED AC12 mutant=in-progress-always-healthy: failed-predecessor control refuses; isolated mutant admits without predecessor read'

    $env:LANDING_PREFLIGHT_MOCK_RUNS = Write-JsonFixture 'runs-completion-restored.json' (New-RealDeployRunFixture)
    Set-RealDeployJobFixtures
    if ($RegressionOnly -eq 'DeployCompletionOnly') { return }
  }
  if ($RegressionOnly -in @("All", "DeployResolverOnly")) {
    $resolverControl = Invoke-LoggedProductionPreflight $deployHistory
    $resolverOnly = $resolverControl.result
    Assert-True ($resolverOnly.status -eq "eligible" -and
      $resolverOnly.reason -eq "REPORT_ONLY_ELIGIBLE" -and
      $resolverOnly.mutationCount -eq 0 -and
      $resolverControl.calls.Count -eq 4 -and
      [long]$resolverOnly.observations.initial.deploy.runId -eq [long]30420203201 -and
      [long]$resolverOnly.observations.initial.deploy.jobId -eq [long]90475766694 -and
      @($resolverOnly.observations.initial.deploy.nonAuthority |
        Where-Object { [long]$_.runId -eq [long]30420209472 -and $_.reason -eq "DEPLOY_STAGING_SKIPPED" }).Count -eq 1) `
      "resolver-only run 30420209472 cannot mask executed Deploy Staging run 30420203201 (observed=$($resolverOnly | ConvertTo-Json -Compress -Depth 12))"
    if ($RegressionOnly -eq "DeployResolverOnly") {
      Write-Output "PASS deploy resolver-only live-failure regression"
      return
    }
  }

  if ($RegressionOnly -in @("All", "ExecutedUnrecognizedStaging")) {
    $unrecognizedRun = [long]9007199254740901
    $olderGreenRun = [long]9007199254740900
    $unrecognizedJob = [long]8007199254740901
    $olderGreenJob = [long]8007199254740900
    $unrecognizedRuns = @(
      (New-SyntheticDeployRun $unrecognizedRun "2030-02-02T00:00:00Z" "completed" "failure"),
      (New-SyntheticDeployRun $olderGreenRun "2030-02-01T00:00:00Z")
    )
    $unrecognizedJobs = New-SyntheticStagingJobs $unrecognizedJob "completed" "failure" 59
    $unrecognizedJobs.jobs[0].name = "Deploy Staging (staging)"
    $unrecognizedJobs.jobs = @(
      (New-MinimizedJob "Resolve Release"),
      $unrecognizedJobs.jobs[0]
    )
    $unrecognizedJobs.total_count = 2
    Set-DeployFixtures $unrecognizedRuns @{
      "$unrecognizedRun" = $unrecognizedJobs
      "$olderGreenRun" = New-SyntheticStagingJobs $olderGreenJob "completed" "success" 1
    }
    $unrecognizedControl = Invoke-LoggedProductionPreflight $deployHistory
    $unrecognized = $unrecognizedControl.result
    $olderGreenQueryCount = Get-JobQueryCount $unrecognizedControl $olderGreenRun
    Assert-True ($unrecognized.status -eq "unknown" -and
      $unrecognized.reason -eq "DEPLOY_AUTHORITY_UNREADABLE" -and
      $unrecognized.mutationCount -eq 0 -and
      [long]$unrecognized.observations.initial.deploy.unobservableRunId -eq $unrecognizedRun -and
      $null -eq $unrecognized.observations.initial.deploy.runId -and
      (Get-JobQueryCount $unrecognizedControl $unrecognizedRun) -eq 1 -and
      $olderGreenQueryCount -eq 0) `
      "an executed but unrecognized staging-job shape is terminal unknown and cannot query older green (observed=$($unrecognized | ConvertTo-Json -Compress -Depth 12))"
    if ($RegressionOnly -eq "ExecutedUnrecognizedStaging") {
      Write-Output "PASS executed unrecognized staging job fails closed; older-green job queries=$olderGreenQueryCount"
      return
    }
  }

  if ($RegressionOnly -in @("All", "SensitivityRequired")) {
    $source = Get-Content -LiteralPath $preflight -Raw
    Assert-True (@([regex]::Matches(
          $source,
          [regex]::Escape('$events | Sort-Object instant, line')
        )).Count -eq 1) `
      "the executable breaker reducer explicitly orders equal instants by append line"
    Assert-True (@([regex]::Matches(
          $source,
          [regex]::Escape('if ($runs.Count -lt 1 -or $runs.Count -gt 10) {')
        )).Count -eq 1) `
      "the executable deploy mapper retains its complete bounded run-list guard"

    $breakerDeployRun = [long]9007199254740801
    $breakerDeployJob = [long]8007199254740801
    Set-DeployFixtures @(
      (New-SyntheticDeployRun $breakerDeployRun "2030-03-01T00:00:00Z")
    ) @{
      "$breakerDeployRun" = New-SyntheticStagingJobs $breakerDeployJob "completed" "success" 1
    }
    $tieInstant = [datetimeoffset]::Parse("2030-02-01T12:00:00Z")
    $tieClearFirst = Invoke-ProductionPreflight (New-History @(
        (New-Pass $headA),
        (New-BreakerEvent "breaker-clear" 6101 6201 $tieInstant),
        (New-BreakerEvent "breaker-open" 6101 6201 $tieInstant)
      ))
    Assert-True ($tieClearFirst.status -eq "refused" -and
      $tieClearFirst.reason -eq "PIPELINE_BREAKER_OPEN" -and
      @($tieClearFirst.observations.initial.breaker.open).Count -eq 1 -and
      $tieClearFirst.observations.initial.breaker.open[0] -ceq "6101/6201" -and
      $tieClearFirst.observations.initial.breaker.unpairedClears -eq 1) `
      "same-timestamp clear-then-open append order leaves the breaker open"

    $tieOpenFirst = Invoke-ProductionPreflight (New-History @(
        (New-Pass $headA),
        (New-BreakerEvent "breaker-open" 6101 6201 $tieInstant),
        (New-BreakerEvent "breaker-clear" 6101 6201 $tieInstant)
      ))
    Assert-True ($tieOpenFirst.status -eq "eligible" -and
      $tieOpenFirst.observations.initial.breaker.healthy -eq $true -and
      @($tieOpenFirst.observations.initial.breaker.open).Count -eq 0 -and
      $tieOpenFirst.observations.initial.breaker.unpairedClears -eq 0) `
      "same-timestamp open-then-clear append order discharges the breaker"

    $timestampBeforeLine = Invoke-ProductionPreflight (New-History @(
        (New-Pass $headA),
        (New-BreakerEvent "breaker-clear" 6102 6202 ([datetimeoffset]::Parse("2030-02-01T12:05:00Z"))),
        (New-BreakerEvent "breaker-open" 6102 6202 ([datetimeoffset]::Parse("2030-02-01T12:00:00Z")))
      ))
    Assert-True ($timestampBeforeLine.status -eq "eligible" -and
      $timestampBeforeLine.observations.initial.breaker.healthy -eq $true -and
      $timestampBeforeLine.observations.initial.breaker.unpairedClears -eq 0) `
      "breaker timestamps remain primary when append order is not chronological"

    $crossKey = Invoke-ProductionPreflight (New-History @(
        (New-Pass $headA),
        (New-BreakerEvent "breaker-open" 6103 6203 ([datetimeoffset]::Parse("2030-02-01T12:00:00Z"))),
        (New-BreakerEvent "breaker-clear" 7103 7203 ([datetimeoffset]::Parse("2030-02-01T12:05:00Z")))
      ))
    Assert-True ($crossKey.status -eq "refused" -and
      $crossKey.reason -eq "PIPELINE_BREAKER_OPEN" -and
      @($crossKey.observations.initial.breaker.open).Count -eq 1 -and
      $crossKey.observations.initial.breaker.open[0] -ceq "6103/6203" -and
      $crossKey.observations.initial.breaker.unpairedClears -eq 1) `
      "a clear for another issue/PR key cannot discharge the open pipeline breaker"

    $caseRun = [long]9007199254740701
    $caseJob = [long]8007199254740701
    $caseJobs = New-SyntheticStagingJobs $caseJob "completed" "success" 1
    $caseJobs.jobs[0].name = "deploy staging"
    Set-DeployFixtures @(
      (New-SyntheticDeployRun $caseRun "2030-04-01T00:00:00Z")
    ) @{ "$caseRun" = $caseJobs }
    $caseControl = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($caseControl.result.status -eq "unknown" -and
      $caseControl.result.reason -eq "DEPLOY_AUTHORITY_UNREADABLE" -and
      [long]$caseControl.result.observations.initial.deploy.unobservableRunId -eq $caseRun) `
      "a case-variant staging-job name is an unrecognized completed workflow shape"

    $largeRun = [long]9007199254740702
    $largeJob = [long]8007199254740702
    $largeJobs = [Collections.Generic.List[object]]::new()
    foreach ($index in 1..100) { $largeJobs.Add((New-MinimizedJob "Auxiliary Job $index")) }
    $largeJobs.Add((New-SyntheticStagingJobs $largeJob "completed" "success" 1).jobs[0])
    Set-DeployFixtures @(
      (New-SyntheticDeployRun $largeRun "2030-04-02T00:00:00Z")
    ) @{
      "$largeRun" = [ordered]@{ total_count = 101; jobs = @($largeJobs) }
    }
    $largeControl = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($largeControl.result.status -eq "unknown" -and
      [long]$largeControl.result.observations.initial.deploy.unobservableRunId -eq $largeRun) `
      "a jobs collection beyond the requested page bound is unreadable"

    $mismatchRun = [long]9007199254740703
    $mismatchJob = [long]8007199254740703
    Set-DeployFixtures @(
      (New-SyntheticDeployRun $mismatchRun "2030-04-03T00:00:00Z")
    ) @{
      "$mismatchRun" = [ordered]@{
        total_count = 2
        jobs = @((New-SyntheticStagingJobs $mismatchJob "completed" "success" 1).jobs[0])
      }
    }
    $mismatchControl = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($mismatchControl.result.status -eq "unknown" -and
      [long]$mismatchControl.result.observations.initial.deploy.unobservableRunId -eq $mismatchRun) `
      "a jobs total_count/collection mismatch is unreadable"

    $duplicateJobRun = [long]9007199254740704
    $duplicateJobA = [long]8007199254740704
    $duplicateJobB = [long]8007199254740705
    Set-DeployFixtures @(
      (New-SyntheticDeployRun $duplicateJobRun "2030-04-04T00:00:00Z")
    ) @{
      "$duplicateJobRun" = [ordered]@{
        total_count = 2
        jobs = @(
          (New-SyntheticStagingJobs $duplicateJobA "completed" "success" 1).jobs[0],
          (New-SyntheticStagingJobs $duplicateJobB "completed" "success" 1).jobs[0]
        )
      }
    }
    $duplicateJobControl = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($duplicateJobControl.result.status -eq "unknown" -and
      [long]$duplicateJobControl.result.observations.initial.deploy.unobservableRunId -eq $duplicateJobRun) `
      "duplicate exact staging jobs are contradictory authority"

    $outOfOrderFirst = [long]9007199254740601
    $outOfOrderSecond = [long]9007199254740602
    Set-DeployFixtures @(
      (New-SyntheticDeployRun $outOfOrderFirst "2030-05-01T00:00:00Z"),
      (New-SyntheticDeployRun $outOfOrderSecond "2030-05-02T00:00:00Z")
    ) @{
      "$outOfOrderFirst" = New-SyntheticStagingJobs ([long]8007199254740601) "completed" "skipped" 0
      "$outOfOrderSecond" = New-SyntheticStagingJobs ([long]8007199254740602) "completed" "success" 1
    }
    $outOfOrderControl = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($outOfOrderControl.result.status -eq "unknown" -and
      [long]$outOfOrderControl.result.observations.initial.deploy.unobservableRunId -eq $outOfOrderSecond -and
      (Get-JobQueryCount $outOfOrderControl $outOfOrderSecond) -eq 0) `
      "an out-of-order run list is unreadable before the later row's jobs are queried"

    $tieRunFirst = [long]9007199254740501
    $tieRunSecond = [long]9007199254740502
    Set-DeployFixtures @(
      (New-SyntheticDeployRun $tieRunFirst "2030-06-01T00:00:00Z"),
      (New-SyntheticDeployRun $tieRunSecond "2030-06-01T00:00:00Z")
    ) @{
      "$tieRunFirst" = New-SyntheticStagingJobs ([long]8007199254740501) "completed" "skipped" 0
      "$tieRunSecond" = New-SyntheticStagingJobs ([long]8007199254740502) "completed" "success" 1
    }
    $tieRunControl = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($tieRunControl.result.status -eq "unknown" -and
      [long]$tieRunControl.result.observations.initial.deploy.unobservableRunId -eq $tieRunSecond -and
      (Get-JobQueryCount $tieRunControl $tieRunSecond) -eq 0) `
      "equal run timestamps require strictly descending run IDs"

    $duplicateRun = [long]9007199254740402
    $duplicateRunOlder = [long]9007199254740401
    Set-DeployFixtures @(
      (New-SyntheticDeployRun $duplicateRun "2030-07-03T00:00:00Z"),
      (New-SyntheticDeployRun $duplicateRun "2030-07-02T00:00:00Z"),
      (New-SyntheticDeployRun $duplicateRunOlder "2030-07-01T00:00:00Z")
    ) @{
      "$duplicateRun" = New-SyntheticStagingJobs ([long]8007199254740402) "completed" "skipped" 0
      "$duplicateRunOlder" = New-SyntheticStagingJobs ([long]8007199254740401) "completed" "success" 1
    }
    $duplicateRunControl = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($duplicateRunControl.result.status -eq "unknown" -and
      [long]$duplicateRunControl.result.observations.initial.deploy.unobservableRunId -eq $duplicateRun -and
      (Get-JobQueryCount $duplicateRunControl $duplicateRun) -eq 1 -and
      (Get-JobQueryCount $duplicateRunControl $duplicateRunOlder) -eq 0) `
      "a duplicate run ID is unreadable even when its timestamps differ"

    $uppercaseRun = New-SyntheticDeployRun ([long]9007199254740301) "2030-08-01T00:00:00Z"
    $uppercaseRun.headSha = "A" * 40
    Set-DeployFixtures @($uppercaseRun) @{
      "9007199254740301" = New-SyntheticStagingJobs ([long]8007199254740301) "completed" "success" 1
    }
    $uppercaseControl = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($uppercaseControl.result.status -eq "unknown" -and
      [long]$uppercaseControl.result.observations.initial.deploy.unobservableRunId -eq [long]9007199254740301 -and
      (Get-JobQueryCount $uppercaseControl ([long]9007199254740301)) -eq 0) `
      "an uppercase head SHA is not canonical provider authority"

    $env:LANDING_PREFLIGHT_MOCK_RUNS = "FAIL"
    $runListFailure = Invoke-LoggedProductionPreflight $deployHistory
    Assert-True ($runListFailure.result.status -eq "unknown" -and
      $runListFailure.result.reason -eq "DEPLOY_AUTHORITY_UNREADABLE" -and
      $runListFailure.result.mutationCount -eq 0 -and
      @($runListFailure.calls | Where-Object { $_ -match "actions/runs/.+/jobs" }).Count -eq 0) `
      "an empty gh run list response is terminal unreadable with no jobs query"

    $env:LANDING_PREFLIGHT_MOCK_RUNS = Write-JsonFixture `
      ("runs-nonzero-exit-" + [guid]::NewGuid().ToString("N") + ".json") (New-RealDeployRunFixture)
    $env:LANDING_PREFLIGHT_MOCK_RUNS_EXIT = "2"
    $runListNonzeroWithJson = Invoke-LoggedProductionPreflight $deployHistory
    [Environment]::SetEnvironmentVariable("LANDING_PREFLIGHT_MOCK_RUNS_EXIT", $null, "Process")
    Assert-True ($runListNonzeroWithJson.result.status -eq "unknown" -and
      $runListNonzeroWithJson.result.reason -eq "DEPLOY_AUTHORITY_UNREADABLE" -and
      $runListNonzeroWithJson.result.mutationCount -eq 0 -and
      @($runListNonzeroWithJson.calls | Where-Object { $_ -match "actions/runs/.+/jobs" }).Count -eq 0) `
      "a nonzero gh run list exit with valid runs JSON is terminal unreadable with no jobs query"

    if ($RegressionOnly -eq "SensitivityRequired") {
      Write-Output "PASS required landing-preflight sensitivity controls"
      return
    }
    $env:LANDING_PREFLIGHT_MOCK_RUNS = Write-JsonFixture `
      ("runs-restored-" + [guid]::NewGuid().ToString("N") + ".json") (New-RealDeployRunFixture)
    Set-RealDeployJobFixtures
  }

  $laterOpenRows = [Collections.Generic.List[object]]::new()
  foreach ($row in $clearOnlyRows) { $laterOpenRows.Add($row) }
  $laterOpenRows.Add((New-BreakerEvent "breaker-open" 6254 6258 `
        ([datetimeoffset]::Parse("2026-07-28T14:00:00Z"))))
  $laterOpen = Invoke-ProductionPreflight (New-History @($laterOpenRows))
  Assert-True ($laterOpen.status -eq "refused" -and
    $laterOpen.reason -eq "PIPELINE_BREAKER_OPEN" -and
    $laterOpen.mutationCount -eq 0 -and
    @($laterOpen.observations.initial.breaker.open).Count -eq 1 -and
    $laterOpen.observations.initial.breaker.open[0] -eq "6254/6258" -and
    $laterOpen.observations.initial.breaker.unpairedClears -eq 7) `
    "an unmatched later pipeline open remains blocking while clear-only rows stay diagnostic"

  $artifactHistory = New-History @(
    (New-Pass $headA),
    (New-BreakerEvent "breaker-open" 6254 6258 ([datetimeoffset]::Parse("2026-07-28T14:01:00Z")) "artifact")
  )
  $artifact = Invoke-ProductionPreflight $artifactHistory
  Assert-True ($artifact.status -eq "eligible" -and
    $artifact.mutationCount -eq 0 -and
    $artifact.observations.initial.breaker.healthy -eq $true -and
    @($artifact.observations.initial.breaker.open).Count -eq 0) `
    "artifact-scoped breakers do not halt the pipeline"

  $badBreaker = New-BreakerEvent "breaker-open" 6254 6258 `
    ([datetimeoffset]::Parse("2026-07-28T14:02:00Z"))
  $badBreaker.ts = "not-an-instant"
  $malformedBreaker = Invoke-ProductionPreflight (New-History @((New-Pass $headA), $badBreaker))
  Assert-True ($malformedBreaker.status -eq "unknown" -and
    $malformedBreaker.reason -eq "BREAKER_HISTORY_MALFORMED" -and
    $malformedBreaker.mutationCount -eq 0) `
    "malformed breaker authority fails closed"

  # Synthetic deploy shapes use deliberately synthetic Int64 identities.
  $newestSyntheticRun = [long]9007199254740993
  $olderSyntheticRun = [long]9007199254740992
  $newestSyntheticJob = [long]8007199254740993
  $olderSyntheticJob = [long]8007199254740992
  $syntheticRuns = @(
    (New-SyntheticDeployRun $newestSyntheticRun "2030-01-02T00:00:00Z"),
    (New-SyntheticDeployRun $olderSyntheticRun "2030-01-01T00:00:00Z")
  )
  $olderGreenJobs = New-SyntheticStagingJobs $olderSyntheticJob "completed" "success" 1
  $nonAuthorityCases = @(
    [ordered]@{
      name = "queued"
      reason = "DEPLOY_STAGING_QUEUED"
      jobs = New-SyntheticStagingJobs $newestSyntheticJob "queued" $null 0
    },
    [ordered]@{
      name = "skipped"
      reason = "DEPLOY_STAGING_SKIPPED"
      jobs = New-SyntheticStagingJobs $newestSyntheticJob "completed" "skipped" 0
    },
    [ordered]@{
      name = "cancelled-before-start"
      reason = "DEPLOY_STAGING_CANCELLED_BEFORE_START"
      jobs = New-SyntheticStagingJobs $newestSyntheticJob "completed" "cancelled" 0
    },
    [ordered]@{
      name = "zero-job"
      reason = "RUN_HAS_ZERO_JOBS"
      jobs = [ordered]@{ total_count = 0; jobs = @() }
    }
  )
  foreach ($case in $nonAuthorityCases) {
    Set-DeployFixtures $syntheticRuns @{
      "$newestSyntheticRun" = $case.jobs
      "$olderSyntheticRun" = $olderGreenJobs
    }
    $fallback = Invoke-ProductionPreflight $deployHistory
    Assert-True ($fallback.status -eq "eligible" -and
      $fallback.mutationCount -eq 0 -and
      [long]$fallback.observations.initial.deploy.runId -eq $olderSyntheticRun -and
      [long]$fallback.observations.initial.deploy.jobId -eq $olderSyntheticJob -and
      @($fallback.observations.initial.deploy.nonAuthority |
        Where-Object { [long]$_.runId -eq $newestSyntheticRun -and $_.reason -eq $case.reason }).Count -eq 1) `
      "$($case.name) Deploy Staging is bounded non-authority metadata"
  }

  foreach ($absentButMeasured in @(
      [ordered]@{ name = "incomplete-workflow"; status = "in_progress"; conclusion = $null },
      [ordered]@{ name = "cancelled-workflow"; status = "completed"; conclusion = "cancelled" }
    )) {
    $measuredRuns = @(
      (New-SyntheticDeployRun $newestSyntheticRun "2030-01-02T00:00:00Z" `
          $absentButMeasured.status $absentButMeasured.conclusion),
      (New-SyntheticDeployRun $olderSyntheticRun "2030-01-01T00:00:00Z")
    )
    Set-DeployFixtures $measuredRuns @{
      "$newestSyntheticRun" = [ordered]@{
        total_count = 1
        jobs = @((New-MinimizedJob "Resolve Release"))
      }
      "$olderSyntheticRun" = $olderGreenJobs
    }
    $measuredNonExecution = Invoke-ProductionPreflight $deployHistory
    Assert-True ($measuredNonExecution.status -eq "eligible" -and
      [long]$measuredNonExecution.observations.initial.deploy.runId -eq $olderSyntheticRun -and
      @($measuredNonExecution.observations.initial.deploy.nonAuthority |
        Where-Object {
          [long]$_.runId -eq $newestSyntheticRun -and
          $_.reason -eq "DEPLOY_STAGING_JOB_ABSENT"
        }).Count -eq 1) `
      "$($absentButMeasured.name) with jobs but no exact staging job is measured nonexecution"
  }

  foreach ($executedRed in @(
      [ordered]@{ name = "failure"; conclusion = "failure" },
      [ordered]@{ name = "cancelled-after-start"; conclusion = "cancelled" }
    )) {
    Set-DeployFixtures $syntheticRuns @{
      "$newestSyntheticRun" = New-SyntheticStagingJobs $newestSyntheticJob "completed" $executedRed.conclusion 1
      "$olderSyntheticRun" = $olderGreenJobs
    }
    $redAuthority = Invoke-ProductionPreflight $deployHistory
    Assert-True ($redAuthority.status -eq "refused" -and
      $redAuthority.reason -eq "DEPLOY_UNHEALTHY" -and
      $redAuthority.mutationCount -eq 0 -and
      [long]$redAuthority.observations.initial.deploy.runId -eq $newestSyntheticRun -and
      [long]$redAuthority.observations.initial.deploy.jobId -eq $newestSyntheticJob) `
      "executed $($executedRed.name) Deploy Staging remains the newest red authority"
  }

  Set-DeployFixtures $syntheticRuns @{
    "$newestSyntheticRun" = "FAIL"
    "$olderSyntheticRun" = $olderGreenJobs
  }
  [IO.File]::WriteAllText($env:LANDING_PREFLIGHT_MOCK_LOG, "")
  $unobservableCandidate = Invoke-ProductionPreflight $deployHistory
  $unobservableCallCount = @(Get-Content -LiteralPath $env:LANDING_PREFLIGHT_MOCK_LOG).Count
  Assert-True ($unobservableCandidate.status -eq "unknown" -and
    $unobservableCandidate.reason -eq "DEPLOY_AUTHORITY_UNREADABLE" -and
    $unobservableCandidate.mutationCount -eq 0 -and
    [long]$unobservableCandidate.observations.initial.deploy.unobservableRunId -eq $newestSyntheticRun -and
    $null -eq $unobservableCandidate.observations.initial.deploy.runId -and
    $unobservableCallCount -eq 3) `
    "an unobservable newest deploy candidate fails closed without probing or promoting older green"

  $currentHistory = New-History @((New-Pass $headA))

  $defaultGraphPath = $env:LANDING_PREFLIGHT_MOCK_GRAPH
  Test-NativeCurrentScopeOutput
  Test-SyntheticScopeCollector
  $scopeJobId = [long]8007199254740601
  $scopeRunId = [long]9007199254740601
  try {
    $env:LANDING_PREFLIGHT_MOCK_RUNS = Write-JsonFixture "scope-runs.json" (New-RealDeployRunFixture)
    Set-RealDeployJobFixtures
    $scopeGraph = New-ProductionGraphFixture
    $scopeCheck = [ordered]@{
      __typename = "CheckRun"
      name = "Change Scope"
      status = "COMPLETED"
      conclusion = "SUCCESS"
      databaseId = $scopeJobId
      detailsUrl = "https://github.com/chase-sets/chase-sets/actions/runs/$scopeRunId/job/$scopeJobId"
    }
    $scopeGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes += $scopeCheck
    $scopeGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount = 2
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture "scope-graph-one.json" $scopeGraph
    Set-ScopeProviderFixtures $scopeJobId $scopeRunId $headA $false @("docs/scope-proof.md")
    $scopeRunControl = (& $mockGh api "repos/chase-sets/chase-sets/actions/runs/$scopeRunId" | ConvertFrom-Json -NoEnumerate)
    Assert-True ($scopeRunControl.pull_requests -is [object[]] -and
      $scopeRunControl.pull_requests.Count -eq 1 -and
      $scopeRunControl.pull_requests[0].number -eq 6254 -and
      $scopeRunControl.pull_requests[0].head.sha -ceq $headA) `
      "the production-shaped scope run fixture preserves the exact singleton PR/head association"
    $scopeLogControlRaw = Get-Content -LiteralPath $env:LANDING_PREFLIGHT_MOCK_SCOPE_LOG_8007199254740601 -Raw
    $scopeLogControl = [object[]]@(Get-ChangeScopeOutputMaps $scopeLogControlRaw)
    Assert-True ($scopeLogControl.Count -eq 1 -and $scopeLogControl[0].changedFiles -is [string[]] -and
      $scopeLogControl[0].changedFiles.Count -eq 1) `
      "the production Change Scope log parser accepts one exact output map and retains its singleton changed-file array (maps=$($scopeLogControl.Count) raw=$scopeLogControlRaw)"
    # Synthetic current producer map through the native CLI transport. Keep
    # the independent legacy transport control above and the later resets.
    $currentMap = Copy-TestValue $script:scopeParityMaps[1]
    $currentMap.deploy = 'false'
    $currentScope = ConvertFrom-Json -InputObject $currentMap.scope_json -AsHashtable
    $currentScope.deployRequired = $false
    $currentMap.scope_json = ConvertTo-Json -InputObject $currentScope -Compress -Depth 32
    [IO.File]::WriteAllText($env:LANDING_PREFLIGHT_MOCK_SCOPE_LOG_8007199254740601, (ConvertTo-ScopeTestLog $currentMap))
    $productionScope = Invoke-ProductionPreflight $currentHistory
    Assert-True ($productionScope.status -ceq "eligible" -and
      $productionScope.changeScope.classification -ceq "non-deployable" -and
      $productionScope.changeScope.proven -eq $true -and
      $productionScope.changeScope.evaluatedHead -ceq $headA -and
      $productionScope.changeScope.checkCandidateCount -eq 1 -and
      $productionScope.changeScope.checkCandidates -is [object[]] -and
      $productionScope.changeScope.evidence.workflowRunId -eq $scopeRunId -and
      $productionScope.changeScope.evidence.jobId -eq $scopeJobId -and
      $productionScope.changeScope.evidence.jobRunAttempt -eq 1 -and
      $productionScope.changeScope.evidence.workflowRunAttempt -eq 1 -and
      $productionScope.changeScope.evidence.changedFiles -is [object[]] -and
      $productionScope.changeScope.evidence.changedFiles.Count -eq 1 -and
      $productionScope.changeScope.evidence.deploy -eq $false) `
      "the exact current Change Scope check resolves through its owning job/run/log and retains singleton typed evidence (observed=$($productionScope | ConvertTo-Json -Compress -Depth 20))"

    foreach ($attemptCase in @(
        [ordered]@{ name = "absent"; jobRunAttempt = $null },
        [ordered]@{ name = "lower"; jobRunAttempt = 1; runAttempt = 2 },
        [ordered]@{ name = "higher"; jobRunAttempt = 3; runAttempt = 2 },
        [ordered]@{ name = "invalid-typed"; jobRunAttempt = "1" }
      )) {
      $runAttempt = if ($attemptCase.Contains("runAttempt")) { $attemptCase.runAttempt } else { 1 }
      Set-ScopeProviderFixtures $scopeJobId $scopeRunId $headA $false @("docs/attempt-$($attemptCase.name).md") $attemptCase.jobRunAttempt $runAttempt
      $attemptMismatchScope = Invoke-ProductionPreflight $currentHistory
      Assert-True ($attemptMismatchScope.status -ceq "eligible" -and
        $attemptMismatchScope.changeScope.classification -ceq "deployable" -and
        $attemptMismatchScope.changeScope.proven -eq $false -and
        $attemptMismatchScope.changeScope.reason -ceq "CHANGE_SCOPE_ATTEMPT_MISMATCH") `
        "a $($attemptCase.name) job run_attempt fails closed before non-deployable proof"
      $attemptMismatchApply = Invoke-ScopeBreakerFixture @(
        (New-ScopeBreakerObservation $attemptMismatchScope.changeScope),
        (New-ScopeBreakerObservation $attemptMismatchScope.changeScope)
      ) $currentHistory
      Assert-True ($attemptMismatchApply.status -ceq "refused" -and
        $attemptMismatchApply.reason -ceq "PIPELINE_BREAKER_OPEN" -and
        $attemptMismatchApply.mutationCount -eq 0 -and
        $attemptMismatchApply.changeScope.classification -ceq "deployable" -and
        $attemptMismatchApply.changeScope.proven -eq $false -and
        $attemptMismatchApply.changeScope.reason -ceq "CHANGE_SCOPE_ATTEMPT_MISMATCH") `
        "a $($attemptCase.name) job run_attempt cannot reopen Apply under an open breaker"
    }

    Set-ScopeProviderFixtures $scopeJobId $scopeRunId $headB $false @("docs/stale-scope-proof.md")
    $staleProductionScope = Invoke-ProductionPreflight $currentHistory
    Assert-True ($staleProductionScope.status -ceq "eligible" -and
      $staleProductionScope.changeScope.classification -ceq "deployable" -and
      $staleProductionScope.changeScope.proven -eq $false -and
      $staleProductionScope.changeScope.reason -ceq "CHANGE_SCOPE_HEAD_MISMATCH") `
      "a hosted Change Scope run bound to a different PR head fails closed as deployable"

    $manyScopeGraph = New-ProductionGraphFixture
    $manyScopeGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes += $scopeCheck
    $secondScopeCheck = Copy-TestValue $scopeCheck
    $secondScopeCheck.databaseId = $scopeJobId + 1
    $secondScopeCheck.detailsUrl = "https://github.com/chase-sets/chase-sets/actions/runs/$($scopeRunId + 1)/job/$($scopeJobId + 1)"
    $manyScopeGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes += $secondScopeCheck
    $manyScopeGraph.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount = 3
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = Write-JsonFixture "scope-graph-many.json" $manyScopeGraph
    $manyProductionScope = Invoke-ProductionPreflight $currentHistory
    Assert-True ($manyProductionScope.changeScope.classification -ceq "deployable" -and
      $manyProductionScope.changeScope.proven -eq $false -and
      $manyProductionScope.changeScope.reason -ceq "CHANGE_SCOPE_CHECK_AMBIGUOUS" -and
      $manyProductionScope.changeScope.checkCandidateCount -eq 2 -and
      $manyProductionScope.changeScope.checkCandidates -is [object[]] -and
      $manyProductionScope.changeScope.checkCandidates.Count -eq 2) `
      "multiple current Change Scope checks preserve N candidates and fail closed without choosing one"
  } finally {
    $env:LANDING_PREFLIGHT_MOCK_GRAPH = $defaultGraphPath
  }

  $nonDeployableScope = $productionScope.changeScope
  $scopeReport = Invoke-ScopeBreakerFixture @((New-ScopeBreakerObservation $nonDeployableScope)) $currentHistory "Report"
  Assert-True ($scopeReport.status -ceq "eligible" -and $scopeReport.reason -ceq "REPORT_ONLY_ELIGIBLE" -and
    $scopeReport.mutationCount -eq 0 -and $scopeReport.changeScope.classification -ceq "non-deployable" -and
    $scopeReport.changeScope.proven -eq $true -and $scopeReport.changeScope.evaluatedHead -ceq $headA -and
    $scopeReport.openBreaker.schemaVersion -ceq "open-pipeline-breaker-identity/v1" -and
    $scopeReport.openBreaker.keys.Count -eq 1 -and $scopeReport.openBreaker.keys[0] -ceq "9001/9002" -and
    $scopeReport.openBreaker.rows[0].rowSha256 -ceq ("9" * 64)) `
    "Report publishes exact-head non-deployable scope and the open breaker identity without mutation (observed=$($scopeReport | ConvertTo-Json -Compress -Depth 20))"

  $scopeApply = Invoke-ScopeBreakerFixture @(
    (New-ScopeBreakerObservation $nonDeployableScope),
    (New-ScopeBreakerObservation $nonDeployableScope)
  ) $currentHistory
  Assert-True ($scopeApply.status -ceq "enqueued" -and $scopeApply.reason -ceq "ENQUEUE_CONFIRMED" -and
    $scopeApply.mutationCount -eq 1 -and $scopeApply.mergeQueueEntryId -ceq "MQE_scope_fixture_6254" -and
    $scopeApply.changeScope.classification -ceq "non-deployable" -and
    $scopeApply.openBreaker.keys[0] -ceq "9001/9002") `
    "Apply re-derives unchanged exact-head non-deployable scope and enqueues once while retaining breaker identity"

  $deployableScopeResult = Invoke-ScopeBreakerFixture @(
    (New-ScopeBreakerObservation (New-SyntheticChangeScope "deployable"))
  ) $currentHistory
  Assert-True ($deployableScopeResult.status -ceq "refused" -and
    $deployableScopeResult.reason -ceq "PIPELINE_BREAKER_OPEN" -and
    $deployableScopeResult.mutationCount -eq 0 -and
    $deployableScopeResult.changeScope.classification -ceq "deployable" -and
    $deployableScopeResult.changeScope.proven -eq $true) `
    "an exactly proven deployable head remains refused by an open breaker"

  $missingScopeResult = Invoke-ScopeBreakerFixture @((New-ScopeBreakerObservation $null)) $currentHistory
  Assert-True ($missingScopeResult.status -ceq "refused" -and
    $missingScopeResult.reason -ceq "PIPELINE_BREAKER_OPEN" -and
    $missingScopeResult.mutationCount -eq 0 -and
    $missingScopeResult.changeScope.classification -ceq "deployable" -and
    $missingScopeResult.changeScope.proven -eq $false -and
    $missingScopeResult.changeScope.reason -ceq "CHANGE_SCOPE_EVIDENCE_MISSING" -and
    $missingScopeResult.changeScope.checkCandidateCount -eq 0 -and
    $missingScopeResult.changeScope.checkCandidates -is [object[]]) `
    "missing scope preserves the typed zero-candidate boundary and fails closed as deployable"

  $staleScopeResult = Invoke-ScopeBreakerFixture @(
    (New-ScopeBreakerObservation (New-SyntheticChangeScope "non-deployable" $headB))
  ) $currentHistory
  Assert-True ($staleScopeResult.status -ceq "refused" -and
    $staleScopeResult.reason -ceq "PIPELINE_BREAKER_OPEN" -and
    $staleScopeResult.mutationCount -eq 0 -and
    $staleScopeResult.changeScope.classification -ceq "deployable" -and
    $staleScopeResult.changeScope.proven -eq $false -and
    $staleScopeResult.changeScope.reason -ceq "CHANGE_SCOPE_HEAD_MISMATCH") `
    "stale-head non-deployable prose cannot bypass the breaker"

  $ambiguousScopeResult = Invoke-ScopeBreakerFixture @(
    (New-ScopeBreakerObservation (New-SyntheticChangeScope "non-deployable" $headA 2))
  ) $currentHistory
  Assert-True ($ambiguousScopeResult.status -ceq "refused" -and
    $ambiguousScopeResult.reason -ceq "PIPELINE_BREAKER_OPEN" -and
    $ambiguousScopeResult.changeScope.classification -ceq "deployable" -and
    $ambiguousScopeResult.changeScope.proven -eq $false -and
    $ambiguousScopeResult.changeScope.checkCandidateCount -eq 2 -and
    $ambiguousScopeResult.changeScope.checkCandidates.Count -eq 2) `
    "ambiguous N-candidate scope is retained and fails closed as deployable"

  $headRaceScopeResult = Invoke-ScopeBreakerFixture @(
    (New-ScopeBreakerObservation $nonDeployableScope $headA),
    (New-ScopeBreakerObservation (New-SyntheticChangeScope "non-deployable" $headB) $headB)
  ) $currentHistory
  Assert-True ($headRaceScopeResult.status -ceq "unknown" -and
    $headRaceScopeResult.reason -ceq "HEAD_MOVED_BETWEEN_READS" -and
    $headRaceScopeResult.mutationCount -eq 0 -and
    $headRaceScopeResult.observations.initial.changeScope.evaluatedHead -ceq $headA -and
    $headRaceScopeResult.observations.final.changeScope.evaluatedHead -ceq $headB) `
    "an exact PR-head race remains terminal before mutation even when both heads separately classify non-deployable"

  $movedScopeResult = Invoke-ScopeBreakerFixture @(
    (New-ScopeBreakerObservation (New-SyntheticChangeScope "non-deployable" $headA 1 7101)),
    (New-ScopeBreakerObservation (New-SyntheticChangeScope "non-deployable" $headA 1 7102))
  ) $currentHistory
  Assert-True ($movedScopeResult.status -ceq "refused" -and
    $movedScopeResult.reason -ceq "PIPELINE_BREAKER_OPEN" -and
    $movedScopeResult.mutationCount -eq 0 -and
    $movedScopeResult.changeScope.classification -ceq "deployable" -and
    $movedScopeResult.changeScope.proven -eq $false -and
    $movedScopeResult.changeScope.reason -ceq "CHANGE_SCOPE_MOVED_BETWEEN_READS") `
    "moving same-head Change Scope authority fails closed before enqueue"

  # The actual current collector output flows into both Report and Apply.
  # Mutants execute this same inert entrypoint; only the named clause changes.
  $scopeInitial = New-ScopeBreakerObservation $nonDeployableScope
  $scopeFinal = Copy-TestValue $scopeInitial
  $scopeFinal.changeScope.evidence.outputSha256 = 'f' * 64
  $drift = Invoke-ScopeBreakerFixture @($scopeInitial, $scopeFinal) $currentHistory
  Assert-True ($drift.reason -ceq 'PIPELINE_BREAKER_OPEN' -and $drift.mutationCount -eq 0 -and
    $drift.changeScope.reason -ceq 'CHANGE_SCOPE_MOVED_BETWEEN_READS') 'current output hash drift reaches scope reread guard'
  $otherAuthority = Copy-TestValue $scopeInitial
  $otherAuthority.deploy.conclusion = 'failure'
  $other = Invoke-ScopeBreakerFixture @($otherAuthority, $otherAuthority) $currentHistory
  Assert-True ($other.reason -ceq 'DEPLOY_UNHEALTHY' -and $other.mutationCount -eq 0) 'scope-output-through-report-apply does not bypass deploy authority'
  foreach ($mutant in @(
      @{name='skip-scope-reread';before='if (-not $scopeStable)';after='if ($false)';observations=@($scopeInitial,$scopeFinal)},
      @{name='scope-bypasses-other-authority';before='if ([string]$Observation.deploy.status -cne "completed" -or';after='if ($false -and [string]$Observation.deploy.status -cne "completed" -or';observations=@()}
    )) {
    $mutantSource = [IO.File]::ReadAllText($preflight)
    if ($mutant.name -ceq 'scope-bypasses-other-authority') {
      # Remove just the complete deploy predicate; the positive scope and all
      # review/queue/check/breaker facts remain identical to its red control.
      $mutant.before = '[string]$Observation.deploy.status -cne "completed" -or' + "`n" + '      [string]$Observation.deploy.conclusion -cne "success"'
      $mutantSource = $mutantSource.Replace("`r`n", "`n")
      $mutant.after = '$false'
      $mutant.observations = @($otherAuthority,$otherAuthority)
    }
    Assert-True ($mutantSource.Contains($mutant.before, [StringComparison]::Ordinal)) "Apply mutant $($mutant.name) clause exists"
    $mutantSource = $mutantSource.Replace($mutant.before, $mutant.after).Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'"))
    $control = [ordered]@{schema='landing-preflight-fixture/v1';scenarios=[ordered]@{scope=[ordered]@{
          observations=$mutant.observations;mutation=[ordered]@{complete=$true;entryId='MQE_SYNTHETIC_7972_MUTANT'} }}}
    $controlPath = Write-JsonFixture "scope-$($mutant.name).json" $control
    $bypass = & ([scriptblock]::Create($mutantSource)) -Pr 6254 -Action Apply -HistoryPath $currentHistory -AuthorityFixture $controlPath -AuthorityScenario scope | ConvertFrom-Json -DateKind String
    Assert-True ($bypass.reason -ceq 'ENQUEUE_CONFIRMED' -and $bypass.mutationCount -eq 1) "Apply mutant $($mutant.name) exposes intended bypass"
    Write-Output "KILLED scope mutant=$($mutant.name) intended-clause=Apply"
  }
  Write-Output 'PASS scope-output-through-report-apply current collector output, stable breaker identity, drift and other-authority zero-mutation controls'

  Write-Output "PASS scope-aware breaker hosted-output binding, job/run-attempt equality, deployable/non-deployable/missing/stale/moving matrix, exact-head race, breaker identity, and typed 0/1/N preservation"
  if ($RegressionOnly -eq "ScopeAwareBreakerOnly") { return }

  $continuationSource = New-Pass $headB
  $sourcePath = New-History @($continuationSource)
  $sourceReduction = Reduce-ExactHeadReview -Pr 6254 -CurrentHead $headB `
    -History (Read-ExactHeadReviewHistory -Path $sourcePath)
  $continuation = [pscustomobject][ordered]@{
    ts = [datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')
    kind = 'repair-complete'
    continuationSchema = 'rebase-only-continuation/v1'
    pr = 6254
    reviewedHead = $headB
    predecessorHead = $headB
    newHead = $headA
    newBase = $repairBase
    sourcePassReceiptIdentity = $sourceReduction.latest.receiptIdentity
    integrationLane = 'synthetic-pr6254-integration'
    reviewedBase = $repairHead
    patchPairs = [object[]]@([ordered]@{
        reviewedCommit=$repairHead; newCommit=$headA
        reviewedPatchId=('1' * 40); newPatchId=('1' * 40)
      })
    rangeDiff = 'semantic-patch-equivalent'
    conflictResolution = $false
  }
  $continuationHistory = New-History @($continuationSource, $continuation)
  $continuationFixtureValue = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json -Depth 100 -DateKind String
  foreach ($observation in @($continuationFixtureValue.scenarios.eligible.observations)) {
    $observation.pr | Add-Member -NotePropertyName baseHead -NotePropertyValue $repairBase -Force
  }
  $continuationFixturePath = Join-Path $testRoot 'continuation-authority-fixture.json'
  [IO.File]::WriteAllText($continuationFixturePath, ($continuationFixtureValue | ConvertTo-Json -Depth 100))
  $continuationApply = Invoke-Preflight 'eligible' $continuationHistory -FixturePath $continuationFixturePath
  Assert-True ($continuationApply.status -ceq 'enqueued' -and
    $continuationApply.mutationCount -eq 1 -and
    $continuationApply.review.state -ceq 'authorized' -and
    $continuationApply.review.reason -ceq 'QUALIFIED_REBASE_ONLY_CONTINUATION' -and
    $continuationApply.review.latest.reviewedHead -ceq $headB -and
    $continuationApply.review.latest.authorizedHead -ceq $headA) `
    'Apply did not admit green new-head CI through the exact qualified continuation'

  $wrongSource = Copy-TestValue $continuation
  $wrongSource.reviewedHead = $repairHead
  $wrongSourceHistory = New-History @($continuationSource, $wrongSource)
  $wrongSourceResult = Invoke-Preflight 'eligible' $wrongSourceHistory -FixturePath $continuationFixturePath
  Assert-True ($wrongSourceResult.status -ceq 'unknown' -and $wrongSourceResult.mutationCount -eq 0 -and
    $wrongSourceResult.reason -match '^REVIEW_AUTHORITY_CONTINUATION_SOURCE_PASS_') `
    'a continuation naming the wrong reviewed head did not fail closed'

  $changedPatch = Copy-TestValue $continuation
  $changedPatch.patchPairs[0].newPatchId = '2' * 40
  $changedPatchResult = Invoke-Preflight 'eligible' (New-History @($continuationSource, $changedPatch)) -FixturePath $continuationFixturePath
  Assert-True ($changedPatchResult.status -ceq 'unknown' -and $changedPatchResult.mutationCount -eq 0 -and
    $changedPatchResult.reason -ceq 'REVIEW_AUTHORITY_MALFORMED_REBASE_ONLY_CONTINUATION') `
    'a changed per-commit patch id did not fail closed'

  $conflict = Copy-TestValue $continuation
  $conflict.conflictResolution = $true
  $conflictResult = Invoke-Preflight 'eligible' (New-History @($continuationSource, $conflict)) -FixturePath $continuationFixturePath
  Assert-True ($conflictResult.status -ceq 'unknown' -and $conflictResult.mutationCount -eq 0) `
    'conflict resolution fabricated continuation authority without DELTA'
  $deltaReceipt = New-Pass $headA
  $deltaReceipt.reviewerAttempt = 'synthetic-delta-review'
  $deltaReceipt.authorAttempt = 'synthetic-integration-author'
  $deltaResult = Invoke-Preflight 'eligible' (New-History @($continuationSource, $deltaReceipt)) -FixturePath $continuationFixturePath
  Assert-True ($deltaResult.status -ceq 'enqueued' -and $deltaResult.review.reason -ceq 'LATEST_EXACT_HEAD_PASS') `
    'a bounded exact-new-head DELTA PASS did not restore ordinary landing authority'
  $wrongBaseFixtureValue = Copy-TestValue $continuationFixtureValue
  foreach ($observation in @($wrongBaseFixtureValue.scenarios.eligible.observations)) {
    $observation.pr.baseHead = $repairHead
  }
  $wrongBaseFixturePath = Join-Path $testRoot 'continuation-wrong-base-fixture.json'
  [IO.File]::WriteAllText($wrongBaseFixturePath, ($wrongBaseFixtureValue | ConvertTo-Json -Depth 100))
  $wrongBaseResult = Invoke-Preflight 'eligible' $continuationHistory -FixturePath $wrongBaseFixturePath
  Assert-True ($wrongBaseResult.status -ceq 'unknown' -and $wrongBaseResult.mutationCount -eq 0 -and
    $wrongBaseResult.reason -ceq 'CONTINUATION_BASE_HEAD_MISMATCH') `
    "a continuation whose recorded new base is not the canonical current main head did not fail closed (status=$($wrongBaseResult.status), reason=$($wrongBaseResult.reason), mutations=$($wrongBaseResult.mutationCount))"
  Write-Output 'PASS landing Apply continuation positive, wrong-source, changed-patch, conflict-without-DELTA, canonical-base mismatch, and DELTA-positive controls'
  if ($RegressionOnly -eq 'ContinuationOnly') { return }

  $precursorZeroOne = New-Pass $headB
  $precursorZeroOne.pr = 0
  $precursorZeroOne.reviewerAttempt = "precursor-zero-review-one"
  $precursorZeroOne.authorAttempt = "precursor-zero-author-one"
  $precursorZeroTwo = New-Pass $headA
  $precursorZeroTwo.pr = 0
  $precursorZeroTwo.reviewerAttempt = "precursor-zero-review-two"
  $precursorZeroTwo.authorAttempt = "precursor-zero-author-two"
  $poisonReadThroughHistory = New-History @($precursorZeroOne, $precursorZeroTwo, (New-Pass $headA))
  $poisonReadThrough = Invoke-Preflight "eligible" $poisonReadThroughHistory -Action Report
  Assert-True ($poisonReadThrough.status -eq "eligible" -and
    $poisonReadThrough.reason -eq "REPORT_ONLY_ELIGIBLE" -and
    $poisonReadThrough.mutationCount -eq 0 -and
    $poisonReadThrough.review.audit.quarantinedNonPrReceipts -eq 2 -and
    $poisonReadThrough.review.audit.validRelevantReceipts -eq 1) `
    "two historical pr:0 rows are quarantined while the target's valid exact-head PASS alone authorizes"

  $livePlanningLine16343 = '{"ts":"2026-09-09T10:49:03.2980812+00:00","kind":"review-complete","issue":7735,"lane":"20260909-7735-glossary-conformance-review-r1","laneRole":"planning","harness":"codex","model":"gpt-5.6-sol","authorModel":"claude-opus-5","effort":"high","authorEffort":"high","row":"8","placement":"measured","transcript":"7735-sol-high-glossary-conformance-planning-review-r1.jsonl","outcome":"BLOCK_REPLAN","planningContract":"planning-repair/v1","planningRound":1,"completeSweep":true,"reviewedHead":"6feb1454cecb4a73a90845103a9a0de2a336eaad","reviewerAttempt":"7735-sol-high-glossary-conformance-planning-review-r1","authorAttempt":"7735-opus5-high-glossary-conformance-plan-r1","findingIds":["F1","F2","F3","F4","F5"],"nonBlockingIds":["N1"],"repairOwner":"author","disposition":"REPLACED","note":"Qualified terminal planning review receipt."}' | ConvertFrom-Json -DateKind String
  $planningControlHistory = New-History @($livePlanningLine16343, (New-Pass $headA))
  $planningControl = Invoke-Preflight "eligible" $planningControlHistory -Action Report
  Assert-True ($planningControl.status -eq "eligible" -and
    $planningControl.reason -eq "REPORT_ONLY_ELIGIBLE" -and
    $planningControl.mutationCount -eq 0 -and
    $planningControl.review.audit.planningReceiptsIgnored -eq 1 -and
    $planningControl.review.audit.planningReceiptDetails[0].line -eq 1 -and
    $planningControl.review.audit.planningReceiptDetails[0].issue -eq 7735 -and
    $planningControl.review.audit.malformedExactHeadReceipts -eq 0 -and
    $planningControl.review.audit.validRelevantReceipts -eq 1) `
    "Report excludes the exact live line-16343 planning shape while reducing the requested PR's own PASS"

  $legacyLines = [object[]]@(Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures/legacy-non-pr-review-history.jsonl"))
  $syntheticLegacyTarget = New-Pass $headA
  $syntheticLegacyTarget.reviewerAttempt = "synthetic-7837-legacy-target-reviewer"
  $syntheticLegacyTarget.authorAttempt = "synthetic-7837-legacy-target-author"
  $legacyApply = Invoke-Preflight "eligible" (New-History ([object[]](@($legacyLines) + @($syntheticLegacyTarget))))
  Assert-True ($legacyApply.status -ceq "enqueued" -and
    $legacyApply.reason -ceq "ENQUEUE_CONFIRMED" -and
    $legacyApply.mutationCount -eq 1 -and
    $legacyApply.review.audit.validRelevantReceipts -eq 1 -and
    $legacyApply.review.audit.quarantinedNonPrReceipts -eq 25 -and
    @($legacyApply.review.audit.quarantinedNonPrReceiptDetails | Where-Object {
        $_.reason -cne "LEGACY_NON_PR_NON_EXACT_HEAD_REVIEW" -or $null -ne $_.pr
      }).Count -eq 0) `
    "synthetic Apply fixture did not admit the qualified target through all 25 genuine legacy non-PR records"

  $otherMalformed = New-Pass $headA
  $otherMalformed.pr = 9002
  $otherMalformed.reviewerAttempt = $otherMalformed.authorAttempt
  $controllerMalformed = [ordered]@{ kind="review-complete"; controllerHead=$headA; controllerReviewSchema="malformed-controller-row" }
  $isolatedHistory = New-History @($otherMalformed, $controllerMalformed, (New-Pass $headA))
  $isolatedApply = Invoke-Preflight "eligible" $isolatedHistory
  Assert-True ($isolatedApply.status -ceq "enqueued" -and $isolatedApply.reason -ceq "ENQUEUE_CONFIRMED" -and
     $isolatedApply.mutationCount -eq 1 -and $isolatedApply.review.audit.quarantinedOtherPrReceipts -eq 1 -and
     $isolatedApply.review.audit.controllerReceiptsIgnored -eq 1 -and $isolatedApply.review.audit.validRelevantReceipts -eq 1) `
     "Apply did not isolate PR A authority from malformed PR B and controller receipts"

  $poisonOnly = Invoke-Preflight "eligible" (New-History @($precursorZeroOne, $precursorZeroTwo))
  Assert-True ($poisonOnly.status -eq "unknown" -and
    $poisonOnly.reason -eq "REVIEW_AUTHORITY_NO_REVIEW_HISTORY" -and
    $poisonOnly.mutationCount -eq 0) `
    "historical pr:0 rows cannot authorize when the target PASS is absent"

  $poisonWithStale = Invoke-Preflight "eligible" (New-History @(
      $precursorZeroOne,
      $precursorZeroTwo,
      (New-Pass $headB)
    ))
  Assert-True ($poisonWithStale.status -eq "refused" -and
    $poisonWithStale.reason -eq "REVIEW_STALE_CURRENT_HEAD_HAS_NO_TERMINAL_REVIEW" -and
    $poisonWithStale.mutationCount -eq 0) `
    "historical pr:0 rows cannot promote a stale positive-target PASS"

  $matchingMalformed = New-Pass $headA
  $matchingMalformed.reviewerAttempt = $matchingMalformed.authorAttempt
  $poisonWithMatchingMalformed = Invoke-Preflight "eligible" (New-History @(
      $precursorZeroOne,
      $precursorZeroTwo,
      (New-Pass $headA),
      $matchingMalformed
    ))
  Assert-True ($poisonWithMatchingMalformed.status -eq "unknown" -and
    $poisonWithMatchingMalformed.reason -eq "REVIEW_AUTHORITY_MALFORMED_EXACT_HEAD_RECEIPT" -and
    $poisonWithMatchingMalformed.mutationCount -eq 0) `
    "a malformed row for the requested positive PR still poisons that PR"

  $report = Invoke-Preflight "eligible" $currentHistory -Action Report
  Assert-True ($report.status -eq "eligible" -and
    $report.reason -eq "REPORT_ONLY_ELIGIBLE" -and
    $report.mutationCount -eq 0) "default/report path is eligible and non-mutating"

  $applied = Invoke-Preflight "eligible" $currentHistory
  Assert-True ($applied.status -eq "enqueued" -and
    $applied.reason -eq "ENQUEUE_CONFIRMED" -and
    $applied.mutationCount -eq 1 -and
    $applied.mergeQueueEntryId -eq "MQE_fixture_6254") "apply re-proves authority and calls exactly one mutation"

  $hardDisabled = Invoke-Preflight "eligible" $currentHistory -MutationDisabled
  Assert-True ($hardDisabled.status -eq "refused" -and
    $hardDisabled.reason -eq "MUTATION_HARD_DISABLED" -and
    $hardDisabled.mutationCount -eq 0) "mutation hard-disable is terminal"

  $refusals = [ordered]@{
    "pagination-failure" = "ISSUE_DEPENDENCY_PAGINATION_INCOMPLETE"
    "head-movement" = "HEAD_MOVED_BETWEEN_READS"
    "draft" = "PR_DRAFT"
    "red-required-check" = "REQUIRED_CHECK_NOT_GREEN"
    "native-blocker" = "OPEN_NATIVE_ISSUE_BLOCKER"
    "unhealthy-breaker" = "PIPELINE_BREAKER_OPEN"
    "already-enqueued" = "PR_ALREADY_ENQUEUED"
  }
  foreach ($entry in $refusals.GetEnumerator()) {
    $result = Invoke-Preflight $entry.Key $currentHistory
    Assert-True ($result.status -in @("refused", "unknown") -and
      $result.reason -eq $entry.Value -and
      $result.mutationCount -eq 0) "$($entry.Key) refuses with zero mutations (observed=$($result | ConvertTo-Json -Compress -Depth 12))"
  }

  $p0FixtureValue = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json -DateKind String
  $p0Observation = Copy-TestValue $p0FixtureValue.scenarios.'unhealthy-deploy'.observations[0]
  $p0Scenario = [pscustomobject][ordered]@{
    observations = @($p0Observation, (Copy-TestValue $p0Observation))
    mutation = [ordered]@{ complete=$true; entryId='MQE_fixture_p0_6254' }
  }
  $p0FixtureValue.scenarios | Add-Member -NotePropertyName 'controller-p0-direct' -NotePropertyValue $p0Scenario
  $p0FixturePath = Join-Path $testRoot 'controller-p0-direct.fixture.json'
  [IO.File]::WriteAllText($p0FixturePath, ($p0FixtureValue | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
  $p0History = New-History @((New-Pass $headA))
  $p0Result = Invoke-Preflight 'controller-p0-direct' $p0History -FixturePath $p0FixturePath
  $p0Rows = @(Get-Content -LiteralPath $p0History | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
  $stallRows = @($p0Rows | Where-Object { $_.kind -ceq 'landing-stall' })
  Assert-True ($p0Result.status -ceq 'enqueued' -and $p0Result.reason -ceq 'CONTROLLER_P0_DIRECT_ENQUEUE_CONFIRMED' -and
    $p0Result.mutationCount -eq 1 -and $p0Result.enqueueAttempts -eq 1 -and $p0Result.mergeQueueEntryId -ceq 'MQE_fixture_p0_6254' -and
    $stallRows.Count -eq 1 -and $stallRows[0].refusalReason -ceq 'DEPLOY_UNHEALTHY' -and
    $stallRows[0].enqueue.attempted -eq $true -and $stallRows[0].enqueue.result -ceq 'confirmed' -and
    $stallRows[0].enqueue.entryId -ceq 'MQE_fixture_p0_6254' -and $stallRows[0].enqueue.expectedHeadOid -ceq $headA -and
    $stallRows[0].enqueue.jump -eq $false) `
    "controller P0 direct enqueue did not atomically record refusal and actual once-only enqueue"

  $reconcileQueueEntry = [ordered]@{ valid=$true; stable=[ordered]@{
      entryId='MQE_fixture_p0_reconciled'; pullRequest=[ordered]@{ number=6254; id='PR_fixture_6254'; headOid=$headA }
    } }
  $reconcileObservation = Copy-TestValue $p0Observation
  $reconcileObservation.admission = [ordered]@{ queue=[ordered]@{ complete=$true; entries=@($reconcileQueueEntry) } }
  $reconcileScenario = [pscustomobject][ordered]@{
    observations=@((Copy-TestValue $p0Observation),(Copy-TestValue $p0Observation),$reconcileObservation)
    mutation=[ordered]@{ complete=$false; entryId=$null }
  }
  $p0FixtureValue.scenarios | Add-Member -NotePropertyName 'controller-p0-reconcile' -NotePropertyValue $reconcileScenario
  [IO.File]::WriteAllText($p0FixturePath, ($p0FixtureValue | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
  $reconcileHistory = New-History @((New-Pass $headA))
  $reconciled = Invoke-Preflight 'controller-p0-reconcile' $reconcileHistory -FixturePath $p0FixturePath
  Assert-True ($reconciled.status -ceq 'enqueued' -and $reconciled.mutationCount -eq 1 -and
    $reconciled.landingStall.enqueue.result -ceq 'reconciled' -and
    $reconciled.mergeQueueEntryId -ceq 'MQE_fixture_p0_reconciled') `
    "unknown direct-enqueue response was not reconciled from the queue before any retry"

  $nonqualifiedHistory = New-History @((New-Pass $headA))
  $nonqualifiedBefore = [IO.File]::ReadAllBytes($nonqualifiedHistory)
  $nonqualified = Invoke-Preflight 'red-required-check' $nonqualifiedHistory
  Assert-True ($nonqualified.status -ceq 'refused' -and $nonqualified.mutationCount -eq 0 -and
    [Linq.Enumerable]::SequenceEqual([byte[]]$nonqualifiedBefore, [byte[]][IO.File]::ReadAllBytes($nonqualifiedHistory))) `
    "non-landing-authority-complete PR was mutated or received fabricated landing-stall evidence"
  $controllerCandidateHistory = New-History @((New-Pass $headA))
  $controllerCandidateBefore = [IO.File]::ReadAllBytes($controllerCandidateHistory)
  $controllerCandidate = Invoke-Preflight 'controller-p0-direct' $controllerCandidateHistory -FixturePath $p0FixturePath -ControllerCandidate
  Assert-True ($controllerCandidate.status -ceq 'refused' -and $controllerCandidate.reason -ceq 'DEPLOY_UNHEALTHY' -and
    $controllerCandidate.mutationCount -eq 0 -and [Linq.Enumerable]::SequenceEqual([byte[]]$controllerCandidateBefore, [byte[]][IO.File]::ReadAllBytes($controllerCandidateHistory))) `
    "controller candidate crossed the product-PR direct enqueue exception"

  $parentOnlyHistory = New-History @((New-Pass $headB))
  $parentOnly = Invoke-Preflight "eligible" $parentOnlyHistory
  Assert-True ($parentOnly.status -eq "refused" -and
    $parentOnly.reason -match "^REVIEW_STALE_" -and
    $parentOnly.mutationCount -eq 0) "parent-only PASS cannot authorize the current head"

  $emptyHistory = New-History @()
  $unknownReview = Invoke-Preflight "eligible" $emptyHistory
  Assert-True ($unknownReview.status -eq "unknown" -and
    $unknownReview.reason -eq "REVIEW_AUTHORITY_NO_REVIEW_HISTORY" -and
    $unknownReview.mutationCount -eq 0) "missing exact-head review authority is unknown and non-mutating"

  $unreadableHistory = Join-Path $testRoot "does-not-exist.jsonl"
  $unreadable = Invoke-Preflight "eligible" $unreadableHistory
  Assert-True ($unreadable.status -eq "unknown" -and
    $unreadable.reason -eq "REVIEW_AUTHORITY_HISTORY_MISSING" -and
    $unreadable.mutationCount -eq 0) "unreadable review history refuses before mutation"

  $malformedHistory = Join-Path $testRoot "malformed.jsonl"
  [IO.File]::WriteAllText($malformedHistory, '{"kind":"review-complete"', [Text.UTF8Encoding]::new($false))
  $malformed = Invoke-Preflight "eligible" $malformedHistory
  Assert-True ($malformed.status -eq "unknown" -and
    $malformed.reason -eq "REVIEW_AUTHORITY_HISTORY_MALFORMED" -and
    $malformed.mutationCount -eq 0) "unattributed malformed history cannot fabricate requested-PR authority"

  $truncatedHistory = New-History @((New-Pass $headA), (New-Pass $headA))
  $truncated = Invoke-Preflight "eligible" $truncatedHistory -MaxHistoryRows 1
  Assert-True ($truncated.status -eq "unknown" -and
    $truncated.reason -eq "REVIEW_AUTHORITY_HISTORY_TRUNCATED" -and
    $truncated.mutationCount -eq 0) "truncated review history refuses before mutation"

  $ambiguousPass = New-Pass $headA
  $ambiguousBlock = New-Pass $headA
  $ambiguousBlock.ts = $ambiguousPass.ts
  $ambiguousBlock.reviewerAttempt = "review-6254-other"
  $ambiguousBlock.outcome = "BLOCK_FIXABLE"
  $ambiguousBlock.findingIds = @("F_AMBIGUOUS")
  $ambiguousBlock.findings = [ordered]@{ blocking = 1; candidates = 1; nonBlocking = 0 }
  $contradictoryHistory = New-History @($ambiguousPass, $ambiguousBlock)
  $contradictory = Invoke-Preflight "eligible" $contradictoryHistory
  Assert-True ($contradictory.status -eq "unknown" -and
    $contradictory.reason -eq "REVIEW_AUTHORITY_TERMINAL_ORDER_AMBIGUOUS" -and
    $contradictory.mutationCount -eq 0) "contradictory terminal authority refuses before mutation"

  $source = Get-Content -LiteralPath $preflight -Raw
  Assert-True (@([regex]::Matches($source, "mutation\(\`$pullRequestId:ID!")).Count -eq 1) `
    "the production preflight contains exactly one canonical enqueue mutation definition"
  Assert-True ($source -match "enqueuePullRequest\(input:") "the canonical mutation is GitHub enqueuePullRequest"

  Write-Output "PASS landing-preflight report/apply, final re-read, exact-head, pagination, draft, checks, blockers, deploy, breaker, and zero-mutation refusal coverage"
} finally {
  foreach ($name in @(
      "LANDING_PREFLIGHT_MOCK_GRAPH",
      "LANDING_PREFLIGHT_MOCK_RUNS",
      "LANDING_PREFLIGHT_MOCK_RUNS_EXIT",
      "LANDING_PREFLIGHT_MOCK_LOG"
    )) {
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
  }
  Get-ChildItem Env: |
    Where-Object {
      $_.Name -like "LANDING_PREFLIGHT_MOCK_JOBS_*" -or
      $_.Name -like "LANDING_PREFLIGHT_MOCK_SCOPE_JOB_*" -or
      $_.Name -like "LANDING_PREFLIGHT_MOCK_SCOPE_RUN_*" -or
      $_.Name -like "LANDING_PREFLIGHT_MOCK_SCOPE_LOG_*"
    } |
    ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null, "Process") }
  $resolved = [IO.Path]::GetFullPath($testRoot)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
  if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
      (Split-Path -Leaf $resolved) -notlike "landing-preflight-test-*") {
    throw "refusing unsafe test cleanup target: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  Exit-RoutingDataTestScope $routingTestScope
}

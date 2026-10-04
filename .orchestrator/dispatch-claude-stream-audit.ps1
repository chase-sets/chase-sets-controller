# Fail-closed completion audit for Claude CLI stream-json. Task identities use
# the snake_case fields emitted by current Claude plus known camelCase variants.

function Get-ClaudeEventField([object]$Object, [string[]]$Names) {
  if ($null -eq $Object) { return $null }
  foreach ($name in $Names) {
    $property = $Object.PSObject.Properties[$name]
    if ($property -and $null -ne $property.Value -and [string]$property.Value) {
      return [string]$property.Value
    }
  }
  return $null
}

function Add-ClaudeTerminalTaskState(
  [System.Collections.IDictionary]$States,
  [string]$TaskId,
  [string]$State
) {
  $existing = if ($States.Contains($TaskId)) { [string]$States[$TaskId] } else { "" }
  if (($existing -split "/") -notcontains $State) {
    $States[$TaskId] = if ($existing) { "$existing/$State" } else { $State }
  }
}

function Test-ClaudeStreamJsonCompletion([string]$Path) {
  $taskDescriptions = [ordered]@{}
  $activeTasks = [ordered]@{}
  $activeAtSuccess = [ordered]@{}
  $terminalStates = [ordered]@{}
  $auditErrors = [Collections.Generic.List[string]]::new()
  $resultCount = 0
  $successfulResultSeen = $false
  $lineNumber = 0

  foreach ($line in [IO.File]::ReadLines($Path)) {
    $lineNumber++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try {
      $event = $line | ConvertFrom-Json -Depth 100
    } catch {
      $auditErrors.Add("malformed stream-json at line $lineNumber")
      continue
    }

    if ($event.type -eq "system" -and $event.subtype -eq "background_tasks_changed") {
      $tasksProperty = $event.PSObject.Properties["tasks"]
      if (-not $tasksProperty -or $null -eq $tasksProperty.Value) {
        $auditErrors.Add("background task snapshot at line $lineNumber has no tasks array")
        continue
      }

      $nextActiveTasks = [ordered]@{}
      foreach ($task in @($tasksProperty.Value)) {
        $taskId = Get-ClaudeEventField $task @("task_id", "taskId", "id")
        if (-not $taskId) {
          $auditErrors.Add("background task snapshot at line $lineNumber contains a task without an identity")
          continue
        }

        $description = Get-ClaudeEventField $task @("description", "summary", "task_type", "taskType")
        if (-not $description) { $description = "description unavailable" }
        $taskDescriptions[$taskId] = $description
        $nextActiveTasks[$taskId] = $description

        $snapshotState = (Get-ClaudeEventField $task @("status", "state"))
        if ($snapshotState -and $snapshotState.ToLowerInvariant() -in @("killed", "stopped")) {
          Add-ClaudeTerminalTaskState $terminalStates $taskId $snapshotState.ToLowerInvariant()
        }
      }
      $activeTasks = $nextActiveTasks

      # A task first reported after a successful result was not cleared before
      # delivery completed, even if shutdown later emits an empty snapshot.
      if ($successfulResultSeen) {
        foreach ($taskId in $activeTasks.Keys) {
          $activeAtSuccess[$taskId] = $activeTasks[$taskId]
        }
      }
    }

    if ($event.subtype -in @("task_updated", "task_notification")) {
      $taskId = Get-ClaudeEventField $event @("task_id", "taskId", "id")
      $description = Get-ClaudeEventField $event @("description", "summary")
      if ($taskId -and $description) {
        $taskDescriptions[$taskId] = $description
      }
      $taskState = Get-ClaudeEventField $event @("status", "state")
      if (-not $taskState) {
        $taskState = Get-ClaudeEventField $event.patch @("status", "state")
      }
      if ($taskState -and $taskState.ToLowerInvariant() -in @("killed", "stopped")) {
        if ($taskId) {
          Add-ClaudeTerminalTaskState $terminalStates $taskId $taskState.ToLowerInvariant()
        } else {
          $auditErrors.Add("task event at line $lineNumber has state $($taskState.ToLowerInvariant()) but no identity")
        }
      }
    }

    if ($event.type -eq "result") {
      $resultCount++
      $isError = $event.PSObject.Properties["is_error"]
      if ($event.subtype -eq "success" -and (-not $isError -or -not [bool]$isError.Value)) {
        $successfulResultSeen = $true
        foreach ($taskId in $activeTasks.Keys) {
          $activeAtSuccess[$taskId] = $activeTasks[$taskId]
        }
      }
    }
  }

  if ($resultCount -ne 1) {
    $auditErrors.Add("expected exactly one result event; observed $resultCount")
  } elseif (-not $successfulResultSeen) {
    $auditErrors.Add("the result event did not report success")
  }

  foreach ($taskId in @($activeTasks.Keys)) {
    $activeAtSuccess[$taskId] = $activeTasks[$taskId]
  }
  foreach ($taskId in @($activeAtSuccess.Keys | Sort-Object)) {
    $auditErrors.Add("task $taskId state active at delivery success ($($activeAtSuccess[$taskId]))")
  }
  foreach ($taskId in @($terminalStates.Keys | Sort-Object)) {
    $states = [string]$terminalStates[$taskId]
    $description = if ($taskDescriptions.Contains($taskId)) { $taskDescriptions[$taskId] } else { "description unavailable" }
    $auditErrors.Add("task $taskId state $states ($description)")
  }

  [pscustomobject]@{
    accepted = $auditErrors.Count -eq 0
    diagnostics = @($auditErrors)
  }
}

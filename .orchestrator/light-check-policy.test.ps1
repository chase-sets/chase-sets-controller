$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-lane.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'launcher does not parse' }
$definitions = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-HeavyVerificationPreamble'}, $false))
if ($definitions.Count -ne 1) { throw 'expected one real verification preamble' }
. ([scriptblock]::Create($definitions[0].Extent.Text))
foreach ($role in @('implementation','planning','review','decision')) {
  foreach ($row in @(7,13)) {
    $text = Get-HeavyVerificationPreamble $role $row 'synthetic-heavy-wrapper'
    foreach ($required in @('Scoped compiler checks and explicit one-worker non-DB test files run directly',
        'do not add acquireHeavySlot or an invoke-heavy-verifier wrapper',
        'Full-workspace, DB and browser checks retain heavy admission',
        'Never run a refused heavy command unadmitted')) {
      if (-not $text.Contains($required, [StringComparison]::Ordinal)) { throw "missing light-check boundary for $role/row-$row : $required" }
    }
  }
}
# Load the actual classifier with an acquisition tripwire, not the native guard.
$check = @'
const assert = require('node:assert/strict');
const Module = require('node:module');
const original = Module._load;
let acquisitions = 0;
Module._load = function(name, ...args) {
  if (name === './heavy-slot.cjs') return () => { acquisitions++; throw Error('unexpected admission'); };
  return original.call(this, name, ...args);
};
delete process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG;
const classifier = require(process.argv[1]);
const scripts = { scoped: 'tsc -p work/scoped.json --noEmit', focused: 'vitest run source/one.test.ts --maxWorkers 1',
  mixed: 'tsc -p work/scoped.json --noEmit && pnpm run verify:test-db', browser: 'playwright test source/one.spec.ts' };
const cases = [
  [['node','node_modules/typescript/bin/tsc','-p','work/scoped.json','--noEmit'], null],
  [['node','pnpm.cjs','run','scoped'], null],
  [['node','pnpm.cjs','run','focused'], null],
  [['node','pnpm.cjs','run','mixed'], 'repository-gate'],
  [['node','pnpm.cjs','run','browser'], 'playwright'],
  [['node','pnpm.cjs','run','verify:test-db'], 'repository-gate'],
  [['node','pnpm.cjs','run','verify'], 'repository-gate'],
  [['node','vitest.mjs','run'], 'vitest-full']
];
for (const [argv, expected] of cases) assert.equal(classifier.classifyCommand(argv, { packageScripts: scripts }), expected, argv.join(' '));
assert.equal(acquisitions, 0);
console.log('PASS actual light/heavy classification; acquisition tripwire untouched; native runtime NOT_RUN');
'@
& node -e $check (Join-Path $PSScriptRoot 'heavy-admission-preload.cjs')
if ($LASTEXITCODE -ne 0) { throw 'light/heavy classifier boundary failed' }
& (Join-Path $PSScriptRoot 'dispatch-lane.test.ps1') -VerificationPolicyOnly
Write-Output 'PASS every lane-role light-check instruction; unknown heavy refusals never authorize a bypass'

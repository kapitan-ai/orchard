import assert from 'node:assert/strict';
import { copyFileSync, mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { parse } from 'yaml';
import { checkPins } from './check-mise-action-pins.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const policy = JSON.parse(readFileSync(join(root, '.github/mise-action-pin.json'), 'utf8'));
const workflow = readFileSync(join(root, '.github/workflows/required-validation.yml'), 'utf8');
const approved = `jdx/mise-action@${policy.sha}`;
const stale = `jdx/mise-action@${'a'.repeat(40)}`;

function fixture(t, text = workflow, record = policy) {
  const dir = mkdtempSync(join(tmpdir(), 'orchard-mise-pin-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, '.github/workflows'), { recursive: true });
  writeFileSync(join(dir, '.github/mise-action-pin.json'), JSON.stringify(record));
  writeFileSync(join(dir, '.github/workflows', policy.requiredWorkflow), text);
  return dir;
}

function replaceInvocation(text, index, replacement) {
  let seen = 0;
  return text.replaceAll(approved, value => ++seen === index ? replacement : value);
}

test('current repository has seven approved invocations', () => assert.equal(checkPins(root), 7));

test('stale seventh invocation fails while the first six remain approved', t => {
  assert.throws(() => checkPins(fixture(t, replaceInvocation(workflow, 7, stale))), /approved immutable SHA/);
});

test('missing seventh pin is rejected', t => {
  assert.throws(() => checkPins(fixture(t, replaceInvocation(workflow, 7, 'jdx/mise-action'))), /approved immutable SHA/);
});

test('deleted seventh invocation is rejected', t => {
  assert.throws(() => checkPins(fixture(t, replaceInvocation(workflow, 7, 'actions/checkout@v7'))), /expected one/);
});

test('dormant assembly invocation is still checked', t => {
  const text = workflow.replace(/(app-distribution-validation:[\s\S]*?)jdx\/mise-action@[a-f0-9]{40}/, `$1${stale}`);
  assert.throws(() => checkPins(fixture(t, text)), /app-distribution-validation: mise-action/);
});

test('uniform stale pins cannot become their own authority', t => {
  assert.throws(() => checkPins(fixture(t, workflow.replaceAll(approved, stale))), /approved immutable SHA/);
});

test('quoted uses keys/values and comments are parsed', t => {
  const text = workflow.replaceAll(`uses: ${approved} # v4.3.0`, `'uses': "${approved}" # ${stale}`);
  assert.equal(checkPins(fixture(t, text)), 7);
});

test('folded YAML scalar is parsed as an invocation', t => {
  const text = workflow.replaceAll(`uses: ${approved} # v4.3.0`, `uses: >- # folded invocation\n          ${approved}`);
  assert.equal(checkPins(fixture(t, text)), 7);
});

test('run strings, env values and comments are not invocations', t => {
  const text = workflow + `\n# uses: ${stale}\n`;
  const dir = fixture(t, text);
  writeFileSync(join(dir, '.github/workflows/notes.yaml'), `jobs:\n  notes:\n    steps:\n      - run: |\n          uses: ${stale}\n        env:\n          uses: ${stale}\n`);
  assert.equal(checkPins(dir), 7);
});

test('flow mappings, aliases and different indentation retain actual uses', t => {
  const dir = fixture(t);
  writeFileSync(join(dir, '.github/workflows/extra.yaml'), `jobs:\n extra:\n  steps:\n   - &setup {uses: '${approved}'}\n   - *setup\n`);
  assert.equal(checkPins(dir), 9);
});

test('additional workflow invocation must use the approved SHA', t => {
  const dir = fixture(t);
  writeFileSync(join(dir, '.github/workflows/extra.yaml'), `jobs:\n extra:\n  steps: [{uses: '${stale}'}]\n`);
  assert.throws(() => checkPins(dir), /extra.yaml: extra/);
});

test('duplicate retained bootstrap is rejected', t => {
  const text = workflow.replace('      - name: Validate Product Version consistency', `      - uses: ${approved}\n\n      - name: Validate Product Version consistency`);
  assert.throws(() => checkPins(fixture(t, text)), /linux-portable: expected one/);
});

test('missing retained workflow fails', t => {
  const dir = fixture(t);
  rmSync(join(dir, '.github/workflows', policy.requiredWorkflow));
  assert.throws(() => checkPins(dir), /expected one/);
});

test('invalid YAML fails closed', t => {
  assert.throws(() => checkPins(fixture(t, 'jobs: [unterminated')), /Invalid workflow YAML/);
});

test('duplicate uses keys fail closed', t => {
  const text = workflow.replace(`uses: ${approved}`, `uses: ${approved}\n        uses: ${stale}`);
  assert.throws(() => checkPins(fixture(t, text)), /Invalid workflow YAML/);
});

test('workflow without a jobs map fails closed', t => {
  for (const text of ['null', 'jobs: null', 'jobs: []', 'jobs: plain']) {
    assert.throws(() => checkPins(fixture(t, text)), /Missing workflow jobs/);
  }
});

test('malformed approved record fails closed', t => {
  for (const record of [
    { ...policy, sha: 'v4' },
    { ...policy, requiredWorkflow: '../elsewhere.yml' },
    { ...policy, requiredJobs: null },
    { ...policy, requiredJobs: [] },
    { ...policy, requiredJobs: [7] },
    { ...policy, requiredJobs: ['../job'] },
    { ...policy, requiredJobs: ['job', 'job'] }
  ]) assert.throws(() => checkPins(fixture(t, workflow, record)), /Invalid approved/);
});

test('action name capitalization cannot bypass checking', t => {
  assert.throws(() => checkPins(fixture(t, replaceInvocation(workflow, 7, stale.toUpperCase()))), /approved immutable SHA/);
});

test('CLI returns success after checking the repository', () => {
  const result = spawnSync(process.execPath, [join(root, 'scripts/ci/check-mise-action-pins.mjs')], { encoding: 'utf8' });
  assert.equal(result.status, 0);
  assert.match(result.stdout, /passed \(7 invocations\)/);
});

test('CLI returns nonzero for a controlled stale-pin repository', t => {
  const dir = fixture(t, replaceInvocation(workflow, 7, stale));
  mkdirSync(join(dir, 'scripts/ci'), { recursive: true });
  copyFileSync(join(root, 'scripts/ci/check-mise-action-pins.mjs'), join(dir, 'scripts/ci/check-mise-action-pins.mjs'));
  symlinkSync(join(root, 'node_modules'), join(dir, 'node_modules'));
  const result = spawnSync(process.execPath, [join(dir, 'scripts/ci/check-mise-action-pins.mjs')], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /approved immutable SHA/);
});

test('existing OpenSpec lane carries both pin gates and preserves aggregate dependency', () => {
  const jobs = parse(workflow).jobs;
  const steps = jobs['openspec-validation'].steps;
  const install = steps.findIndex(step => step.run === 'make setup-openspec');
  const check = steps.findIndex(step => step.run?.includes('npm run check:mise-action-pins'));
  const validate = steps.findIndex(step => step.name === 'Validate OpenSpec');
  assert.ok(install >= 0 && check > install && validate > check);
  assert.match(steps[check].run, /mise exec -- npm run test:mise-action-pins/);
  assert.equal(steps[check]['continue-on-error'], undefined);
  assert.ok(jobs['required-validation-gate'].needs.includes('openspec-validation'));
});

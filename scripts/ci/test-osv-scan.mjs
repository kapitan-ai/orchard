import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { LOCKFILE_NAMES, findings, introduced, lockfiles, parseArgs, run } from './osv-scan.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const script = join(root, 'scripts/ci/osv-scan.mjs');

// Stub scanner: each lockfile line `OSV <ecosystem> <name> <version> <id>...`
// becomes one package. Like OSV-Scanner, it leaves out a lockfile it reads no
// packages from. It records its arguments, can fail, and can add
// ORCHARD_OSV_STUB_LINE to every lockfile.
const stubSource = log => `#!${process.execPath}
const { appendFileSync, readFileSync } = require('node:fs');
const args = process.argv.slice(2);
appendFileSync(${JSON.stringify(log)}, JSON.stringify(args) + '\\n');
if (process.env.ORCHARD_OSV_STUB_STATUS) {
  process.stderr.write('stub failure');
  process.exit(Number(process.env.ORCHARD_OSV_STUB_STATUS));
}
const results = [];
args.forEach((arg, index) => {
  if (arg !== '-L') return;
  const path = args[index + 1];
  const lines = [...readFileSync(path, 'utf8').split('\\n'), process.env.ORCHARD_OSV_STUB_LINE ?? ''];
  const packages = lines.filter(line => line.startsWith('OSV ')).map(line => {
    const [, ecosystem, name, version, ...ids] = line.split(' ');
    return {
      package: { ecosystem, name, version },
      vulnerabilities: ids.map(id => ({ id })),
      groups: ids.length ? [{ ids, max_severity: '7.5' }] : []
    };
  });
  if (packages.length) results.push({ source: { path, type: 'lockfile' }, packages });
});
process.stdout.write(JSON.stringify({ results }));
process.exit(results.some(result => result.packages.some(pkg => pkg.vulnerabilities.length)) ? 1 : 0);
`;

function write(dir, file, text) {
  mkdirSync(dirname(join(dir, file)), { recursive: true });
  writeFileSync(join(dir, file), text);
}

function git(dir, ...args) {
  const result = spawnSync('git', ['-c', 'user.name=Orchard Test', '-c', 'user.email=test@example.invalid', ...args], {
    cwd: dir, encoding: 'utf8'
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function repository(t) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'orchard-osv-scan-')));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const repo = join(dir, 'repo');
  const log = join(dir, 'scanner.log');
  const bin = join(dir, 'osv-scanner');
  writeFileSync(bin, stubSource(log));
  chmodSync(bin, 0o755);
  mkdirSync(repo);
  git(repo, 'init', '--quiet', '--initial-branch=main');
  write(repo, 'mix.lock', 'OSV Hex cowlib 2.20.0 EEF-CVE-1\nOSV Hex mint 1.11.0\n');
  write(repo, 'native/worker/uv.lock', 'OSV PyPI fsspec 2026.9.0\n');
  write(repo, 'README.md', 'OSV Hex ignored 1.0.0 NOT-A-LOCKFILE\n');
  git(repo, 'add', '.');
  git(repo, 'commit', '--quiet', '-m', 'base');
  const scans = () => readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  return { dir, repo, bin, scans };
}

test('parses full, comparison and pass-through arguments', () => {
  assert.deepEqual(parseArgs([]), { scannerArgs: [] });
  assert.deepEqual(parseArgs(['--base', 'origin/main']), { base: 'origin/main', scannerArgs: [] });
  assert.deepEqual(parseArgs(['--', '--offline-vulnerabilities']), { scannerArgs: ['--offline-vulnerabilities'] });
  assert.deepEqual(parseArgs(['--base', 'abc', '--', '--offline']), { base: 'abc', scannerArgs: ['--offline'] });
  for (const argv of [['--base'], ['--base', ''], ['--full'], ['main']]) {
    assert.throws(() => parseArgs(argv), /usage/);
  }
});

test('selects lockfiles by exact file name at any depth', () => {
  assert.deepEqual(
    lockfiles(['', 'README.md', 'mix.lock', 'docs/mix.lock.md', 'proto/tooling/uv.lock', 'package-lock.json', 'uv.lock.orig']),
    ['mix.lock', 'package-lock.json', 'proto/tooling/uv.lock']
  );
});

test('maps scanner output to one finding per advisory with its group severity', () => {
  const report = {
    results: [{
      source: { path: '/work/native/worker/uv.lock' },
      packages: [{
        package: { ecosystem: 'PyPI', name: 'pytest', version: '9.0.2' },
        vulnerabilities: [{ id: 'PYSEC-1' }, { id: 'GHSA-1' }],
        groups: [{ ids: ['PYSEC-1', 'GHSA-1'], aliases: ['CVE-1', 'GHSA-1', 'PYSEC-1'], max_severity: '6.8' }]
      }]
    }]
  };
  const pytest = { lockfile: 'native/worker/uv.lock', ecosystem: 'PyPI', name: 'pytest', version: '9.0.2', severity: '6.8' };
  assert.deepEqual(findings(report, '/work'), [
    { ...pytest, id: 'PYSEC-1', aliases: ['PYSEC-1', 'GHSA-1', 'CVE-1'] },
    { ...pytest, id: 'GHSA-1', aliases: ['GHSA-1', 'PYSEC-1', 'CVE-1'] }
  ]);
  assert.deepEqual(findings({}, '/work'), []);
});

test('reports only advisories the change introduces', () => {
  const finding = (lockfile, name, version, id, aliases = [id]) =>
    ({ lockfile, ecosystem: 'Hex', name, version, id, severity: '', aliases });
  const baseline = [finding('mix.lock', 'cowlib', '2.20.0', 'EEF-1', ['EEF-1', 'GHSA-1'])];
  assert.deepEqual(introduced(baseline, [finding('mix.lock', 'cowlib', '2.20.1', 'EEF-1')]), []);
  // The same advisory reported under an aliased record is not new.
  assert.deepEqual(introduced(baseline, [finding('mix.lock', 'cowlib', '2.20.1', 'GHSA-1')]), []);
  // Records with disjoint IDs that alias the same CVE are the same advisory.
  const cve = [finding('mix.lock', 'cowlib', '2.20.0', 'EEF-3', ['EEF-3', 'CVE-3'])];
  assert.deepEqual(introduced(cve, [finding('mix.lock', 'cowlib', '2.20.1', 'GHSA-3', ['GHSA-3', 'CVE-3'])]), []);
  assert.deepEqual(introduced(baseline, [finding('mix.lock', 'cowlib', '2.20.0', 'EEF-2')]),
    [finding('mix.lock', 'cowlib', '2.20.0', 'EEF-2')]);
  assert.deepEqual(introduced(baseline, [finding('other/mix.lock', 'cowlib', '2.20.0', 'EEF-1')]),
    [finding('other/mix.lock', 'cowlib', '2.20.0', 'EEF-1')]);
});

test('full scan reports every advisory in tracked lockfiles only', t => {
  const { repo, bin, scans } = repository(t);
  const outcome = run([], { root: repo, bin });
  assert.deepEqual(outcome.reported.map(finding => `${finding.lockfile} ${finding.name} ${finding.id}`),
    ['mix.lock cowlib EEF-CVE-1']);
  assert.equal(outcome.mergeBase, undefined);
  const [args] = scans();
  assert.deepEqual(args.slice(0, 5), ['scan', 'source', '--format', 'json', '--all-packages']);
  assert.equal(args.filter(arg => arg === '-L').length, 2);
  assert.ok(!args.some(arg => arg.endsWith('README.md')));
  assert.ok(!args.includes('--config'));
});

test('comparison ignores the existing backlog and fails on introduced advisories', t => {
  const { repo, bin } = repository(t);
  const head = git(repo, 'rev-parse', 'HEAD');
  assert.deepEqual(run(['--base', 'main'], { root: repo, bin }).reported, []);

  write(repo, 'mix.lock', 'OSV Hex cowlib 2.20.0 EEF-CVE-1\nOSV Hex mint 1.9.3 EEF-CVE-2\n');
  write(repo, 'native/tool/uv.lock', 'OSV PyPI pytest 9.0.2 PYSEC-1\n');
  const outcome = run(['--base', 'main'], { root: repo, bin });
  assert.equal(outcome.mergeBase, head);
  assert.deepEqual(outcome.baseline.map(finding => finding.id), ['EEF-CVE-1']);
  // The new lockfile is untracked; a local run still reports it before staging.
  assert.deepEqual(outcome.reported.map(finding => `${finding.lockfile} ${finding.name}@${finding.version} ${finding.id}`),
    ['mix.lock mint@1.9.3 EEF-CVE-2', 'native/tool/uv.lock pytest@9.0.2 PYSEC-1']);

  write(repo, '.gitignore', 'native/tool/\n');
  assert.deepEqual(run(['--base', 'main'], { root: repo, bin }).reported.map(finding => finding.id), ['EEF-CVE-2']);
});

test('comparison uses the merge base, not the moving base branch tip', t => {
  const { repo, bin } = repository(t);
  const forkPoint = git(repo, 'rev-parse', 'HEAD');
  git(repo, 'switch', '--quiet', '-c', 'feature');
  git(repo, 'switch', '--quiet', 'main');
  write(repo, 'mix.lock', 'OSV Hex cowlib 2.21.0\nOSV Hex mint 1.11.0\n');
  git(repo, 'commit', '--quiet', '-am', 'fix cowlib on main');
  git(repo, 'switch', '--quiet', 'feature');

  const outcome = run(['--base', 'main'], { root: repo, bin });
  assert.equal(outcome.mergeBase, forkPoint);
  assert.deepEqual(outcome.reported, []);
});

test('applies the working-tree exception file to both sides and passes scanner arguments', t => {
  const { repo, bin, scans } = repository(t);
  write(repo, 'osv-scanner.toml', '');
  run(['--base', 'main', '--', '--offline-vulnerabilities'], { root: repo, bin });
  const config = join(repo, 'osv-scanner.toml');
  assert.equal(scans().length, 2);
  for (const args of scans()) {
    assert.equal(args[args.indexOf('--config') + 1], config);
    assert.ok(args.includes('--offline-vulnerabilities'));
  }
});

test('scanner failures and unknown bases are errors, not clean results', t => {
  const { repo, bin } = repository(t);
  t.after(() => delete process.env.ORCHARD_OSV_STUB_STATUS);
  process.env.ORCHARD_OSV_STUB_STATUS = '127';
  assert.throws(() => run([], { root: repo, bin }), /osv-scanner exited with status 127: stub failure/);
  delete process.env.ORCHARD_OSV_STUB_STATUS;
  assert.throws(() => run(['--base', 'no-such-ref'], { root: repo, bin }), /git merge-base no-such-ref HEAD failed/);
});

test('a lockfile the scanner reads no packages from fails the scan instead of looking clean', t => {
  const { repo, bin } = repository(t);
  write(repo, 'mix.lock', 'unreadable\n');
  assert.throws(() => run(['--base', 'main'], { root: repo, bin }), /osv-scanner read no packages from \(unreadable or empty\): mix\.lock$/);
  write(repo, 'native/new/uv.lock', 'unreadable\n');
  assert.throws(() => run([], { root: repo, bin }), /read no packages from \(unreadable or empty\): mix\.lock, native\/new\/uv\.lock$/);
});

test('command line exits 0 when clean, 1 on findings and 2 on errors', t => {
  const { dir, repo } = repository(t);
  // Run from a subdirectory: the script scans the enclosing repository.
  const cli = (argv, env = {}) => spawnSync(process.execPath, [script, ...argv], {
    cwd: join(repo, 'native'), encoding: 'utf8', env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, ...env }
  });

  write(repo, 'mix.lock', 'OSV Hex mint 1.11.0\n');
  const clean = cli([]);
  assert.equal(clean.status, 0, clean.stderr);
  assert.match(clean.stdout, /^OSV full scan: 0 known vulnerabilities\.$/m);

  const line = { ORCHARD_OSV_STUB_LINE: 'OSV Hex cowlib 2.20.0 EEF-CVE-1' };
  const dirty = cli([], line);
  assert.equal(dirty.status, 1, dirty.stderr);
  assert.match(dirty.stdout, /^ {2}mix\.lock: Hex cowlib@2\.20\.0 EEF-CVE-1 CVSS 7\.5 https:\/\/osv\.dev\/EEF-CVE-1$/m);

  const unchanged = cli(['--base', 'HEAD'], line);
  assert.equal(unchanged.status, 0, unchanged.stderr);
  assert.match(unchanged.stdout, /^OSV comparison against merge base [0-9a-f]{40}: [1-9]\d* known at the merge base, 0 introduced\.$/m);

  const failed = cli([], { ORCHARD_OSV_STUB_STATUS: '127' });
  assert.equal(failed.status, 2);
  assert.match(failed.stderr, /osv-scanner exited with status 127/);

  const misuse = cli(['--full']);
  assert.equal(misuse.status, 2);
  assert.match(misuse.stderr, /usage/);
});

test('the CI path classifier selects the lane for every scanned lockfile name', () => {
  const classifier = join(root, 'scripts/ci/classify-supply-chain-paths.sh');
  for (const name of LOCKFILE_NAMES) {
    const result = spawnSync(classifier, { input: `native/example/${name}\n`, encoding: 'utf8' });
    assert.equal(result.stdout.trim(), 'supply_chain=true', name);
  }
});

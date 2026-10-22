import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const usage = 'usage: osv-scan.mjs [--base <rev>] [-- <osv-scanner arguments>]';

// Lockfile names OSV-Scanner reads. scripts/ci/classify-supply-chain-paths.sh
// keeps the same list so a lockfile change always selects the CI lane.
export const LOCKFILE_NAMES = new Set([
  'Cargo.lock', 'Gemfile.lock', 'Pipfile.lock', 'bun.lock', 'composer.lock', 'go.mod',
  'mix.lock', 'package-lock.json', 'pnpm-lock.yaml', 'poetry.lock', 'pylock.toml',
  'uv.lock', 'yarn.lock'
]);

export function parseArgs(argv) {
  const separator = argv.indexOf('--');
  const own = separator === -1 ? argv : argv.slice(0, separator);
  const scannerArgs = separator === -1 ? [] : argv.slice(separator + 1);
  if (own.length === 0) return { scannerArgs };
  if (own.length === 2 && own[0] === '--base' && own[1]) return { base: own[1], scannerArgs };
  throw new Error(usage);
}

export function lockfiles(paths) {
  return paths.filter(path => LOCKFILE_NAMES.has(path.split('/').pop())).sort();
}

export function findings(report, root) {
  const rows = [];
  for (const result of report.results ?? []) {
    const lockfile = relative(root, result.source.path);
    for (const { package: pkg, vulnerabilities = [], groups = [] } of result.packages ?? []) {
      for (const { id } of vulnerabilities) {
        const severity = groups.find(group => group.ids?.includes(id))?.max_severity ?? '';
        rows.push({ lockfile, ecosystem: pkg.ecosystem, name: pkg.name, version: pkg.version, id, severity });
      }
    }
  }
  return rows;
}

// A finding is identified by lockfile, package and advisory, not version: a
// bump that leaves the package inside the same advisory range introduces
// nothing, while the same advisory reaching another lockfile does.
const identity = finding => [finding.lockfile, finding.ecosystem, finding.name, finding.id].join('\0');

export function introduced(baseline, current) {
  const known = new Set(baseline.map(identity));
  return current.filter(finding => !known.has(identity(finding)));
}

function git(root, args, encoding = 'utf8') {
  const result = spawnSync('git', args, { cwd: root, encoding, maxBuffer: 256 * 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`git ${args.join(' ')} failed: ${String(result.stderr).trim()}`);
  return result.stdout;
}

function scan(root, files, { bin, config, scannerArgs }) {
  if (!files.length) return [];
  const args = ['scan', 'source', '--format', 'json', ...(config ? ['--config', config] : []), ...scannerArgs];
  for (const file of files) args.push('-L', join(root, file));
  const result = spawnSync(bin, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (result.error) throw result.error;
  // OSV-Scanner exits 1 when it reports vulnerabilities; anything else is a failed scan.
  if (result.status !== 0 && result.status !== 1) {
    throw new Error(`osv-scanner exited with status ${result.status}: ${result.stderr.trim()}`);
  }
  return findings(JSON.parse(result.stdout), root);
}

export function run(argv, { root = repoRoot, bin = 'osv-scanner' } = {}) {
  const { base, scannerArgs } = parseArgs(argv);
  root = realpathSync(root);
  // The working tree's exception file governs both sides of a comparison.
  const configPath = join(root, 'osv-scanner.toml');
  const options = { bin, config: existsSync(configPath) ? configPath : undefined, scannerArgs };
  // Untracked, unignored lockfiles count so a local run sees a change before it is staged.
  const present = lockfiles(git(root, ['ls-files', '-z', '--cached', '--others', '--exclude-standard']).split('\0'));
  const current = scan(root, [...new Set(present)].filter(file => existsSync(join(root, file))), options);
  if (!base) return { current, reported: current };

  const mergeBase = git(root, ['merge-base', base, 'HEAD']).trim();
  const baseRoot = realpathSync(mkdtempSync(join(tmpdir(), 'orchard-osv-base-')));
  try {
    const baseFiles = lockfiles(git(root, ['ls-tree', '-r', '-z', '--name-only', mergeBase]).split('\0'));
    for (const file of baseFiles) {
      mkdirSync(dirname(join(baseRoot, file)), { recursive: true });
      writeFileSync(join(baseRoot, file), git(root, ['show', `${mergeBase}:${file}`], 'buffer'));
    }
    const baseline = scan(baseRoot, baseFiles, options);
    return { mergeBase, baseline, current, reported: introduced(baseline, current) };
  } finally {
    rmSync(baseRoot, { recursive: true, force: true });
  }
}

function describe(finding) {
  const severity = finding.severity ? ` CVSS ${finding.severity}` : '';
  return `  ${finding.lockfile}: ${finding.ecosystem} ${finding.name}@${finding.version} ${finding.id}${severity} https://osv.dev/${finding.id}`;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const outcome = run(process.argv.slice(2));
    if (outcome.mergeBase) {
      console.log(`OSV comparison against merge base ${outcome.mergeBase}: ` +
        `${outcome.baseline.length} known at the merge base, ${outcome.reported.length} introduced.`);
    } else {
      console.log(`OSV full scan: ${outcome.reported.length} known vulnerabilities.`);
    }
    for (const finding of outcome.reported) console.log(describe(finding));
    if (outcome.reported.length) process.exitCode = 1;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 2;
  }
}

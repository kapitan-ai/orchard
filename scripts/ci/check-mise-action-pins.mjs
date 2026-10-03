import { readFileSync, readdirSync, realpathSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseDocument } from 'yaml';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

export function checkPins(root = repoRoot) {
  const policy = JSON.parse(readFileSync(join(root, '.github/mise-action-pin.json'), 'utf8'));
  if (!/^[a-f0-9]{40}$/.test(policy.sha) ||
      !/^[\w-]+\.ya?ml$/.test(policy.requiredWorkflow) ||
      !Array.isArray(policy.requiredJobs) || !policy.requiredJobs.length ||
      policy.requiredJobs.some(job => typeof job !== 'string' || !/^[\w-]+$/.test(job)) ||
      new Set(policy.requiredJobs).size !== policy.requiredJobs.length) {
    throw new Error('Invalid approved mise-action pin record');
  }

  const workflowDir = join(root, '.github/workflows');
  const files = readdirSync(workflowDir).filter(file => /\.ya?ml$/.test(file)).sort();
  const errors = [];
  const requiredCounts = new Map(policy.requiredJobs.map(job => [job, 0]));
  let count = 0;
  for (const file of files) {
    const document = parseDocument(readFileSync(join(workflowDir, file), 'utf8'), { uniqueKeys: true });
    if (document.errors.length) throw new Error(`Invalid workflow YAML: ${file}`);
    const workflow = document.toJS({ maxAliasCount: 100 });
    if (!workflow || typeof workflow.jobs !== 'object' || !workflow.jobs || Array.isArray(workflow.jobs)) {
      throw new Error(`Missing workflow jobs: ${file}`);
    }
    for (const [jobName, job] of Object.entries(workflow.jobs)) {
      // Only action invocations are inspected; comments, run strings and env
      // values mentioning mise-action have no bearing on the approved pin.
      for (const step of job?.steps ?? []) {
        if (typeof step?.uses !== 'string') continue;
        const uses = step.uses.trim();
        if (!/^jdx\/mise-action(?:@|\/|$)/i.test(uses)) continue;
        count++;
        if (file === policy.requiredWorkflow && requiredCounts.has(jobName)) {
          requiredCounts.set(jobName, requiredCounts.get(jobName) + 1);
        }
        if (uses !== `jdx/mise-action@${policy.sha}`) {
          errors.push(`${file}: ${jobName}: mise-action must use the approved immutable SHA`);
        }
      }
    }
  }
  for (const [job, invocations] of requiredCounts) {
    if (invocations !== 1) errors.push(`${policy.requiredWorkflow}: ${job}: expected one mise-action invocation`);
  }
  if (errors.length) throw new Error(errors.join('\n'));
  return count;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    console.log(`mise-action pins passed (${checkPins()} invocations)`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

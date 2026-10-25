/** Rules of tools/asset_policy.json shared by the publication audit and its tests.
 * A rule matches a repository-relative path by prefix (and optional extension list); the first
 * matching rule wins, so a narrower prefix must come before a broader one.
 */
import path from 'node:path';

export function policyRule(rules, p) {
  const ext = path.extname(p).toLowerCase();
  return rules.find(r => p.startsWith(r.prefix) && (!r.extensions || r.extensions.includes(ext)));
}

/** Rules that can never match because an earlier rule in the same list covers them. */
export function shadowedRules(rules) {
  return rules.filter((r, i) => rules.slice(0, i).some(e => r.prefix.startsWith(e.prefix) &&
    (!e.extensions || r.extensions && r.extensions.every(x => e.extensions.includes(x)))));
}

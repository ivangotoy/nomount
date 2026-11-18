// Checks that every value interpolated into a shell command in module/webroot/index.js is a
// constant, shellQuote()d or shellNum()-checked, and that addExclusion/removeExclusion never
// hand a non-numeric uid to the shell.  usage: node tests/webui_exec.js <index.js>
'use strict';
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
let failures = 0;
const fail = (msg) => { failures++; console.log('FAIL ' + msg); };

// ${} expressions on every line that builds a shell command
function exprs(line) {
    const out = [];
    for (let i = line.indexOf('${'); i >= 0; i = line.indexOf('${', i)) {
        let depth = 1, j = i + 2;
        while (j < line.length && depth) { if (line[j] === '{') depth++; else if (line[j] === '}') depth--; j++; }
        out.push(line.slice(i + 2, j - 1).trim());
        i = j;
    }
    return out;
}

const CONST = /^(NM_BIN|MOD_DIR|NM_DATA|NM_STATE_SEP|FILES\.\w+|filter)$/;
const SAFE = /^(shellQuote|shellNum)\(|\.map\(shellNum\)\.join\(' '\)$/;
let shellLiterals = 0;
src.split('\n').forEach((line, n) => {
    if (!/exec\(|\$\{(NM_BIN|MOD_DIR|NM_DATA|FILES\.)/.test(line)) return;
    if (/^\s*const (NM_BIN|MOD_DIR|NM_DATA|FILES) =/.test(line)) return;
    if (/^\s*const (modPath|skipFile) = `/.test(line)) return; // paths, shellQuote()d where used
    shellLiterals++;
    for (const e of exprs(line)) {
        if (CONST.test(e) || SAFE.test(e) || /^isChecked \? 'on' : 'off'$/.test(e)) continue;
        fail(`unquoted shell interpolation \${${e}} at line ${n + 1}`);
    }
});
if (shellLiterals < 20) fail(`only ${shellLiterals} shell command literals found`);

// run addExclusion/removeExclusion with stubs
function extract(name) {
    const m = src.match(new RegExp(`(?:async )?function ${name}\\(`));
    if (!m) return null;
    let i = src.indexOf('{', m.index), depth = 0;
    for (; i < src.length; i++) { if (src[i] === '{') depth++; else if (src[i] === '}' && --depth === 0) break; }
    return src.slice(m.index, i + 1);
}
const pick = (re) => { const m = src.match(re); return m ? m[0] : ''; };
const cmds = [];
const code = [pick(/const shellQuote = .*\n/), pick(/const shellNum = .*\n/), extract('addExclusion'), extract('removeExclusion')].join('\n');
const run = new Function('exec', 'readExclusionsJson', 'writeExclusionsJson', 'showToast', 'translate', 'loadExclusions',
    'renderEmptyState', 'document', 'NM_BIN', code + '\nreturn { addExclusion, removeExclusion };');
const api = run(async (c) => { cmds.push(c); return { errno: 0, stdout: '', stderr: '' }; }, async () => [], async () => ({ errno: 0 }),
    () => {}, (k) => k, async () => {}, () => {}, { getElementById: () => ({ children: [] }) }, '/nm');
(async () => {
    const bad = '10123; touch /pwned';
    await api.addExclusion(bad, 'x', 'p');
    await api.removeExclusion(bad, 'x', { remove() {}, style: {} });
    for (const c of cmds) if (c.includes('pwned')) fail(`shell command built from a non-numeric uid: ${c}`);
    cmds.length = 0;
    await api.addExclusion('10123', 'x', 'p');
    if (!cmds.includes('/nm uid add 10123')) fail(`numeric uid not passed through: ${JSON.stringify(cmds)}`);
    process.exit(failures ? 1 : 0);
})().catch((e) => { console.log('FAIL ' + e.stack); process.exit(1); });

// Retain the original entry point; exercise the real page/server with Playwright.
const {execFileSync} = require('node:child_process');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
execFileSync('bash', ['harness/jam/server-build.sh'], {cwd: root, stdio: 'inherit'});
execFileSync(process.env.WEBJAM_PYTHON || 'python3', ['harness/jam/browser-test.py'], {cwd: root, stdio: 'inherit'});

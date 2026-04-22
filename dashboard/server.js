const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const WebSocket = require('ws');

const PORT = process.env.DASHBOARD_PORT || 9999;
const OS = process.platform;
const FALCO_LOG = process.env.FALCO_LOG || '/var/log/falco/falco.json';
const RUNSC_LOG = process.env.RUNSC_LOG || '/var/log/runsc/current.log';

// Comma-separated domains/IPs considered safe (e.g. SANDBOX_ALLOWLIST=registry.npmjs.org,github.com)
const ALLOWLIST = (process.env.SANDBOX_ALLOWLIST || '')
  .split(',')
  .map(s => s.trim().toLowerCase())
  .filter(Boolean);

// Built-in safe destinations always treated as allowed
const BUILTIN_ALLOWLIST = [
  'registry.npmjs.org',
  'registry.yarnpkg.com',
  'pypi.org',
  'files.pythonhosted.org',
  'github.com',
  'objects.githubusercontent.com',
  '127.0.0.1',
  '::1',
];

function isAllowlisted(dest) {
  if (!dest || dest === 'TCP connect') return false;
  const d = dest.toLowerCase();
  return [...BUILTIN_ALLOWLIST, ...ALLOWLIST].some(entry => d.includes(entry));
}

// Strip ANSI escape sequences and non-printable control characters, then cap length.
// Applied to every field before broadcast so log-injected content can't reach the UI.
const ANSI_RE = /\x1b\[[0-9;]*[a-zA-Z]/g;
const CTRL_RE = /[\x00-\x08\x0b-\x1f\x7f]/g;

function sanitizeStr(str, maxLen) {
  if (typeof str !== 'string') str = String(str == null ? '' : str);
  return str.replace(ANSI_RE, '').replace(CTRL_RE, '').slice(0, maxLen);
}

function sanitizeAlert(alert) {
  return {
    time:     sanitizeStr(alert.time,     64),
    priority: sanitizeStr(alert.priority, 16),
    rule:     sanitizeStr(alert.rule,     128),
    detail:   sanitizeStr(alert.detail,   256),
    source:   sanitizeStr(alert.source,   32),
  };
}

const server = http.createServer((req, res) => {
  if (req.url === '/' || req.url === '/index.html') {
    const filePath = path.join(__dirname, 'index.html');
    fs.readFile(filePath, (err, data) => {
      if (err) {
        res.writeHead(500);
        res.end('Error loading dashboard');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(data);
    });
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});

const wss = new WebSocket.Server({ server });

// Noise suppression: high-volume INFO events from these path prefixes are
// allowed through SUPPRESS_THRESHOLD times per window, then collapsed into
// a single summary broadcast at the end of each window.
const NOISY_PREFIXES = ['/app/node_modules/', '/tmp/', '/app/.sandbox-'];
const SUPPRESS_THRESHOLD = 5;
const SUPPRESS_WINDOW_MS = 10000;
const _suppressCounts = new Map();

setInterval(() => {
  let total = 0;
  _suppressCounts.forEach(v => { total += v; });
  if (total > 0) {
    broadcast({
      time: new Date().toISOString(),
      priority: 'INFO',
      rule: 'Noise suppressed',
      detail: `${total} repetitive file-read events hidden (node_modules / tmp)`,
      source: 'system',
    });
  }
  _suppressCounts.clear();
}, SUPPRESS_WINDOW_MS);

function shouldSuppress(alert) {
  if (alert.priority !== 'INFO') return false;
  const detail = alert.detail || '';
  const prefix = NOISY_PREFIXES.find(p => detail.startsWith(p));
  if (!prefix) return false;
  const count = (_suppressCounts.get(prefix) || 0) + 1;
  _suppressCounts.set(prefix, count);
  return count > SUPPRESS_THRESHOLD;
}

function broadcast(data) {
  if (shouldSuppress(data)) return;
  const safe = sanitizeAlert(data);
  wss.clients.forEach(client => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify(safe));
    }
  });
}

const SENSITIVE_WRITE_PATHS = /\/(\.ssh|\.aws|etc|root|proc)\//;
const SENSITIVE_READ_PATHS  = /\/etc\/passwd|\/etc\/shadow|id_rsa|\.aws|\.ssh/;
// openat flags: O_WRONLY=0x1, O_RDWR=0x2, O_CREAT=0x40, O_TRUNC=0x200
const WRITE_FLAGS = /O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|0x[0-9a-f]*[1-9a-f][0-9a-f]* /i;

const ENVIRON_PATHS = /\/proc\/(self|\d+)\/environ/;
const ENV_FILE_PATHS = /\/\.env(\.|$)|secrets\.(json|ya?ml)|credentials\.(json|ya?ml)|\.netrc|(\/|^)(config\/secrets|config\/credentials)/i;
const SENSITIVE_VAR_PATTERN = /(key|secret|token|password)/i;

function extractPath(line) {
  const m = line.match(/openat[^"]*"([^"]+)"/);
  return m ? m[1] : null;
}

function isWriteAccess(line) {
  return WRITE_FLAGS.test(line);
}

function extractNetworkDest(line) {
  // Try to extract IP:port from connect syscall — format varies by gVisor version
  const ipPort = line.match(/(\d{1,3}(?:\.\d{1,3}){3}):(\d+)/);
  if (ipPort) return `${ipPort[1]}:${ipPort[2]}`;
  const ipOnly = line.match(/(\d{1,3}(?:\.\d{1,3}){3})/);
  if (ipOnly) return ipOnly[1];
  // sin_addr / sa_data hex patterns from strace
  const sinAddr = line.match(/sin_addr=\{s_addr=([^}]+)\}/);
  if (sinAddr) return sinAddr[1];
  return 'TCP connect';
}

function extractExecveArgs(line) {
  // execve("/path/to/bin", ["arg0", "arg1", ...], ...)
  const argsMatch = line.match(/execve\("([^"]+)",\s*\[([^\]]*)\]/);
  if (argsMatch) {
    const bin = argsMatch[1];
    const args = argsMatch[2].replace(/"/g, '').replace(/,\s*/g, ' ').trim();
    return args || bin;
  }
  const binMatch = line.match(/execve\("([^"]+)"/);
  return binMatch ? binMatch[1] : 'unknown process';
}

function parseRunscLine(line) {
  const ts = new Date().toISOString();

  // Shell spawn — check before generic execve
  if (/execve.*"(sh|bash|zsh|ash)"/.test(line)) {
    const detail = extractExecveArgs(line);
    return { time: ts, priority: 'CRITICAL', rule: 'Shell spawned in container', detail, source: 'gvisor' };
  }

  // Full execve audit — all process spawns with args
  if (/execve/.test(line)) {
    const detail = extractExecveArgs(line);
    return { time: ts, priority: 'INFO', rule: 'Process exec', detail, source: 'gvisor' };
  }

  // Outbound network with IP:port extraction and allowlist check
  if (/connect.*SOCK_STREAM/.test(line)) {
    const detail = extractNetworkDest(line);
    if (isAllowlisted(detail)) {
      return { time: ts, priority: 'INFO', rule: 'Outbound connection', detail: `✓ ${detail}`, source: 'gvisor' };
    }
    return { time: ts, priority: 'WARNING', rule: 'Outbound connection attempt', detail, source: 'gvisor' };
  }

  // File access
  if (/openat/.test(line)) {
    const path = extractPath(line) || 'unknown path';
    const write = isWriteAccess(line);

    // Env var exfiltration via /proc/self/environ or /proc/<pid>/environ
    if (ENVIRON_PATHS.test(path)) {
      return { time: ts, priority: 'CRITICAL', rule: 'Env var exfiltration', detail: path, source: 'gvisor' };
    }

    // Sensitive env/secret file access (.env, secrets.json, credentials, .netrc, etc.)
    if (ENV_FILE_PATHS.test(path)) {
      return { time: ts, priority: 'CRITICAL', rule: 'Env file access', detail: path, source: 'gvisor' };
    }

    if (write) {
      if (SENSITIVE_WRITE_PATHS.test(path)) {
        return { time: ts, priority: 'CRITICAL', rule: 'Sensitive file write', detail: path, source: 'gvisor' };
      }
      return { time: ts, priority: 'WARNING', rule: 'File write', detail: path, source: 'gvisor' };
    }

    if (SENSITIVE_READ_PATHS.test(path)) {
      return { time: ts, priority: 'CRITICAL', rule: 'Credential read attempt', detail: path, source: 'gvisor' };
    }

    // Path contains sensitive variable name patterns (KEY, SECRET, TOKEN, PASSWORD)
    if (SENSITIVE_VAR_PATTERN.test(path)) {
      return { time: ts, priority: 'WARNING', rule: 'Sensitive path access', detail: path, source: 'gvisor' };
    }

    return { time: ts, priority: 'INFO', rule: 'File read', detail: path, source: 'gvisor' };
  }

  return null;
}

function parseFalcoLine(line) {
  try {
    const event = JSON.parse(line);
    const priority = (event.priority || 'info').toUpperCase();
    return {
      time: event.time || new Date().toISOString(),
      priority: priority,
      rule: event.rule || 'Unknown rule',
      detail: event.output || '',
      source: 'falco'
    };
  } catch (e) {
    return null;
  }
}

function startLinuxWatcher() {
  console.log('[dashboard] Linux mode — tailing Falco log:', FALCO_LOG);

  const ensureLog = spawn('bash', ['-c', `touch ${FALCO_LOG} && tail -F ${FALCO_LOG}`]);

  ensureLog.stdout.on('data', data => {
    data.toString().split('\n').filter(Boolean).forEach(line => {
      const alert = parseFalcoLine(line);
      if (alert) broadcast(alert);
    });
  });

  ensureLog.on('close', () => {
    console.log('[dashboard] Falco watcher closed, restarting in 3s...');
    setTimeout(startLinuxWatcher, 3000);
  });

  // Also tail gVisor logs for syscall detail
  const runscWatcher = spawn('bash', ['-c', `touch ${RUNSC_LOG} && tail -F ${RUNSC_LOG}`]);
  runscWatcher.stdout.on('data', data => {
    data.toString().split('\n').filter(Boolean).forEach(line => {
      const alert = parseRunscLine(line);
      if (alert && alert.priority !== 'INFO') broadcast(alert);
    });
  });
}

function startMacOSWatcher() {
  console.log('[dashboard] macOS mode — tailing gVisor log:', RUNSC_LOG);

  const watcher = spawn('bash', ['-c',
    `limactl shell podman -- sudo bash -c "touch ${RUNSC_LOG} && tail -F ${RUNSC_LOG}"`
  ]);

  watcher.stdout.on('data', data => {
    data.toString().split('\n').filter(Boolean).forEach(line => {
      const alert = parseRunscLine(line);
      if (alert) broadcast(alert);
    });
  });

  watcher.on('close', () => {
    console.log('[dashboard] gVisor watcher closed, restarting in 3s...');
    setTimeout(startMacOSWatcher, 3000);
  });
}

function startPodmanEventsWatcher() {
  const cmd = OS === 'darwin'
    ? 'limactl shell podman -- sudo podman events --format json'
    : 'podman events --format json';

  console.log('[dashboard] Podman events watcher starting...');

  const watcher = spawn('bash', ['-c', cmd]);

  watcher.stdout.on('data', data => {
    data.toString().split('\n').filter(Boolean).forEach(line => {
      try {
        const ev = JSON.parse(line);
        const action = ev.Action || ev.action || '';
        const name = (ev.Actor && ev.Actor.Attributes && ev.Actor.Attributes.name)
          || ev.actor || ev.Name || 'unknown';
        const ts = new Date().toISOString();

        let priority = 'INFO';
        if (['die', 'kill', 'oom'].includes(action)) priority = 'WARNING';
        if (action === 'exec') priority = 'CRITICAL';

        broadcast({ time: ts, priority, rule: `Container ${action}`, detail: name, source: 'podman' });
      } catch (e) {
        // non-JSON line from podman events, skip
      }
    });
  });

  watcher.on('close', () => {
    console.log('[dashboard] Podman events watcher closed, restarting in 3s...');
    setTimeout(startPodmanEventsWatcher, 3000);
  });
}

wss.on('connection', ws => {
  console.log('[dashboard] Client connected');
  ws.send(JSON.stringify({
    time: new Date().toISOString(),
    priority: 'INFO',
    rule: 'Dashboard connected',
    detail: `Watching ${OS === 'darwin' ? 'gVisor strace logs (macOS)' : 'Falco + gVisor logs (Linux)'}`,
    source: 'system'
  }));
});

server.listen(PORT, () => {
  console.log(`[dashboard] Security dashboard running at http://localhost:${PORT}`);
  console.log(`[dashboard] WebSocket ready at ws://localhost:${PORT}`);

  if (OS === 'darwin') {
    startMacOSWatcher();
  } else {
    startLinuxWatcher();
  }
  startPodmanEventsWatcher();
});

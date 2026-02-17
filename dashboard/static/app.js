// =========================================================================
// State
// =========================================================================
let lossChart = null;
let prevData = null;
let clusterFramework = '';
const FW_LABELS = { pytorch: 'PyTorch', tensorflow: 'TensorFlow', sklearn: 'scikit-learn' };
let sseSource = null;
let trainingActive = false;
let logAutoScroll = true;
let statusPollTimer = null;

// =========================================================================
// Toast Notifications
// =========================================================================
function showToast(message, type = 'success') {
  const container = document.getElementById('toast-container');
  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  toast.textContent = message;
  container.appendChild(toast);
  setTimeout(() => {
    toast.style.animation = 'toastOut 0.3s ease-in forwards';
    toast.addEventListener('animationend', () => toast.remove());
  }, 5000);
}

// =========================================================================
// Topology Renderer (animated SVG)
// =========================================================================
function renderTopology(nodes, connectedCount, runStatus) {
  const svg = document.getElementById('topology-canvas');
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  const nodeFill = isDark ? '#1e2738' : 'white';
  const textPrimary = isDark ? '#ffffff' : '#1b2332';
  const textSecondary = isDark ? '#d1d5db' : '#576171';
  const textTertiary = isDark ? '#9ca3af' : '#8e96a4';
  const accent = isDark ? '#38b6ff' : '#2ea3f2';
  const green = isDark ? '#34d399' : '#27ae60';
  const borderIdle = isDark ? '#2d3a4e' : '#dde1e8';

  if (!nodes || nodes.length === 0) {
    svg.innerHTML = `<text x="400" y="160" text-anchor="middle" fill="${textTertiary}" font-size="14" font-family="Inter,sans-serif">No nodes detected</text>`;
    return;
  }

  const coordinator = nodes.find(n => n.role === 'superlink');
  const workers = nodes.filter(n => n.role === 'supernode');
  const isTraining = runStatus === 'running';
  const isComplete = runStatus === 'completed';

  // Layout: coordinator centered top, workers spread bottom
  const cx = 400, cy = 90;
  const workerY = 240;
  const workerSpacing = Math.min(200, 600 / Math.max(workers.length, 1));
  const workerStartX = cx - ((workers.length - 1) * workerSpacing) / 2;

  let html = '';

  // Defs for gradients and filters
  html += `
    <defs>
      <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
        <feDropShadow dx="0" dy="2" stdDeviation="6" flood-color="${isDark ? 'rgba(0,0,0,0.4)' : 'rgba(0,0,0,0.08)'}"/>
      </filter>
      <linearGradient id="line-active" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0%" stop-color="${accent}" stop-opacity="0.1"/>
        <stop offset="50%" stop-color="${accent}" stop-opacity="0.6"/>
        <stop offset="100%" stop-color="${accent}" stop-opacity="0.1"/>
      </linearGradient>
      <linearGradient id="line-idle" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0%" stop-color="${borderIdle}"/>
        <stop offset="100%" stop-color="${borderIdle}"/>
      </linearGradient>
    </defs>`;

  // Connection lines from each worker to coordinator
  workers.forEach((w, i) => {
    const wx = workerStartX + i * workerSpacing;
    const isConnected = w.container_status === 'running';
    const lineColor = isConnected ? (isTraining ? 'url(#line-active)' : accent) : borderIdle;
    const lineWidth = isConnected ? 2 : 1;
    const dashArray = isTraining && isConnected ? '6 4' : 'none';
    const animClass = isTraining && isConnected ? 'flow-in' : '';

    // Curved path
    const midY = (cy + 30 + workerY - 30) / 2;
    html += `<path d="M${cx},${cy + 30} Q${(cx + wx) / 2},${midY} ${wx},${workerY - 30}"
      fill="none" stroke="${lineColor}" stroke-width="${lineWidth}"
      stroke-dasharray="${dashArray}" class="${animClass}" opacity="${isConnected ? 1 : 0.4}"/>`;

    // Data flow particles (small circles moving along the line during training)
    if (isTraining && isConnected) {
      html += `
        <circle r="3" fill="${accent}" opacity="0.8">
          <animateMotion dur="2s" repeatCount="indefinite" path="M${cx},${cy + 30} Q${(cx + wx) / 2},${midY} ${wx},${workerY - 30}"/>
        </circle>
        <circle r="3" fill="${green}" opacity="0.8">
          <animateMotion dur="2.5s" repeatCount="indefinite" path="M${wx},${workerY - 30} Q${(cx + wx) / 2},${midY} ${cx},${cy + 30}"/>
        </circle>`;
    }
  });

  // Coordinator node
  if (coordinator) {
    const cRunning = coordinator.container_status === 'running';
    const cRingColor = cRunning ? accent : borderIdle;
    html += `
      <g filter="url(#shadow)" transform="translate(${cx},${cy})">
        <rect x="-70" y="-28" width="140" height="56" rx="14" fill="${nodeFill}" stroke="${cRingColor}" stroke-width="1.5"/>
        <circle cx="-45" cy="0" r="6" fill="${cRunning ? green : borderIdle}"/>
        ${cRunning ? `<circle cx="-45" cy="0" r="6" fill="${green}" class="pulse" opacity="0.5"/>` : ''}
        <text x="-30" y="-6" font-size="13" font-weight="600" fill="${textPrimary}" font-family="Inter,sans-serif">Coordinator</text>
        <text x="-30" y="10" font-size="10" fill="${textSecondary}" font-family="JetBrains Mono,monospace">${coordinator.ip || '\u2014'}</text>
      </g>`;
    html += `<text x="${cx}" y="${cy + 46}" text-anchor="middle" font-size="10" fill="${textTertiary}" font-family="Inter,sans-serif">VM ${coordinator.vm_id} \u00b7 ${coordinator.cpu} vCPU \u00b7 ${(coordinator.memory_mb / 1024).toFixed(0)} GB</text>`;
  }

  // Worker nodes
  const fwColors = { pytorch: '#ee4c2c', tensorflow: '#ff6f00', sklearn: '#f89939' };
  const fwLabels = { pytorch: 'PyTorch', tensorflow: 'TensorFlow', sklearn: 'sklearn' };
  workers.forEach((w, i) => {
    const wx = workerStartX + i * workerSpacing;
    const wRunning = w.container_status === 'running';
    const wRingColor = wRunning ? accent : borderIdle;
    html += `
      <g filter="url(#shadow)" transform="translate(${wx},${workerY})">
        <rect x="-65" y="-25" width="130" height="50" rx="12" fill="${nodeFill}" stroke="${wRingColor}" stroke-width="1.5"/>
        <circle cx="-42" cy="0" r="5" fill="${wRunning ? green : borderIdle}"/>
        ${wRunning ? `<circle cx="-42" cy="0" r="5" fill="${green}" class="pulse" opacity="0.5"/>` : ''}
        <text x="-28" y="-5" font-size="12" font-weight="500" fill="${textPrimary}" font-family="Inter,sans-serif">Worker ${i + 1}</text>
        <text x="-28" y="9" font-size="10" fill="${textSecondary}" font-family="JetBrains Mono,monospace">${w.ip || '\u2014'}</text>
      </g>`;
    // Framework badge below node
    const fw = w.framework || '';
    const fwColor = fwColors[fw] || textTertiary;
    const fwLabel = fwLabels[fw] || '';
    const vmInfo = `VM ${w.vm_id} \u00b7 ${w.cpu} vCPU \u00b7 ${(w.memory_mb / 1024).toFixed(0)} GB`;
    html += `<text x="${wx}" y="${workerY + 42}" text-anchor="middle" font-size="10" fill="${textTertiary}" font-family="Inter,sans-serif">${vmInfo}</text>`;
    if (fwLabel) {
      html += `<text x="${wx}" y="${workerY + 56}" text-anchor="middle" font-size="10" font-weight="600" fill="${fwColor}" font-family="Inter,sans-serif">${fwLabel}</text>`;
    }
  });

  // Legend
  if (isTraining) {
    html += `
      <g transform="translate(20,300)">
        <circle r="3" cx="5" cy="0" fill="${accent}" opacity="0.8"/><text x="14" y="4" font-size="9" fill="${textSecondary}" font-family="Inter,sans-serif">Global weights</text>
        <circle r="3" cx="105" cy="0" fill="${green}" opacity="0.8"/><text x="114" y="4" font-size="9" fill="${textSecondary}" font-family="Inter,sans-serif">Local gradients</text>
      </g>`;
  }

  svg.innerHTML = html;
}

// =========================================================================
// Chart
// =========================================================================
function renderLossChart(rounds) {
  const ctx = document.getElementById('loss-chart').getContext('2d');
  const labels = rounds.map(r => `Round ${r.round_num}`);
  const lossData = rounds.map(r => r.loss);
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  const accent = isDark ? '#38b6ff' : '#2ea3f2';
  const gridColor = isDark ? '#283346' : '#e8ecf1';
  const tickColor = isDark ? '#9ca3af' : '#8e96a4';
  const tooltipBg = isDark ? '#1e2738' : '#fff';
  const tooltipTitle = isDark ? '#ffffff' : '#1b2332';
  const tooltipBody = isDark ? '#d1d5db' : '#576171';
  const tooltipBorder = isDark ? '#2d3a4e' : '#dde1e8';
  const pointBg = isDark ? '#1e2738' : '#fff';

  if (lossChart) {
    lossChart.data.labels = labels;
    lossChart.data.datasets[0].data = lossData;
    lossChart.update('none');
    return;
  }

  lossChart = new Chart(ctx, {
    type: 'line',
    data: {
      labels,
      datasets: [{
        label: 'Loss',
        data: lossData,
        borderColor: accent,
        backgroundColor: isDark ? 'rgba(56, 182, 255, 0.1)' : 'rgba(46, 163, 242, 0.06)',
        borderWidth: 2,
        pointBackgroundColor: pointBg,
        pointBorderColor: accent,
        pointBorderWidth: 2,
        pointRadius: 4,
        pointHoverRadius: 6,
        fill: true,
        tension: 0.35,
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          backgroundColor: tooltipBg,
          titleColor: tooltipTitle,
          bodyColor: tooltipBody,
          borderColor: tooltipBorder,
          borderWidth: 1,
          cornerRadius: 8,
          padding: 10,
          titleFont: { family: 'Inter', weight: '600', size: 12 },
          bodyFont: { family: 'JetBrains Mono', size: 11 },
          callbacks: { label: ctx => `Loss: ${ctx.parsed.y?.toFixed(4) ?? 'N/A'}` }
        }
      },
      scales: {
        x: {
          grid: { color: gridColor },
          ticks: { color: tickColor, font: { family: 'Inter', size: 11 } },
          border: { display: false },
        },
        y: {
          grid: { color: gridColor },
          ticks: { color: tickColor, font: { family: 'JetBrains Mono', size: 11 } },
          border: { display: false },
          title: { display: true, text: 'Loss', color: tickColor, font: { family: 'Inter', size: 11, weight: '500' } },
        }
      }
    }
  });
}

// =========================================================================
// Rounds Table
// =========================================================================
function renderRoundsTable(rounds) {
  const el = document.getElementById('rounds-table');
  if (!rounds || rounds.length === 0) {
    el.innerHTML = `<div class="px-6 py-10 text-center text-sm text-[var(--text-tertiary)]">Waiting for training data</div>`;
    return;
  }
  el.innerHTML = `
    <table class="w-full text-sm">
      <thead><tr class="border-b border-[var(--border)]">
        <th class="text-left px-5 py-3 text-[11px] font-medium text-[var(--text-tertiary)] uppercase tracking-wider">Round</th>
        <th class="text-right px-5 py-3 text-[11px] font-medium text-[var(--text-tertiary)] uppercase tracking-wider">Loss</th>
        <th class="text-right px-5 py-3 text-[11px] font-medium text-[var(--text-tertiary)] uppercase tracking-wider">Clients</th>
        <th class="text-right px-5 py-3 text-[11px] font-medium text-[var(--text-tertiary)] uppercase tracking-wider">Eval</th>
      </tr></thead>
      <tbody>
        ${rounds.map(r => `
          <tr class="border-b border-[var(--border)] last:border-0">
            <td class="px-5 py-3 mono font-medium text-[var(--accent)]">${r.round_num}</td>
            <td class="px-5 py-3 text-right mono">${r.loss !== null ? r.loss.toFixed(4) : '--'}</td>
            <td class="px-5 py-3 text-right">
              <span class="text-[var(--green)]">${r.fit_clients}</span>${r.fit_failures > 0 ? `<span class="text-[var(--red)]"> / ${r.fit_failures}</span>` : ''}
            </td>
            <td class="px-5 py-3 text-right">
              <span class="text-[var(--green)]">${r.eval_clients}</span>${r.eval_failures > 0 ? `<span class="text-[var(--red)]"> / ${r.eval_failures}</span>` : ''}
            </td>
          </tr>`).join('')}
      </tbody>
    </table>`;
}

// =========================================================================
// Run Info
// =========================================================================
function renderRunInfo(run) {
  const el = document.getElementById('run-info');
  if (!run.run_id) {
    el.innerHTML = `<div class="text-sm text-[var(--text-tertiary)]">No active run</div>`;
    return;
  }

  const statusColor = { idle: 'var(--text-tertiary)', running: 'var(--orange)', completed: 'var(--green)', failed: 'var(--red)' };
  const sc = statusColor[run.status] || statusColor.idle;
  const pct = run.num_rounds_configured > 0 ? Math.round((run.num_rounds_completed / run.num_rounds_configured) * 100) : 0;

  el.innerHTML = `
    <div class="grid grid-cols-2 gap-6">
      <div>
        <p class="text-[11px] text-[var(--text-tertiary)] uppercase tracking-wider mb-1">Run ID</p>
        <p class="mono text-sm truncate">${run.run_id}</p>
      </div>
      <div>
        <p class="text-[11px] text-[var(--text-tertiary)] uppercase tracking-wider mb-1">Status</p>
        <p class="text-sm font-semibold" style="color:${sc}">${(run.status || 'idle').toUpperCase()}</p>
      </div>
      <div>
        <p class="text-[11px] text-[var(--text-tertiary)] uppercase tracking-wider mb-1">Progress</p>
        <div class="flex items-center gap-3">
          <div class="flex-1 h-1.5 rounded-full bg-[#f2f2f7] overflow-hidden">
            <div class="h-full rounded-full bg-[var(--accent)] transition-all duration-700" style="width:${pct}%"></div>
          </div>
          <span class="text-xs mono text-[var(--text-secondary)]">${run.num_rounds_completed}/${run.num_rounds_configured}</span>
        </div>
      </div>
      <div>
        <p class="text-[11px] text-[var(--text-tertiary)] uppercase tracking-wider mb-1">Duration</p>
        <p class="text-sm mono">${run.total_duration_s > 0 ? `${(run.total_duration_s / 60).toFixed(1)} min` : '--'}</p>
      </div>
    </div>`;
}

// =========================================================================
// Model Panel
// =========================================================================
function renderModelPanel(model) {
  const el = document.getElementById('model-panel');
  if (!model || Object.keys(model).length === 0) {
    el.innerHTML = `<div class="text-sm text-[var(--text-tertiary)]">No model info</div>`;
    return;
  }

  const rows = [
    ['Architecture', model.architecture],
    ['Parameters', model.parameters],
    ['Framework', model.framework],
    ['Dataset', model.dataset],
    ['Strategy', model.strategy],
    ['Weight Size', model.weight_size_bytes],
  ].filter(r => r[1]);

  el.innerHTML = `<div class="space-y-3">
    ${rows.map(([k, v]) => `
      <div class="flex justify-between items-baseline">
        <span class="text-xs text-[var(--text-tertiary)]">${k}</span>
        <span class="text-sm font-medium text-right max-w-[60%] truncate">${v}</span>
      </div>`).join('')}
  </div>`;
}

// =========================================================================
// Main refresh
// =========================================================================
async function refresh() {
  try {
    const res = await fetch('/api/cluster');
    const data = await res.json();
    prevData = data;

    // KPIs
    document.getElementById('kpi-nodes').textContent = data.nodes?.length || 0;
    document.getElementById('kpi-connected').textContent = data.connected_supernodes || 0;

    const run = data.current_run || {};
    const statusEl = document.getElementById('kpi-status');
    const st = run.status || 'idle';
    statusEl.textContent = st.charAt(0).toUpperCase() + st.slice(1);
    statusEl.style.color = { completed: 'var(--green)', running: 'var(--orange)', failed: 'var(--red)' }[st] || 'var(--text-primary)';

    document.getElementById('kpi-round').textContent = run.num_rounds_completed > 0
      ? `${run.num_rounds_completed}/${run.num_rounds_configured || '?'}`
      : '--';

    // Nav status
    const running = data.nodes?.filter(n => n.container_status === 'running').length || 0;
    const total = data.nodes?.length || 0;
    const csEl = document.getElementById('cluster-status');
    csEl.innerHTML = `
      <span class="w-1.5 h-1.5 rounded-full ${running === total && total > 0 ? 'bg-[var(--green)] pulse' : running > 0 ? 'bg-[var(--orange)]' : 'bg-[var(--text-tertiary)]'}"></span>
      <span>${running}/${total} online</span>`;

    document.getElementById('last-updated').textContent = new Date().toLocaleTimeString();

    // Panels
    renderTopology(data.nodes, data.connected_supernodes, run.status);
    renderLossChart(run.rounds || []);
    renderRoundsTable(run.rounds || []);
    renderRunInfo(run);
    renderModelPanel(run.model_info);

  } catch (err) {
    document.getElementById('cluster-status').innerHTML = `
      <span class="w-1.5 h-1.5 rounded-full bg-[var(--red)]"></span>
      <span class="text-[var(--red)]">Offline</span>`;
  }
}

// =========================================================================
// Dark mode toggle
// =========================================================================
function initTheme() {
  const saved = localStorage.getItem('fl-theme');
  if (saved === 'dark' || (!saved && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
    document.documentElement.setAttribute('data-theme', 'dark');
  }
}

function toggleTheme() {
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  const next = isDark ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', next === 'dark' ? 'dark' : '');
  if (next === 'light') document.documentElement.removeAttribute('data-theme');
  localStorage.setItem('fl-theme', next);

  // Recreate chart with new theme colors
  if (lossChart) {
    lossChart.destroy();
    lossChart = null;
  }
  if (prevData) {
    const run = prevData.current_run || {};
    renderLossChart(run.rounds || []);
    renderTopology(prevData.nodes, prevData.connected_supernodes, run.status);
  }
}

// =========================================================================
// Refresh Button
// =========================================================================
function handleRefreshClick() {
  const btn = document.getElementById('refresh-btn');
  const svg = btn.querySelector('svg');
  svg.classList.add('spinning');
  svg.addEventListener('animationend', () => svg.classList.remove('spinning'), { once: true });
  refresh();
}

// =========================================================================
// Control Panel: Frameworks
// =========================================================================
async function loadFrameworks() {
  try {
    const res = await fetch('/api/frameworks');
    const data = await res.json();

    clusterFramework = data.cluster_framework || '';

    // Populate framework dropdown
    const fwSelect = document.getElementById('cp-framework');
    fwSelect.innerHTML = data.frameworks.map(fw =>
      `<option value="${fw}"${fw === clusterFramework ? ' selected' : ''}>${FW_LABELS[fw] || fw}</option>`
    ).join('');

    // Populate strategy dropdown
    const stSelect = document.getElementById('cp-strategy');
    stSelect.innerHTML = data.strategies.map(st =>
      `<option value="${st}">${st}</option>`
    ).join('');

    // Fill defaults
    const d = data.defaults || {};
    if (d['num-server-rounds']) document.getElementById('cp-rounds').value = d['num-server-rounds'];
    if (d['local-epochs']) document.getElementById('cp-epochs').value = d['local-epochs'];
    if (d['batch-size']) document.getElementById('cp-batch').value = d['batch-size'];
    if (d['min-fit-clients']) document.getElementById('cp-min-clients').value = d['min-fit-clients'];

  } catch (err) {
    console.error('loadFrameworks failed:', err);
    document.getElementById('cp-framework').innerHTML =
      '<option value="pytorch">PyTorch</option><option value="tensorflow">TensorFlow</option><option value="sklearn">scikit-learn</option>';
  }
}

function handleStrategyChange() {
  const strategy = document.getElementById('cp-strategy').value;
  document.getElementById('cp-fedprox-params').classList.toggle('hidden', strategy !== 'FedProx');
  document.getElementById('cp-fedadam-params').classList.toggle('hidden', strategy !== 'FedAdam');
}

// =========================================================================
// Control Panel: Training Start / Stop
// =========================================================================
async function startTraining() {
  const framework = document.getElementById('cp-framework').value;
  if (!framework) {
    showToast('Select a framework first', 'error');
    return;
  }

  const strategy = document.getElementById('cp-strategy').value;
  const extra_config = {};
  if (strategy === 'FedProx') {
    extra_config['proximal-mu'] = parseFloat(document.getElementById('cp-proximal-mu').value) || 1.0;
  } else if (strategy === 'FedAdam') {
    extra_config['server-lr'] = parseFloat(document.getElementById('cp-server-lr').value) || 0.01;
    extra_config['tau'] = parseFloat(document.getElementById('cp-tau').value) || 0.1;
  }

  const body = {
    framework,
    num_rounds: parseInt(document.getElementById('cp-rounds').value) || 3,
    strategy,
    local_epochs: parseInt(document.getElementById('cp-epochs').value) || 1,
    batch_size: parseInt(document.getElementById('cp-batch').value) || 32,
    min_fit_clients: parseInt(document.getElementById('cp-min-clients').value) || 2,
    min_available_clients: parseInt(document.getElementById('cp-min-clients').value) || 2,
    extra_config,
  };

  const startBtn = document.getElementById('cp-start-btn');
  const needsSwitch = clusterFramework && clusterFramework !== framework;

  // Show loading state on button
  const origText = startBtn.textContent;
  startBtn.disabled = true;
  startBtn.style.opacity = '0.5';
  startBtn.style.cursor = 'not-allowed';

  if (needsSwitch) {
    startBtn.textContent = 'Switching...';
    showToast(`Switching SuperNodes to ${FW_LABELS[framework] || framework}...`);
  } else {
    startBtn.textContent = 'Starting...';
  }

  try {
    const res = await fetch('/api/training/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });

    if (res.status === 409) {
      showToast('Training is already running', 'error');
      startBtn.textContent = origText;
      startBtn.disabled = false;
      startBtn.style.opacity = '1';
      startBtn.style.cursor = 'pointer';
      return;
    }
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      showToast(err.detail || 'Failed to start training', 'error');
      startBtn.textContent = origText;
      startBtn.disabled = false;
      startBtn.style.opacity = '1';
      startBtn.style.cursor = 'pointer';
      return;
    }

    const result = await res.json();
    if (result.switched) {
      clusterFramework = framework;
    }

    showToast('Training started');
    startBtn.textContent = origText;
    setTrainingActive(true);
    connectSSE();
    startStatusPolling();
  } catch (err) {
    showToast('Connection error: ' + err.message, 'error');
    startBtn.textContent = origText;
    startBtn.disabled = false;
    startBtn.style.opacity = '1';
    startBtn.style.cursor = 'pointer';
  }
}

async function stopTraining() {
  try {
    const res = await fetch('/api/training/stop', { method: 'POST' });
    if (res.ok) {
      showToast('Training stopped');
      setTrainingActive(false);
      disconnectSSE();
      stopStatusPolling();
    } else {
      const err = await res.json().catch(() => ({}));
      showToast(err.detail || 'Failed to stop training', 'error');
    }
  } catch (err) {
    showToast('Connection error: ' + err.message, 'error');
  }
}

async function newTraining() {
  // Tell backend to suppress stale log data
  try {
    await fetch('/api/training/reset', { method: 'POST' });
  } catch { /* best-effort */ }

  // Clear log
  const log = document.getElementById('cp-log');
  log.textContent = 'Waiting for training to start...';

  // Reset KPI bar to idle
  document.getElementById('kpi-status').textContent = 'Idle';
  document.getElementById('kpi-status').style.color = 'var(--text-primary)';
  document.getElementById('kpi-round').textContent = '--';

  // Clear data panels
  if (lossChart) { lossChart.destroy(); lossChart = null; }
  document.getElementById('loss-chart').getContext('2d').clearRect(0, 0, 9999, 9999);
  renderRoundsTable([]);
  renderRunInfo({});
  renderModelPanel({});

  // Re-enable form and hide New Training button
  const startBtn = document.getElementById('cp-start-btn');
  startBtn.disabled = false;
  startBtn.style.opacity = '1';
  startBtn.style.cursor = 'pointer';
  document.getElementById('cp-stop-btn').classList.add('hidden');

  trainingActive = false;
}

function setTrainingActive(active) {
  trainingActive = active;
  const startBtn = document.getElementById('cp-start-btn');
  const stopBtn = document.getElementById('cp-stop-btn');
  if (active) {
    startBtn.disabled = true;
    startBtn.style.opacity = '0.5';
    startBtn.style.cursor = 'not-allowed';
    stopBtn.classList.remove('hidden');
  } else {
    startBtn.disabled = false;
    startBtn.style.opacity = '1';
    startBtn.style.cursor = 'pointer';
    stopBtn.classList.add('hidden');
  }
}

// =========================================================================
// Control Panel: SSE Log Viewer
// =========================================================================
function connectSSE() {
  disconnectSSE();
  const log = document.getElementById('cp-log');
  log.textContent = '';

  sseSource = new EventSource('/api/training/log');

  sseSource.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      appendLogLine(data.line || '');
    } catch {
      appendLogLine(event.data);
    }
  };

  sseSource.addEventListener('complete', () => {
    appendLogLine('\n--- Training complete ---', 'success');
    disconnectSSE();
    setTrainingActive(false);
    stopStatusPolling();
    refresh();
  });

  sseSource.onerror = () => {
    // SSE reconnects automatically; if training ended, the complete event handles cleanup
  };
}

function disconnectSSE() {
  if (sseSource) {
    sseSource.close();
    sseSource = null;
  }
}

function appendLogLine(text, type = '') {
  const log = document.getElementById('cp-log');
  const line = document.createElement('div');

  if (type === 'error' || /error|exception|traceback/i.test(text)) {
    line.className = 'log-line-error';
  } else if (type === 'success' || /complete|finished|done/i.test(text)) {
    line.className = 'log-line-success';
  }

  line.textContent = text;
  log.appendChild(line);

  // Auto-scroll if user hasn't scrolled up
  if (logAutoScroll) {
    log.scrollTop = log.scrollHeight;
  }
}

function setupLogScroll() {
  const log = document.getElementById('cp-log');
  log.addEventListener('scroll', () => {
    const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 30;
    logAutoScroll = atBottom;
  });
}

function clearLog() {
  document.getElementById('cp-log').textContent = '';
}

// =========================================================================
// Control Panel: Status Polling
// =========================================================================
function startStatusPolling() {
  stopStatusPolling();
  statusPollTimer = setInterval(pollTrainingStatus, 3000);
}

function stopStatusPolling() {
  if (statusPollTimer) {
    clearInterval(statusPollTimer);
    statusPollTimer = null;
  }
}

async function pollTrainingStatus() {
  try {
    const res = await fetch('/api/training/status');
    const data = await res.json();

    if (!data.active) {
      setTrainingActive(false);
      stopStatusPolling();
      disconnectSSE();
      refresh();
    }
  } catch {
    // Ignore transient errors
  }
}

// =========================================================================
// Control Panel: File Upload
// =========================================================================
function setupUpload() {
  const dropZone = document.getElementById('cp-drop-zone');
  const fileInput = document.getElementById('cp-file-input');

  dropZone.addEventListener('click', () => fileInput.click());

  dropZone.addEventListener('dragover', (e) => {
    e.preventDefault();
    dropZone.classList.add('dragover');
  });

  dropZone.addEventListener('dragleave', () => {
    dropZone.classList.remove('dragover');
  });

  dropZone.addEventListener('drop', (e) => {
    e.preventDefault();
    dropZone.classList.remove('dragover');
    if (e.dataTransfer.files.length > 0) {
      uploadFile(e.dataTransfer.files[0]);
    }
  });

  fileInput.addEventListener('change', () => {
    if (fileInput.files.length > 0) {
      uploadFile(fileInput.files[0]);
      fileInput.value = '';
    }
  });
}

function uploadFile(file) {
  const MAX_SIZE = 500 * 1024 * 1024; // 500 MB
  if (file.size > MAX_SIZE) {
    showToast('File exceeds 500 MB limit', 'error');
    return;
  }

  const progressEl = document.getElementById('cp-upload-progress');
  const filenameEl = document.getElementById('cp-upload-filename');
  const pctEl = document.getElementById('cp-upload-pct');
  const barEl = document.getElementById('cp-upload-bar');
  const statusEl = document.getElementById('cp-upload-status');

  filenameEl.textContent = file.name;
  pctEl.textContent = '0%';
  barEl.style.width = '0%';
  progressEl.classList.remove('hidden');
  statusEl.classList.add('hidden');

  const formData = new FormData();
  formData.append('file', file);

  const xhr = new XMLHttpRequest();
  xhr.open('POST', '/api/upload');

  xhr.upload.addEventListener('progress', (e) => {
    if (e.lengthComputable) {
      const pct = Math.round((e.loaded / e.total) * 100);
      pctEl.textContent = pct + '%';
      barEl.style.width = pct + '%';
    }
  });

  xhr.addEventListener('load', () => {
    if (xhr.status >= 200 && xhr.status < 300) {
      try {
        const result = JSON.parse(xhr.responseText);
        showUploadStatus(result);
        showToast('Upload complete');
      } catch {
        showToast('Upload complete');
      }
    } else {
      showToast('Upload failed: ' + xhr.statusText, 'error');
    }
    setTimeout(() => progressEl.classList.add('hidden'), 2000);
  });

  xhr.addEventListener('error', () => {
    showToast('Upload failed: network error', 'error');
    progressEl.classList.add('hidden');
  });

  xhr.send(formData);
}

function showUploadStatus(result) {
  const statusEl = document.getElementById('cp-upload-status');
  if (!result.nodes || result.nodes.length === 0) {
    statusEl.classList.add('hidden');
    return;
  }

  statusEl.classList.remove('hidden');
  statusEl.innerHTML = result.nodes.map(n => {
    const ok = n.success;
    const color = ok ? 'var(--green)' : 'var(--red)';
    const icon = ok ? '&#10003;' : '&#10007;';
    return `<div class="flex items-center gap-2 text-xs">
      <span style="color:${color}">${icon}</span>
      <span class="text-[var(--text-secondary)]">${n.node || n.ip}</span>
      <span class="text-[var(--text-tertiary)]">${ok ? '' : n.message || ''}</span>
    </div>`;
  }).join('');
}

// =========================================================================
// Check initial training state
// =========================================================================
async function checkTrainingState() {
  try {
    const res = await fetch('/api/training/status');
    const data = await res.json();
    if (data.active) {
      setTrainingActive(true);
      connectSSE();
      startStatusPolling();
    }
  } catch {
    // Endpoint not available yet
  }
}

// =========================================================================
// Init
// =========================================================================
initTheme();

document.getElementById('theme-toggle').addEventListener('click', toggleTheme);
document.getElementById('refresh-btn').addEventListener('click', handleRefreshClick);
document.getElementById('cp-strategy').addEventListener('change', handleStrategyChange);
document.getElementById('cp-start-btn').addEventListener('click', startTraining);
document.getElementById('cp-stop-btn').addEventListener('click', stopTraining);
document.getElementById('cp-new-btn').addEventListener('click', newTraining);
document.getElementById('cp-log-clear').addEventListener('click', clearLog);

setupLogScroll();
setupUpload();

refresh();
loadFrameworks();
checkTrainingState();
setInterval(refresh, 10000);

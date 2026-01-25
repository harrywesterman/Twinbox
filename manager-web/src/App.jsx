import React, { useState, useEffect } from 'react';

function App() {
  const [status, setStatus] = useState('initializing');
  const [logs, setLogs] = useState(['[SYSTEM] Management Wizard started.', '[SYSTEM] Waiting for cluster signals...']);
  const [installing, setInstalling] = useState(false);
  const [step, setStep] = useState(0);

  const steps = [
    { name: 'Cluster Generation', desc: 'Generating Talos configuration files.' },
    { name: 'Node Bootstrap', desc: 'Bootstrapping etcd on control plane.' },
    { name: 'ArgoCD Installation', desc: 'Deploying GitOps engine to Kubernetes.' },
    { name: 'Rook/Ceph Storage', desc: 'Initializing distributed block storage.' },
    { name: 'Traefik Ingress', desc: 'Configuring ingress controller.' },
    { name: 'Management Console', desc: 'Deploying Headlamp Kubernetes UI.' },
    { name: 'Velero Backups', desc: 'Configuring backup and disaster recovery.' }
  ];

  const addLog = (msg) => {
    setLogs(prev => [...prev, `[${new Date().toLocaleTimeString()}] ${msg}`]);
  };

  const startDeployment = () => {
    setInstalling(true);
    addLog('Starting automated deployment sequence...');

    // Simulate deployment steps for UI demonstration
    let currentStep = 0;
    const interval = setInterval(() => {
      if (currentStep < steps.length) {
        setStep(currentStep);
        addLog(`Executing: ${steps[currentStep].name}...`);
        currentStep++;
      } else {
        clearInterval(interval);
        setInstalling(false);
        setStatus('ready');
        addLog('Deployment complete! ArgoCD is now live.');
      }
    }, 3000);
  };

  return (
    <div className="dashboard-container">
      <header className="header">
        <div className="brand">TWINBOX MANAGER</div>
        <div className={`status-badge ${status === 'ready' ? 'status-online' : ''}`}>
          <span className="step-dot" style={{ background: status === 'ready' ? '#10b981' : '#f59e0b' }}></span>
          {status.charAt(0).toUpperCase() + status.slice(1)}
        </div>
      </header>

      <main>
        <div className="grid">
          <section className="glass-card">
            <h2>Cluster Bootstrap</h2>
            <p>From here we finish the deployment of your Talos cluster and prepare the environment.</p>

            <div className="steps-list" style={{ marginBottom: '24px' }}>
              {steps.map((s, i) => (
                <div key={i} className={`step-indicator ${step >= i ? 'step-active' : ''}`}>
                  <div className="step-dot"></div>
                  <div style={{ color: step === i ? '#fff' : '#94a3b8' }}>{s.name}</div>
                </div>
              ))}
            </div>

            <button
              className="btn-primary"
              onClick={startDeployment}
              disabled={installing || status === 'ready'}
            >
              {installing ? 'Processing...' : status === 'ready' ? 'Cluster Active' : 'Start Installation'}
            </button>
          </section>

          <section className="glass-card">
            <h2>Recommended Apps</h2>
            <p>The first application to be installed is <strong>ArgoCD</strong>. It will manage all other cluster components.</p>

            <div style={{ padding: '16px', borderRadius: '8px', background: 'rgba(99, 102, 241, 0.1)', border: '1px solid rgba(99, 102, 241, 0.2)' }}>
              <div style={{ fontWeight: '600', marginBottom: '4px' }}>ArgoCD GitOps</div>
              <div style={{ fontSize: '13px', color: '#94a3b8' }}>Declarative, GitOps continuous delivery tool for Kubernetes.</div>
            </div>
          </section>
        </div>

        <div className="log-container" id="logs">
          {logs.map((log, i) => (
            <div key={i} style={{ marginBottom: '4px' }}>{log}</div>
          ))}
        </div>
      </main>
    </div>
  );
}

export default App;

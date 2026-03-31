import './App.css';
import heroIllustration from './assets/hero-illustration.svg';
import hardwareIllustration from './assets/hardware-illustration.svg';

const trustWords = ['On-prem', 'GitOps', 'Open Source', 'Data sovereignty'];

const steps = [
  {
    number: '01',
    title: 'Run the setup wizard on Proxmox',
    text: 'A single command creates the Management VM, installs Docker, and boots the Twinbox stack. No cloud accounts, no external dependencies.',
  },
  {
    number: '02',
    title: 'Deploy your cluster through the web UI',
    text: 'Open the browser-based installer to provision Talos Linux nodes, configure networking, and size your cluster — all from one guided interface.',
  },
  {
    number: '03',
    title: 'Install platform services step by step',
    text: 'Flannel, Argo CD, Longhorn storage, OpenBao secrets, Traefik ingress, Velero backups — each component installs in order through the same UI, driven by GitOps.',
  },
];

const benefits = [
  {
    title: 'Fully on-prem',
    text: 'Everything runs on your own hardware. Your data never leaves your network, and you are not tied to any cloud provider.',
  },
  {
    title: 'Reuse existing hardware',
    text: 'Twinbox runs on Proxmox, so you can repurpose servers or PCs you already own. No new equipment required.',
  },
  {
    title: 'GitOps by default',
    text: 'Argo CD manages every component declaratively. Changes are versioned, reviewable, and reproducible — not applied by hand.',
  },
  {
    title: 'Open Source',
    text: 'The full stack is transparent and auditable. No vendor lock-in, no hidden license fees, no black boxes.',
  },
];

const reasons = [
  {
    title: 'Production-grade Kubernetes',
    text: 'Twinbox provisions Talos Linux clusters with Flannel networking, Longhorn storage, and CloudNativePG databases — a battle-tested stack you can rely on.',
  },
  {
    title: 'Secrets managed, not scattered',
    text: 'OpenBao and External Secrets Operator centralize credentials and bootstrap material. Secrets are synced, audited, and never left in environment files.',
  },
  {
    title: 'Automated backups',
    text: 'Velero protects your workloads with scheduled snapshots to a Twinbox-managed Garage bucket or any S3-compatible target.',
  },
];

const faqs = [
  {
    question: 'What is Talos Linux?',
    answer: 'Talos is a minimal, immutable operating system designed specifically for Kubernetes. It has no shell, no SSH, and no package manager — just a hardened API surface that Twinbox configures for you.',
  },
  {
    question: 'Do I need to replace my existing IT environment?',
    answer: 'No. Twinbox deploys alongside your current setup on Proxmox. It provisions its own VMs and does not interfere with existing workloads.',
  },
  {
    question: 'What does the Management VM do?',
    answer: 'The Management VM runs the Twinbox web installer, the REST API, and a background worker that executes provisioning scripts. It is the control plane for your cluster lifecycle.',
  },
  {
    question: 'Can I use this without deep Kubernetes experience?',
    answer: 'Yes. The web UI walks you through each step with sensible defaults. You can also skip steps and install components later.',
  },
  {
    question: 'How do backups work?',
    answer: 'Twinbox installs Velero with a built-in Garage object store or connects to your own S3-compatible endpoint. Scheduled backups protect your persistent volumes automatically.',
  },
];

function App() {
  return (
    <div className="site-shell">
      <main className="landing-page">
        <header className="topbar" id="top">
          <a className="brand" href="#top" aria-label="Twinbox start">
            <span className="brand-mark" aria-hidden="true" />
            <span>Twinbox</span>
          </a>

          <nav className="topnav" aria-label="Main navigation">
            <a href="#how-it-works">How it works</a>
            <a href="#benefits">Benefits</a>
            <a href="#faq">FAQ</a>
          </nav>

          <a className="button button-small" href="#contact">
            Explore
          </a>
        </header>

        <section className="hero">
          <div className="hero-copy">
            <p className="eyebrow">Self-hosted Kubernetes on Proxmox</p>
            <h1>A fully configured Kubernetes cluster, running on your own hardware.</h1>
            <p className="hero-lead">
              Twinbox turns an existing Proxmox server into a production-grade Talos Kubernetes cluster with GitOps,
              secret management, backups, and ingress — all set up through a guided web interface.
            </p>

            <div className="hero-actions">
              <a className="button button-primary" href="#contact">
                Get started
              </a>
              <a className="button button-secondary" href="#how-it-works">
                See how it works
              </a>
            </div>

            <dl className="hero-facts" aria-label="Key points">
              <div>
                <dt>One command</dt>
                <dd>From Proxmox to running cluster</dd>
              </div>
              <div>
                <dt>GitOps</dt>
                <dd>Everything managed by Argo CD</dd>
              </div>
              <div>
                <dt>Zero cloud</dt>
                <dd>Your data never leaves your network</dd>
              </div>
            </dl>
          </div>

          <div className="hero-panel" aria-label="Twinbox illustration and highlights">
            <figure className="art-frame art-frame-hero">
              <img
                className="art-image"
                src={heroIllustration}
                alt="Illustration of a self-hosted Kubernetes cluster on local Proxmox infrastructure"
                loading="eager"
              />
            </figure>

            <article className="hero-card hero-card-main">
              <p className="card-kicker">What Twinbox provisions</p>
              <strong>Talos Linux, Argo CD, Longhorn, OpenBao, and more</strong>
              <p>
                A complete platform stack — networking, storage, secrets, databases, ingress, and backups — installed
                step by step through a single web interface.
              </p>
            </article>

            <div className="hero-card-grid">
              <article className="hero-card">
                <span>Talos Linux</span>
                <p>Immutable, API-driven OS for Kubernetes.</p>
              </article>
              <article className="hero-card">
                <span>Argo CD</span>
                <p>GitOps for every component.</p>
              </article>
              <article className="hero-card">
                <span>OpenBao</span>
                <p>Centralized secret management.</p>
              </article>
            </div>
          </div>
        </section>

        <section className="trust-band" aria-label="Core words">
          {trustWords.map((word) => (
            <span key={word} className="trust-pill">
              {word}
            </span>
          ))}
        </section>

        <section className="content-section" id="how-it-works">
          <div className="section-heading">
            <p className="eyebrow">How it works</p>
            <h2>From Proxmox to production in three stages</h2>
            <p>
              Twinbox automates the entire lifecycle: VM provisioning, cluster bootstrap, and platform service installation.
              Every step runs through the same web UI.
            </p>
          </div>

          <div className="step-grid">
            {steps.map((step) => (
              <article key={step.number} className="step-card">
                <span className="step-number">{step.number}</span>
                <h3>{step.title}</h3>
                <p>{step.text}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="content-section split-section" id="benefits">
          <div className="section-heading section-heading-compact">
            <p className="eyebrow">Benefits</p>
            <h2>Why self-hosted Kubernetes with Twinbox</h2>
            <p>
              Twinbox combines proven open-source components into a single, opinionated stack — so you get
              production-grade infrastructure without assembling it yourself.
            </p>
          </div>

          <div className="benefit-grid">
            {benefits.map((benefit) => (
              <article key={benefit.title} className="benefit-card">
                <h3>{benefit.title}</h3>
                <p>{benefit.text}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="content-section reasons-section" aria-label="Platform services">
          <div className="section-heading">
            <p className="eyebrow">Platform services</p>
            <h2>Built on trusted open-source infrastructure</h2>
          </div>

          <div className="reasons-grid">
            {reasons.map((reason) => (
              <article key={reason.title} className="reason-card">
                <h3>{reason.title}</h3>
                <p>{reason.text}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="content-section faq-section" id="faq">
          <div className="section-heading section-heading-compact">
            <p className="eyebrow">FAQ</p>
            <h2>Frequently asked questions</h2>
          </div>

          <div className="faq-list">
            {faqs.map((faq) => (
              <details key={faq.question} className="faq-item">
                <summary>{faq.question}</summary>
                <p>{faq.answer}</p>
              </details>
            ))}
          </div>
        </section>

        <section className="contact-band" id="contact">
          <div className="contact-copy">
            <p className="eyebrow">Ready to get started</p>
            <h2>Run one command on Proxmox. Open your browser. Build your cluster.</h2>
            <p>
              Twinbox is open source and runs entirely on your infrastructure. Clone the repository and follow the
              quick-start guide to have a Management VM running in minutes.
            </p>

            <div className="hero-actions">
              <a className="button button-primary" href="https://github.com/harrywesterman/twinbox">
                View on GitHub
              </a>
              <a className="button button-secondary" href="#top">
                Back to top
              </a>
            </div>
          </div>

          <figure className="art-frame art-frame-contact">
            <img
              className="art-image"
              src={hardwareIllustration}
              alt="Illustration of Proxmox server hardware running a Twinbox Kubernetes cluster"
              loading="lazy"
            />
          </figure>
        </section>
      </main>
    </div>
  );
}

export default App;

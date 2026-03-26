import './App.css';
import heroIllustration from './assets/hero-illustration.svg';
import hardwareIllustration from './assets/hardware-illustration.svg';

const trustWords = ['Sovereign', 'Your data', 'In control', 'Always up to date'];

const steps = [
  {
    number: '01',
    title: 'Set up Twinbox on your own hardware',
    text: 'Use an existing PC or server in your own environment. Twinbox is built for on-prem use, with no cloud dependency.',
  },
  {
    number: '02',
    title: 'Let Twinbox do the heavy lifting',
    text: 'The setup takes care of the basics, updates, and initial configuration for you. You do not need to manage every step by hand.',
  },
  {
    number: '03',
    title: 'Keep working without extra stress',
    text: 'Your data stays local, your environment stays current, and you need far less IT administration. That creates calm and clarity.',
  },
];

const benefits = [
  {
    title: 'No cloud',
    text: 'Keep your data and infrastructure close. That makes you less dependent on external platforms.',
  },
  {
    title: 'Reuse existing hardware',
    text: 'Twinbox is a practical layer on top of existing PCs or servers, so you do not have to buy new equipment first.',
  },
  {
    title: 'Minimal administration',
    text: 'The focus is on automatic updates and a clear baseline, not on endless manual maintenance.',
  },
  {
    title: 'Open Source',
    text: 'Transparent, modern, and easy to assess. No black box you need to trust blindly.',
  },
];

const reasons = [
  {
    title: 'Calm for non-technical people',
    text: 'Twinbox explains what is happening in plain language so the solution stays understandable for everyone.',
  },
  {
    title: 'Sovereignty without drama',
    text: 'Even when political winds shift in the United States, your data stays under your own control.',
  },
  {
    title: 'Up to date without stress',
    text: 'New techniques and security updates are part of the design, so the platform stays fresh without adding much work.',
  },
];

const faqs = [
  {
    question: 'Do I need to replace my entire IT environment?',
    answer: 'No. Twinbox is designed to reuse existing hardware and an existing base where that makes sense.',
  },
  {
    question: 'Is this only for technical teams?',
    answer: 'No. The goal is that you can understand it and explain it to colleagues without deep technical knowledge.',
  },
  {
    question: 'Is everything in the cloud?',
    answer: 'No. Twinbox is intended for on-prem use, so your data stays local and under your own control.',
  },
  {
    question: 'Will the system stay current?',
    answer: 'Yes. Automatic updates and a modern Open Source base help keep the platform up to date.',
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
            <p className="eyebrow">Sovereign. Simple. On-prem.</p>
            <h1>Your data stays yours. Twinbox keeps it calm and up to date.</h1>
            <p className="hero-lead">
              For organizations that want control without cloud dependency, with a solution that feels clear, calm, and easy
              to explore.
            </p>

            <div className="hero-actions">
              <a className="button button-primary" href="#contact">
                Explore Twinbox
              </a>
              <a className="button button-secondary" href="#how-it-works">
                See how it works
              </a>
            </div>

            <dl className="hero-facts" aria-label="Key points">
              <div>
                <dt>Local</dt>
                <dd>Data stays under your own control</dd>
              </div>
              <div>
                <dt>Automatic</dt>
                <dd>Updates without much manual work</dd>
              </div>
              <div>
                <dt>Practical</dt>
                <dd>Works on hardware you already own</dd>
              </div>
            </dl>
          </div>

          <div className="hero-panel" aria-label="Twinbox illustration and highlights">
            <figure className="art-frame art-frame-hero">
              <img
                className="art-image"
                src={heroIllustration}
                alt="Abstract illustration of local control, calm updates, and a connected on-prem environment"
                loading="eager"
              />
            </figure>

            <article className="hero-card hero-card-main">
              <p className="card-kicker">What Twinbox promises</p>
              <strong>Calm operations, control over your data</strong>
              <p>
                A straightforward on-prem foundation for teams that want to keep their data in-house instead of relying on a
                public cloud.
              </p>
            </article>

            <div className="hero-card-grid">
              <article className="hero-card">
                <span>No cloud</span>
                <p>Everything stays local.</p>
              </article>
              <article className="hero-card">
                <span>Open Source</span>
                <p>Transparent and modern.</p>
              </article>
              <article className="hero-card">
                <span>Low maintenance</span>
                <p>Automatic where it matters.</p>
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
            <h2>Three simple steps, with no complicated explanation</h2>
            <p>
              The idea is intentionally easy to follow: Twinbox helps you move from existing hardware to a calm, manageable
              environment.
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
            <h2>Why Twinbox feels right for teams and decision-makers</h2>
            <p>
              The page focuses on outcomes: less hassle, more control, and a platform that stays in step with modern
              techniques.
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

        <section className="content-section reasons-section" aria-label="Why Twinbox">
          <div className="section-heading">
            <p className="eyebrow">Why Twinbox</p>
            <h2>Built for local control, modern techniques, and a calm explanation</h2>
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
            <h2>Common questions in plain language</h2>
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
            <p className="eyebrow">Ready for a first impression</p>
            <h2>See whether Twinbox fits your environment.</h2>
            <p>
              This version is ready for GitHub Pages. The operational management environment can keep running separately on
              the Management VM.
            </p>

            <div className="hero-actions">
              <a className="button button-primary" href="https://github.com/harrywesterman/twinbox">
                See the source code
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
              alt="Friendly illustration of reusable hardware and a local, on-prem Twinbox stack"
              loading="lazy"
            />
          </figure>
        </section>
      </main>
    </div>
  );
}

export default App;

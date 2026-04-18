import { useCallback, useEffect, useMemo, useState } from 'react';

function requestJson(url, options = {}) {
  return fetch(url, {
    headers: {
      'Content-Type': 'application/json',
      ...(options.headers || {}),
    },
    ...options,
  }).then(async (response) => {
    const text = await response.text();
    let body = null;
    if (text) {
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
    }
    if (!response.ok) {
      const error = new Error(body?.error || body?.message || text || `Request failed with ${response.status}`);
      error.status = response.status;
      throw error;
    }
    return body;
  });
}

function formatHost(url) {
  try {
    return new URL(url, window.location.origin).host;
  } catch {
    return url;
  }
}

function slugify(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function badgeTone(ok) {
  return ok ? 'is-ok' : 'is-bad';
}

function useRoute() {
  const [pathname, setPathname] = useState(window.location.pathname);

  useEffect(() => {
    const onPopState = () => setPathname(window.location.pathname);
    window.addEventListener('popstate', onPopState);
    return () => window.removeEventListener('popstate', onPopState);
  }, []);

  const navigate = (nextPath) => {
    if (nextPath === window.location.pathname) {
      return;
    }
    window.history.pushState({}, '', nextPath);
    setPathname(nextPath);
  };

  return [pathname, navigate];
}

function usePortalData() {
  const [sessionState, setSessionState] = useState({ loading: true, session: null });
  const [configState, setConfigState] = useState({ loading: true, config: null });
  const [preferences, setPreferences] = useState(null);
  const [statusState, setStatusState] = useState({ loading: false, data: null });

  useEffect(() => {
    let cancelled = false;
    requestJson('/api/session')
      .then((payload) => {
        if (!cancelled) {
          setSessionState({ loading: false, session: payload.session });
        }
      })
      .catch(() => {
        if (!cancelled) {
          setSessionState({ loading: false, session: null });
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!sessionState.session) {
      setConfigState({ loading: false, config: null });
      setPreferences(null);
      return;
    }

    let cancelled = false;
    Promise.all([
      requestJson('/api/portal-config'),
      requestJson('/api/preferences'),
    ]).then(([config, prefs]) => {
      if (cancelled) {
        return;
      }
      setConfigState({ loading: false, config });
      setPreferences(prefs);
    }).catch(() => {
      if (!cancelled) {
        setConfigState({ loading: false, config: null });
        setPreferences(null);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [sessionState.session]);

  const refreshStatus = useCallback(async () => {
    setStatusState((current) => ({ ...current, loading: true }));
    try {
      const data = await requestJson('/api/status');
      setStatusState({ loading: false, data });
    } catch {
      setStatusState({ loading: false, data: null });
    }
  }, []);

  return {
    sessionState,
    configState,
    preferences,
    setPreferences,
    statusState,
    refreshStatus,
  };
}

function SectionTitle({ eyebrow, title, description }) {
  return (
    <header className="section-title">
      <p>{eyebrow}</p>
      <h2>{title}</h2>
      {description ? <p className="section-title-copy">{description}</p> : null}
    </header>
  );
}

function AppTile({ card, onOpen }) {
  return (
    <button className="app-tile" type="button" onClick={onOpen}>
      <span className="app-tile-badge" style={{ '--accent': card.accent }}>
        <span>{card.iconText}</span>
      </span>
      <span className="app-tile-body">
        <strong>{card.title}</strong>
        <span>{card.summary}</span>
      </span>
      <span className="app-tile-meta">
        <span className={`status-chip ${card.status ? 'is-live' : ''}`}>{card.status || 'ready'}</span>
      </span>
    </button>
  );
}

function Panel({ className = '', children }) {
  return <section className={`panel ${className}`}>{children}</section>;
}

function MenuPopover({ visible, onNavigate, onLogout, onClose, isAdmin }) {
  if (!visible) {
    return null;
  }

  return (
    <div className="menu-popover" role="menu">
      <button type="button" onClick={() => { onNavigate('/settings'); onClose(); }}>Settings</button>
      {isAdmin ? <button type="button" onClick={() => { onNavigate('/admin'); onClose(); }}>Admin apps</button> : null}
      <button type="button" onClick={() => { onNavigate('/intranet'); onClose(); }}>Intranet</button>
      <button type="button" onClick={() => { onNavigate('/status'); onClose(); }}>Cluster status</button>
      <button type="button" onClick={() => { onLogout(); onClose(); }}>Log out</button>
    </div>
  );
}

function LoginScreen({ brand, onLogin }) {
  return (
    <main className="auth-screen">
      <div className="auth-shell">
        <div className="auth-hero">
          <span className="auth-mark" />
          <p className="eyebrow">{brand}</p>
          <h1>Twinbox Portal</h1>
          <p>
            One place for your apps, settings, intranet links, and a high-level view of the cluster.
          </p>
          <button type="button" className="primary-button" onClick={onLogin}>
            Sign in with Authentik
          </button>
        </div>
        <div className="auth-notes">
          <div>
            <strong>Apps</strong>
            <span>Launch the tools that are available for your account.</span>
          </div>
          <div>
            <strong>Settings</strong>
            <span>Store your language, timezone, and theme server-side.</span>
          </div>
          <div>
            <strong>Status</strong>
            <span>See whether the platform services are reachable.</span>
          </div>
        </div>
      </div>
    </main>
  );
}

function PortalHeader({ session, config, theme, onThemeToggle, onNavigate, onLogout, onMenuToggle, menuOpen, isAdmin }) {
  return (
    <header className="topbar">
      <button type="button" className="topbar-brand" onClick={() => onNavigate('/')}>
        <span className="brand-mark" />
        <div>
          <strong>Twinbox</strong>
          <span>{config?.portal?.hero?.eyebrow || 'User portal'}</span>
        </div>
      </button>
      <div className="topbar-actions">
        <button type="button" className="icon-button" onClick={onThemeToggle} aria-label="Toggle theme">
          {theme === 'dark' ? '◐' : '◑'}
        </button>
        <button type="button" className="icon-button" onClick={onMenuToggle} aria-label="Open menu">
          ☰
        </button>
        <MenuPopover
          visible={menuOpen}
          onNavigate={onNavigate}
          onLogout={onLogout}
          onClose={onMenuToggle}
          isAdmin={isAdmin}
        />
        <div className="topbar-session">
          <strong>{session?.name || 'User'}</strong>
          <span>{isAdmin ? 'Admins' : 'Member'}</span>
        </div>
      </div>
    </header>
  );
}

function HomePage({ config, navigate, isAdmin }) {
  const sections = config?.appSections || [];

  return (
    <div className="page-grid">
      <Panel className="hero-panel">
        <p className="eyebrow">{config?.portal?.hero?.eyebrow || 'User portal'}</p>
        <h1>{config?.portal?.hero?.title || 'Twinbox Portal'}</h1>
        <p className="hero-copy">{config?.portal?.hero?.description}</p>
        <div className="hero-actions">
          <button type="button" className="primary-button" onClick={() => navigate('/status')}>Cluster status</button>
          <button type="button" className="secondary-button" onClick={() => navigate('/settings')}>Settings</button>
        </div>
      </Panel>

      <div className="stack">
        {sections.map((section) => (
          <Panel key={section.name}>
            <SectionTitle
              eyebrow={section.name}
              title="Applications"
              description="Open the app, read the overview, and start when you are ready."
            />
            <div className="card-grid">
              {section.items.map((card) => (
                <AppTile key={card.id} card={card} onOpen={() => navigate(card.route)} />
              ))}
            </div>
          </Panel>
        ))}
        {isAdmin ? (
          <Panel className="admin-teaser">
            <SectionTitle
              eyebrow="Admin"
              title="Management apps"
              description="A separate space for the operator tools."
            />
            <button type="button" className="primary-button" onClick={() => navigate('/admin')}>
              Open admin apps
            </button>
          </Panel>
        ) : null}
      </div>
    </div>
  );
}

function AppDetailPage({ card, onNavigate }) {
  if (!card) {
    return (
      <Panel>
        <SectionTitle eyebrow="Missing app" title="Nothing here yet" description="This app is not available in the current cluster state." />
        <button type="button" className="secondary-button" onClick={() => onNavigate('/')}>Back home</button>
      </Panel>
    );
  }

  return (
    <div className="detail-layout">
      <Panel className="detail-hero">
        <span className="detail-icon" style={{ '--accent': card.accent }}>
          <span>{card.iconText}</span>
        </span>
        <div className="detail-copy">
          <p className="eyebrow">{card.section}</p>
          <h1>{card.title}</h1>
          <p>{card.description}</p>
          <div className="hero-actions">
            <button type="button" className="primary-button" onClick={() => window.location.assign(card.liveUrl || card.url)}>Start</button>
            <button type="button" className="secondary-button" onClick={() => onNavigate('/')}>Back</button>
          </div>
        </div>
      </Panel>
      <div className="detail-side">
        <Panel>
          <SectionTitle eyebrow="What it does" title="Capabilities" />
          <ul className="capability-list">
            {card.capabilities.map((item) => <li key={item}>{item}</li>)}
          </ul>
        </Panel>
        <Panel>
          <SectionTitle eyebrow="Launch" title="Details" />
          <dl className="fact-list">
            <div>
              <dt>Host</dt>
              <dd>{formatHost(card.liveUrl || card.url)}</dd>
            </div>
            <div>
              <dt>Status</dt>
              <dd><span className="status-chip is-live">{card.status || 'ready'}</span></dd>
            </div>
            <div>
              <dt>Source</dt>
              <dd>{card.sourceStepTitle || card.sourceStepId}</dd>
            </div>
          </dl>
        </Panel>
      </div>
    </div>
  );
}

function SettingsPage({ config, preferences, setPreferences, onSave, onNavigate }) {
  const [draft, setDraft] = useState(preferences || { theme: 'dark', language: 'nl', timezone: Intl.DateTimeFormat().resolvedOptions().timeZone });
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    setDraft(preferences || { theme: 'dark', language: 'nl', timezone: Intl.DateTimeFormat().resolvedOptions().timeZone });
  }, [preferences]);

  const submit = async (event) => {
    event.preventDefault();
    const next = await onSave(draft);
    setPreferences(next);
    setSaved(true);
    window.setTimeout(() => setSaved(false), 2500);
  };

  const timezoneOptions = useMemo(() => {
    if (typeof Intl.supportedValuesOf === 'function') {
      try {
        return Intl.supportedValuesOf('timeZone').slice(0, 400);
      } catch {
        return [];
      }
    }
    return [];
  }, []);

  return (
    <Panel>
      <SectionTitle
        eyebrow="Settings"
        title="Personal preferences"
        description="Language, timezone, and theme are stored on the portal side for this account."
      />
      <form className="settings-form" onSubmit={submit}>
        <label>
          <span>Language</span>
          <select value={draft.language || 'nl'} onChange={(event) => setDraft((current) => ({ ...current, language: event.target.value }))}>
            {(config?.settings?.languages || [{ value: 'nl', label: 'Nederlands' }, { value: 'en', label: 'English' }]).map((option) => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </select>
        </label>
        <label>
          <span>Timezone</span>
          <select value={draft.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone} onChange={(event) => setDraft((current) => ({ ...current, timezone: event.target.value }))}>
            <option value={Intl.DateTimeFormat().resolvedOptions().timeZone}>
              {Intl.DateTimeFormat().resolvedOptions().timeZone}
            </option>
            {timezoneOptions.slice(0, 20).map((timezone) => (
              <option key={timezone} value={timezone}>{timezone}</option>
            ))}
          </select>
        </label>
        <label>
          <span>Theme</span>
          <div className="segmented-control">
            <button
              type="button"
              className={draft.theme === 'light' ? 'is-active' : ''}
              onClick={() => setDraft((current) => ({ ...current, theme: 'light' }))}
            >
              Light
            </button>
            <button
              type="button"
              className={draft.theme === 'dark' ? 'is-active' : ''}
              onClick={() => setDraft((current) => ({ ...current, theme: 'dark' }))}
            >
              Dark
            </button>
          </div>
        </label>
        <div className="settings-actions">
          <button type="submit" className="primary-button">Save preferences</button>
          <span className={`save-banner ${saved ? 'is-visible' : ''}`}>Saved</span>
        </div>
      </form>

      <div className="settings-links">
        <a className="link-card" href={config?.settings?.authentikUserUrl || '#'} target="_blank" rel="noreferrer">
          <strong>Set password</strong>
          <span>Open the Authentik user self-service area.</span>
        </a>
        <a className="link-card" href={config?.settings?.authentikOtpUrl || '#'} target="_blank" rel="noreferrer">
          <strong>Enable 2FA</strong>
          <span>Manage your Authentik authenticator devices.</span>
        </a>
        <a className="link-card" href={config?.settings?.issueUrl || '#'} target="_blank" rel="noreferrer">
          <strong>Meld een issue</strong>
          <span>Open a GitHub issue for bug reports or requests.</span>
        </a>
      </div>

      <button type="button" className="secondary-button" onClick={() => onNavigate('/')}>Back home</button>
    </Panel>
  );
}

function IntranetPage({ links, onNavigate }) {
  return (
    <Panel>
      <SectionTitle
        eyebrow="Intranet"
        title="Handy links"
        description="A lightweight internal directory for the things you open most often."
      />
      <div className="card-grid intranet-grid">
        {links.map((card) => (
          <a key={card.id} className="intranet-card" href={card.liveUrl || card.url}>
            <span className="app-tile-badge" style={{ '--accent': card.accent }}>
              <span>{card.iconText}</span>
            </span>
            <strong>{card.title}</strong>
            <span>{card.summary}</span>
          </a>
        ))}
      </div>
      <button type="button" className="secondary-button" onClick={() => onNavigate('/')}>Back home</button>
    </Panel>
  );
}

function AdminPage({ adminApps, onNavigate }) {
  return (
    <Panel>
      <SectionTitle
        eyebrow="Admin"
        title="Management apps"
        description="Operators and admins get their own screen, separate from the normal launcher."
      />
      <div className="card-grid">
        {adminApps.map((card) => (
          <AppTile key={card.id} card={card} onOpen={() => window.location.assign(card.liveUrl || card.url)} />
        ))}
      </div>
      <button type="button" className="secondary-button" onClick={() => onNavigate('/')}>Back home</button>
    </Panel>
  );
}

function StatusPage({ statusState, onRefresh, onNavigate }) {
  const data = statusState.data;
  return (
    <Panel>
      <SectionTitle
        eyebrow="Cluster status"
        title="High-level health"
        description="A user-friendly view of the core platform services."
      />
      <div className="status-summary">
        <div>
          <strong>{data?.summary?.label || 'Status is not loaded yet'}</strong>
          <span>{data?.summary ? `${data.summary.healthy}/${data.summary.total} checks healthy` : 'Tap refresh to load the current view.'}</span>
        </div>
        <div className="hero-actions">
          <button type="button" className="secondary-button" onClick={onRefresh}>Refresh</button>
          <button type="button" className="secondary-button" onClick={() => onNavigate('/')}>Back home</button>
        </div>
      </div>
      <div className="status-grid">
        {(data?.checks || []).map((check) => (
          <article key={check.title} className={`status-card ${badgeTone(check.ok)}`}>
            <div className="status-card-head">
              <strong>{check.title}</strong>
              <span className="status-chip">{check.ok ? 'healthy' : 'attention'}</span>
            </div>
            <p>{check.description}</p>
            <span>{check.note}</span>
          </article>
        ))}
      </div>
    </Panel>
  );
}

export default function App() {
  const [route, navigate] = useRoute();
  const { sessionState, configState, preferences, setPreferences, statusState, refreshStatus } = usePortalData();
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => {
    const theme = preferences?.theme || 'dark';
    document.documentElement.dataset.theme = theme;
  }, [preferences?.theme]);

  useEffect(() => {
    if (route === '/status' && !statusState.loading && !statusState.data) {
      refreshStatus();
    }
  }, [route, refreshStatus, statusState.data, statusState.loading]);

  useEffect(() => {
    const onClick = (event) => {
      if (!event.target.closest?.('.menu-popover') && !event.target.closest?.('.icon-button')) {
        setMenuOpen(false);
      }
    };
    window.addEventListener('click', onClick);
    return () => window.removeEventListener('click', onClick);
  }, []);

  const session = sessionState.session;
  const config = configState.config;
  const isAdmin = Boolean(session?.isAdmin);

  const currentApp = useMemo(() => {
    if (!config?.apps) {
      return null;
    }
    const slug = route.startsWith('/apps/') ? route.split('/').pop() : '';
    return config.apps.find((card) => card.slug === slug) || null;
  }, [config, route]);

  const login = () => {
    window.location.href = `/auth/login?returnTo=${encodeURIComponent(route || '/')}`;
  };

  const logout = () => {
    window.location.href = '/auth/logout';
  };

  const toggleTheme = async () => {
    if (!session) {
      return;
    }
    const nextTheme = preferences?.theme === 'dark' ? 'light' : 'dark';
    const nextPreferences = {
      ...(preferences || {}),
      theme: nextTheme,
      language: preferences?.language || 'nl',
      timezone: preferences?.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone,
    };
    try {
      const saved = await requestJson('/api/preferences', {
        method: 'PUT',
        body: JSON.stringify(nextPreferences),
      });
      setPreferences(saved);
    } catch {
      setPreferences(nextPreferences);
    }
  };

  const savePreferences = async (draft) => {
    const saved = await requestJson('/api/preferences', {
      method: 'PUT',
      body: JSON.stringify(draft),
    });
    return saved;
  };

  if (sessionState.loading || configState.loading) {
    return (
      <main className="loading-screen">
        <div className="loading-card">
          <span className="brand-mark" />
          <p className="eyebrow">Twinbox</p>
          <h1>Loading portal</h1>
          <p>Preparing your session, app catalog, and preferences.</p>
        </div>
      </main>
    );
  }

  if (!session) {
    return <LoginScreen brand="Twinbox" onLogin={login} />;
  }

  return (
    <main className="portal-shell">
      <PortalHeader
        session={session}
        config={config}
        theme={preferences?.theme || 'dark'}
        onThemeToggle={toggleTheme}
        onNavigate={navigate}
        onLogout={logout}
        onMenuToggle={() => setMenuOpen((current) => !current)}
        menuOpen={menuOpen}
        isAdmin={isAdmin}
      />

      <section className="portal-content">
        {route === '/' ? <HomePage config={config} navigate={navigate} isAdmin={isAdmin} /> : null}
        {route.startsWith('/apps/') ? <AppDetailPage card={currentApp} onNavigate={navigate} /> : null}
        {route === '/settings' ? <SettingsPage config={config} preferences={preferences} setPreferences={setPreferences} onSave={savePreferences} onNavigate={navigate} /> : null}
        {route === '/intranet' ? <IntranetPage links={config?.intranetLinks || []} onNavigate={navigate} /> : null}
        {route === '/status' ? <StatusPage statusState={statusState} onRefresh={refreshStatus} onNavigate={navigate} /> : null}
        {route === '/admin' && isAdmin ? <AdminPage adminApps={config?.adminApps || []} onNavigate={navigate} /> : null}
        {route === '/admin' && !isAdmin ? (
          <Panel>
            <SectionTitle eyebrow="Access denied" title="Admins only" description="This part of Twinbox is reserved for the admins group." />
            <button type="button" className="secondary-button" onClick={() => navigate('/')}>Back home</button>
          </Panel>
        ) : null}
      </section>
    </main>
  );
}

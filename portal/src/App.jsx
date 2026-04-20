import { startTransition, useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from 'react';

import { buildAdminAppsViewModel } from './admin-apps-model.js';
import { buildAdminNavigationItems, buildUserAdminViewModel } from './user-admin-model.js';

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

function openInNewTab(url) {
  if (!url) {
    return;
  }
  window.open(url, '_blank', 'noopener,noreferrer');
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

function useUserAdminData(enabled) {
  const [state, setState] = useState({
    loading: false,
    refreshing: false,
    error: '',
    users: [],
    groups: [],
  });

  const load = useCallback(async ({ silent = false } = {}) => {
    if (!enabled) {
      setState({
        loading: false,
        refreshing: false,
        error: '',
        users: [],
        groups: [],
      });
      return;
    }

    setState((current) => ({
      ...current,
      loading: current.users.length === 0 && !silent,
      refreshing: current.users.length > 0 || silent,
      error: '',
    }));

    try {
      const [usersPayload, groupsPayload] = await Promise.all([
        requestJson('/api/admin/users'),
        requestJson('/api/admin/groups'),
      ]);

      setState({
        loading: false,
        refreshing: false,
        error: '',
        users: Array.isArray(usersPayload?.users) ? usersPayload.users : [],
        groups: Array.isArray(groupsPayload?.groups) ? groupsPayload.groups : [],
      });
    } catch (error) {
      setState((current) => ({
        ...current,
        loading: false,
        refreshing: false,
        error: error instanceof Error ? error.message : 'Failed to load users and groups.',
      }));
    }
  }, [enabled]);

  useEffect(() => {
    load();
  }, [load]);

  return {
    ...state,
    reload: useCallback(() => load({ silent: true }), [load]),
  };
}

function useAdminAppsData(enabled) {
  const [state, setState] = useState({
    loading: false,
    refreshing: false,
    error: '',
    catalog: null,
  });

  const load = useCallback(async ({ silent = false } = {}) => {
    if (!enabled) {
      setState({
        loading: false,
        refreshing: false,
        error: '',
        catalog: null,
      });
      return;
    }

    setState((current) => ({
      ...current,
      loading: current.catalog === null && !silent,
      refreshing: current.catalog !== null || silent,
      error: '',
    }));

    try {
      const catalog = await requestJson('/api/admin/apps/catalog');
      setState({
        loading: false,
        refreshing: false,
        error: '',
        catalog,
      });
    } catch (error) {
      setState((current) => ({
        ...current,
        loading: false,
        refreshing: false,
        error: error instanceof Error ? error.message : 'Failed to load app catalog.',
      }));
    }
  }, [enabled]);

  useEffect(() => {
    load();
  }, [load]);

  return {
    ...state,
    reload: useCallback((options) => load(options), [load]),
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

function AppIcon({ card, className = '' }) {
  if (card?.iconUrl) {
    return <img className={`app-icon-image ${className}`.trim()} src={card.iconUrl} alt={card.iconAlt || `${card.title} icon`} loading="lazy" />;
  }

  return (
    <span className={`app-tile-badge ${className}`.trim()} style={{ '--accent': card.accent }}>
      <span>{card.iconText}</span>
    </span>
  );
}

function adminStepIconUrl(card) {
  const title = String(card?.title || '').trim();
  const base = String(card?.sourceStepId || card?.id || '').trim();
  if (title === 'Dashy') {
    return '/assets/step-icons/install-dashy-dashboard.svg';
  }
  return base ? `/assets/step-icons/${base}.svg` : '';
}

function AppTile({ card, onOpen, showStatus = false }) {
  return (
    <button className="app-tile" type="button" onClick={onOpen}>
      <AppIcon card={card} className="app-tile-badge" />
      <span className="app-tile-body">
        <strong>{card.title}</strong>
        <span>{card.summary}</span>
      </span>
      {showStatus ? (
        <span className="app-tile-meta">
          <span className={`status-chip ${card.status ? 'is-live' : ''}`}>{card.status || 'ready'}</span>
        </span>
      ) : null}
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

  const adminItems = buildAdminNavigationItems({ isAdmin });

  return (
    <div className="menu-popover" role="menu">
      <button type="button" onClick={() => { onNavigate('/settings'); onClose(); }}>Settings</button>
      {adminItems.map((item) => (
        <button key={item.id} type="button" onClick={() => { onNavigate(item.path); onClose(); }}>
          {item.label}
        </button>
      ))}
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

function HomePage({ config, navigate }) {
  const apps = config?.apps || [];

  return (
    <Panel className="apps-home-panel">
      <SectionTitle
        eyebrow="Apps"
        title="Applications"
        description="Open the app, read the overview, and start when you are ready."
      />
      <div className="card-grid apps-home-grid">
        {apps.map((card) => (
          <AppTile key={card.id} card={card} onOpen={() => navigate(card.route)} />
        ))}
      </div>
      {apps.length === 0 ? (
        <div className="empty-card">
          <strong>No applications available yet</strong>
          <span>Install the app category to populate this launcher.</span>
        </div>
      ) : null}
    </Panel>
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
        <AppIcon card={card} className="detail-icon" />
        <div className="detail-copy">
          <p className="eyebrow">{card.section}</p>
          <h1>{card.title}</h1>
          <p>{card.description}</p>
          <div className="hero-actions">
            <button type="button" className="primary-button" onClick={() => openInNewTab(card.liveUrl || card.url)}>Start in new tab</button>
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
          <a key={card.id} className="intranet-card" href={card.liveUrl || card.url} target="_blank" rel="noreferrer">
            <AppIcon card={card} className="app-tile-badge" />
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
      <div className="admin-actions">
        <div className="admin-actions-buttons">
          <button type="button" className="primary-button" onClick={() => onNavigate('/admin/apps')}>
            Open app installs
          </button>
          <button type="button" className="primary-button" onClick={() => onNavigate('/admin/users')}>
            Open user admin
          </button>
        </div>
        <p className="admin-actions-copy">
          Give non-technical admins one safe place to add, disable, and group users.
        </p>
      </div>
      <div className="card-grid">
        {adminApps.map((card) => (
          <AppTile
            key={card.id}
            card={{
              ...card,
              title: card.label || card.title,
            }}
            onOpen={() => openInNewTab(card.liveUrl || card.url)}
            showStatus
          />
        ))}
      </div>
      <button type="button" className="secondary-button" onClick={() => onNavigate('/')}>Back home</button>
    </Panel>
  );
}

function statusTone(state) {
  switch (state) {
    case 'installed':
      return 'is-live';
    case 'ready':
      return 'is-ok';
    case 'installing':
      return 'is-warning';
    case 'blocked':
    case 'planned':
      return 'is-neutral';
    case 'failed':
      return 'is-bad';
    default:
      return 'is-neutral';
  }
}

function statusLabel(state) {
  switch (state) {
    case 'installed':
      return 'installed';
    case 'ready':
      return 'ready';
    case 'installing':
      return 'installing';
    case 'blocked':
      return 'blocked';
    case 'planned':
      return 'coming soon';
    case 'failed':
      return 'failed';
    default:
      return 'planned';
  }
}

function LogViewport({ lines = [], emptyLabel = 'Waiting for output...', viewportRef, onScroll }) {
  return (
    <div className="admin-log-viewport" ref={viewportRef} onScroll={onScroll}>
      {lines.length === 0 ? (
        <p className="muted-copy">{emptyLabel}</p>
      ) : (
        <pre className="admin-log-output">{lines.map((line) => (typeof line === 'string' ? line : line.line)).join('\n')}</pre>
      )}
    </div>
  );
}

function AdminAppCard({ card, selected, onSelect }) {
  const iconCard = {
    ...card,
    iconUrl: card.iconUrl || card.iconArtworkUrl || adminStepIconUrl(card),
    iconAlt: `${card.title} icon`,
  };

  return (
    <button
      type="button"
      className={`admin-app-card ${selected ? 'is-selected' : ''} ${card.title === 'Dashy' ? 'is-dashy' : ''}`}
      onClick={onSelect}
    >
      <AppIcon card={iconCard} className="admin-app-icon" />
      <span className="admin-app-card-copy">
        <strong>{card.title}</strong>
        <span>{card.summary}</span>
      </span>
      <span className="admin-app-card-meta">
        <span className={`status-chip ${statusTone(card.app_state)}`}>{statusLabel(card.app_state)}</span>
        {card.placeholder ? <small>Placeholder</small> : null}
      </span>
    </button>
  );
}

function AdminAppsPage({ onNavigate, adminAppsState }) {
  const [query, setQuery] = useState('');
  const deferredQuery = useDeferredValue(query);
  const [selectedAppId, setSelectedAppId] = useState('');
  const [selectedJob, setSelectedJob] = useState(null);
  const [jobLines, setJobLines] = useState([]);
  const [installBusy, setInstallBusy] = useState(false);
  const [pageError, setPageError] = useState('');
  const [pageNotice, setPageNotice] = useState('');
  const logViewportRef = useRef(null);
  const autoScrollLogsRef = useRef(true);
  const appsState = adminAppsState || useAdminAppsData(true);

  const viewModel = useMemo(() => buildAdminAppsViewModel({
    catalog: appsState.catalog,
    query: deferredQuery,
    selectedAppId,
  }), [appsState.catalog, deferredQuery, selectedAppId]);

  useEffect(() => {
    if (!selectedAppId && viewModel.selectedApp) {
      startTransition(() => setSelectedAppId(viewModel.selectedApp.id));
    }
  }, [selectedAppId, viewModel.selectedApp]);

  useEffect(() => {
    if (!viewModel.selectedApp?.id) {
      return;
    }

    const currentSelected = viewModel.selectedApp.id;
    if (selectedAppId !== currentSelected) {
      return;
    }

    const selectedJobStepId = selectedJob?.payload?.step_id || selectedJob?.step_id;
    if (selectedJob?.id && selectedJobStepId === currentSelected) {
      return;
    }

    if (viewModel.selectedApp.latest_job?.id && ['pending', 'running', 'cancel_requested'].includes(viewModel.selectedApp.latest_job.status)) {
      setSelectedJob(viewModel.selectedApp.latest_job);
      return;
    }

    if (viewModel.selectedApp.latest_job?.id) {
      setSelectedJob(viewModel.selectedApp.latest_job);
      if (viewModel.selectedApp.latest_job.status !== 'failed') {
        setJobLines([]);
      }
      return;
    }

    setSelectedJob(null);
    setJobLines([]);
  }, [selectedAppId, selectedJob?.id, viewModel.selectedApp]);

  useEffect(() => {
    if (!selectedJob?.id) {
      autoScrollLogsRef.current = true;
      return undefined;
    }

    autoScrollLogsRef.current = true;

    let cancelled = false;
    let timeoutId = null;

    const poll = async () => {
      try {
        const [jobPayload, logsPayload] = await Promise.all([
          requestJson(`/api/admin/apps/jobs/${encodeURIComponent(selectedJob.id)}`),
          requestJson(`/api/admin/apps/jobs/${encodeURIComponent(selectedJob.id)}/logs`),
        ]);

        if (cancelled) {
          return;
        }

        setSelectedJob(jobPayload);
        setJobLines(Array.isArray(logsPayload?.lines) ? logsPayload.lines : []);

        if (['pending', 'running', 'cancel_requested'].includes(jobPayload.status)) {
          timeoutId = window.setTimeout(poll, 2000);
        } else {
          setInstallBusy(false);
          await appsState.reload({ silent: true });
        }
      } catch (error) {
        if (!cancelled) {
          setPageError(error instanceof Error ? error.message : 'Failed to load job progress.');
          setInstallBusy(false);
        }
      }
    };

    poll();

    return () => {
      cancelled = true;
      if (timeoutId) {
        window.clearTimeout(timeoutId);
      }
    };
  }, [appsState, selectedJob?.id]);

  useEffect(() => {
    const viewport = logViewportRef.current;
    if (!viewport || !selectedJob?.id || !autoScrollLogsRef.current) {
      return;
    }

    viewport.scrollTop = viewport.scrollHeight;
  }, [jobLines, selectedJob?.id]);

  const handleLogScroll = () => {
    const viewport = logViewportRef.current;
    if (!viewport) {
      return;
    }

    const distanceFromBottom = viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
    autoScrollLogsRef.current = distanceFromBottom < 40;
  };

  const installSelectedApp = async () => {
    if (!viewModel.selectedApp) {
      return;
    }

    setInstallBusy(true);
    setPageError('');
    setPageNotice('');

    try {
      const response = await requestJson(`/api/admin/apps/${encodeURIComponent(viewModel.selectedApp.id)}/install`, {
        method: 'POST',
      });

      setPageNotice(`${viewModel.selectedApp.title} is queued for installation.`);
      setJobLines([{ line: `queued ${response.job_type || 'run_step'} for ${viewModel.selectedApp.title}` }]);
      setSelectedJob({
        id: response.job_id,
        status: 'pending',
        step_id: viewModel.selectedApp.id,
      });
      await appsState.reload({ silent: true });
    } catch (error) {
      setPageError(error instanceof Error ? error.message : 'Failed to install the selected app.');
      setInstallBusy(false);
    }
  };

  const cancelSelectedJob = async () => {
    if (!selectedJob?.id) {
      return;
    }

    setPageError('');
    try {
      await requestJson(`/api/admin/apps/jobs/${encodeURIComponent(selectedJob.id)}/cancel`, {
        method: 'POST',
      });
      setPageNotice(`Cancellation requested for ${selectedJob.id}.`);
    } catch (error) {
      setPageError(error instanceof Error ? error.message : 'Failed to cancel the current job.');
    }
  };

  const selectedApp = viewModel.selectedApp;
  const selectedState = selectedApp?.app_state || 'planned';
  const canInstall = selectedApp && ['ready', 'failed'].includes(selectedState);
  const isPlaceholder = Boolean(selectedApp?.placeholder);

  return (
    <div className="admin-apps-layout">
      <Panel className="admin-apps-overview">
        <SectionTitle
          eyebrow="Admin"
          title="App installs"
          description="Install cluster apps one at a time and watch the live job output here."
        />
        <div className="admin-apps-cluster">
          <div>
            <span>Active cluster</span>
            <strong>{viewModel.activeCluster?.slug || viewModel.activeCluster?.id || 'No cluster'}</strong>
          </div>
          <div>
            <span>Instance</span>
            <strong>{viewModel.activeCluster?.cluster_instance_id || 'n/a'}</strong>
          </div>
          <div>
            <span>Installed</span>
            <strong>{viewModel.stateCounts.installed}</strong>
          </div>
          <div>
            <span>Ready</span>
            <strong>{viewModel.stateCounts.ready}</strong>
          </div>
        </div>
        <div className="hero-actions">
          <button type="button" className="secondary-button" onClick={() => appsState.reload()} disabled={appsState.refreshing}>
            {appsState.refreshing ? 'Refreshing…' : 'Refresh catalog'}
          </button>
          <button type="button" className="secondary-button" onClick={() => onNavigate('/admin')}>
            Back to admin apps
          </button>
        </div>
        {appsState.error || pageError ? (
          <div className="inline-notice is-danger">
            <strong>Something needs attention.</strong>
            <span>{pageError || appsState.error}</span>
          </div>
        ) : null}
        {pageNotice ? (
          <div className="inline-notice is-accent">
            <strong>{pageNotice}</strong>
            <span>When the job completes, the portal refresh will expose the app to users.</span>
          </div>
        ) : null}
        {viewModel.errors.length > 0 ? (
          <div className="inline-notice is-warning">
            <strong>Catalog warnings</strong>
            <span>{viewModel.errors.join(' | ')}</span>
          </div>
        ) : null}
      </Panel>

      <div className="admin-apps-columns">
        <Panel className="admin-apps-catalog">
          <SectionTitle
            eyebrow="Apps"
            title={viewModel.title}
            description={viewModel.description}
          />
          <div className="user-admin-search admin-app-search">
            <input
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search apps"
            />
          </div>
          <div className="admin-app-grid">
            {viewModel.filteredCards.length === 0 ? (
              <div className="empty-card">
                <strong>No apps match the search</strong>
                <span>Try a different term or clear the filter.</span>
              </div>
            ) : (
              viewModel.filteredCards.map((card) => (
                <AdminAppCard
                  key={card.id}
                  card={card}
                  selected={card.id === selectedApp?.id}
                  onSelect={() => startTransition(() => setSelectedAppId(card.id))}
                />
              ))
            )}
          </div>

          <div className="bundle-list">
            <SectionTitle
              eyebrow="Bundles"
              title="Future install groups"
              description="Metadata for grouped installs is loaded now, but the one-click bundle UI comes later."
            />
            <div className="bundle-grid">
              {viewModel.bundles.length === 0 ? (
                <div className="empty-card">
                  <strong>No bundles defined yet</strong>
                  <span>Add bundle manifests under `categories/apps/bundles/`.</span>
                </div>
              ) : viewModel.bundles.map((bundle) => (
                <article key={bundle.id} className="bundle-card">
                  <strong>{bundle.title}</strong>
                  <span>{bundle.summary}</span>
                  <small>{Array.isArray(bundle.apps) ? bundle.apps.length : 0} app{Array.isArray(bundle.apps) && bundle.apps.length === 1 ? '' : 's'}</small>
                </article>
              ))}
            </div>
          </div>
        </Panel>

        <Panel className="admin-apps-detail">
          {selectedApp ? (
            <>
              <SectionTitle
                eyebrow="Selected app"
                title={selectedApp.title}
                description={selectedApp.description || selectedApp.summary}
              />
              <div className="admin-app-detail-head">
                <AppIcon
                  card={{
                    ...selectedApp,
                    iconUrl: selectedApp.iconUrl || selectedApp.iconArtworkUrl || adminStepIconUrl(selectedApp),
                    iconAlt: `${selectedApp.title} icon`,
                  }}
                  className="admin-app-detail-icon"
                />
                <div>
                  <span className={`status-chip ${statusTone(selectedState)}`}>{statusLabel(selectedState)}</span>
                  {isPlaceholder ? <small>Placeholder app, not installable yet</small> : null}
                </div>
              </div>

              <div className="admin-app-stat-grid">
                <article>
                  <strong>{selectedApp.state?.updated_at ? 'Updated' : 'Ready'}</strong>
                  <span>{selectedApp.state?.updated_at || 'Waiting for the first install'}</span>
                </article>
                <article>
                  <strong>{selectedApp.latest_job?.status || 'none'}</strong>
                  <span>Latest job</span>
                </article>
                <article>
                  <strong>{selectedApp.dependencies.length}</strong>
                  <span>Dependencies</span>
                </article>
              </div>

              <div className="admin-app-dependencies">
                <span>Prerequisites</span>
                <div className="dependency-grid">
                  {selectedApp.dependencies.length === 0 ? (
                    <p className="muted-copy">No dependencies were declared for this app.</p>
                  ) : selectedApp.dependencies.map((dependency) => (
                    <span key={dependency.id} className={`dependency-pill ${dependency.state === 'done' ? 'is-done' : 'is-pending'}`}>
                      {dependency.title}
                    </span>
                  ))}
                </div>
              </div>

              <div className="hero-actions">
                <button
                  type="button"
                  className="primary-button"
                  onClick={installSelectedApp}
                  disabled={!canInstall || installBusy}
                >
                  {installBusy
                    ? 'Installing…'
                    : selectedState === 'failed'
                      ? 'Retry install'
                      : isPlaceholder
                        ? 'Coming soon'
                        : selectedState === 'blocked'
                          ? 'Blocked'
                          : selectedState === 'installed'
                            ? 'Installed'
                            : 'Install app'}
                </button>
                {selectedJob?.id && ['pending', 'running', 'cancel_requested'].includes(selectedJob.status) ? (
                  <button type="button" className="secondary-button" onClick={cancelSelectedJob}>
                    Cancel job
                  </button>
                ) : null}
                <button type="button" className="secondary-button" onClick={() => onNavigate('/')}>
                  Back home
                </button>
              </div>

              <div className="admin-app-progress">
                <SectionTitle eyebrow="Logs" title="Live output" description="This window follows the current install job." />
                <LogViewport
                  lines={jobLines}
                  emptyLabel={selectedJob?.id ? 'Waiting for the first log line...' : 'Start an install to see live logs here.'}
                  viewportRef={logViewportRef}
                  onScroll={handleLogScroll}
                />
              </div>
            </>
          ) : (
            <div className="empty-card">
              <strong>No app selected</strong>
              <span>Pick an application from the catalog to view its install status.</span>
            </div>
          )}
        </Panel>
      </div>
    </div>
  );
}

function UserAdminPage({ config, directoryState, onNavigate }) {
  const [query, setQuery] = useState('');
  const deferredQuery = useDeferredValue(query);
  const [selectedUserId, setSelectedUserId] = useState('');
  const [groupDraft, setGroupDraft] = useState([]);
  const [createDraft, setCreateDraft] = useState({
    username: '',
    name: '',
    email: '',
    groupNames: [],
  });
  const [createBusy, setCreateBusy] = useState(false);
  const [groupBusy, setGroupBusy] = useState(false);
  const [statusBusy, setStatusBusy] = useState(false);
  const [formError, setFormError] = useState('');
  const [temporaryPassword, setTemporaryPassword] = useState(null);

  const viewModel = useMemo(() => buildUserAdminViewModel({
    config,
    users: directoryState.users,
    groups: directoryState.groups,
    query: deferredQuery,
    selectedUserId,
  }), [config, directoryState.groups, directoryState.users, deferredQuery, selectedUserId]);

  useEffect(() => {
    if (viewModel.selectedUser?.id && viewModel.selectedUser.id !== selectedUserId) {
      startTransition(() => {
        setSelectedUserId(viewModel.selectedUser.id);
      });
    }
  }, [selectedUserId, viewModel.selectedUser]);

  useEffect(() => {
    setGroupDraft(viewModel.selectedUser?.groupNames || []);
  }, [viewModel.selectedUser?.groupNames, viewModel.selectedUser?.id]);

  useEffect(() => {
    setCreateDraft((current) => {
      const nextGroupNames = current.groupNames.filter((groupName) => (
        viewModel.groups.some((group) => group.name === groupName)
      ));
      if (nextGroupNames.length === current.groupNames.length) {
        return current;
      }
      return {
        ...current,
        groupNames: nextGroupNames,
      };
    });
  }, [viewModel.groups]);

  const toggleCreateGroup = (groupName) => {
    setCreateDraft((current) => ({
      ...current,
      groupNames: current.groupNames.includes(groupName)
        ? current.groupNames.filter((value) => value !== groupName)
        : [...current.groupNames, groupName].sort((left, right) => left.localeCompare(right)),
    }));
  };

  const toggleSelectedGroup = (groupName) => {
    setGroupDraft((current) => (
      current.includes(groupName)
        ? current.filter((value) => value !== groupName)
        : [...current, groupName].sort((left, right) => left.localeCompare(right))
    ));
  };

  const refreshDirectory = async () => {
    setFormError('');
    await directoryState.reload();
  };

  const submitCreate = async (event) => {
    event.preventDefault();
    setCreateBusy(true);
    setFormError('');

    try {
      const payload = await requestJson('/api/admin/users', {
        method: 'POST',
        body: JSON.stringify(createDraft),
      });

      setTemporaryPassword({
        password: payload.temporaryPassword,
        user: payload.user,
      });
      setCreateDraft({
        username: '',
        name: '',
        email: '',
        groupNames: [],
      });
      startTransition(() => {
        setSelectedUserId(payload?.user?.id || '');
      });
      await directoryState.reload();
    } catch (error) {
      setFormError(error instanceof Error ? error.message : 'Failed to create user.');
    } finally {
      setCreateBusy(false);
    }
  };

  const saveGroups = async () => {
    if (!viewModel.selectedUser) {
      return;
    }

    setGroupBusy(true);
    setFormError('');
    try {
      await requestJson(`/api/admin/users/${encodeURIComponent(viewModel.selectedUser.id)}/groups`, {
        method: 'PUT',
        body: JSON.stringify({ groupNames: groupDraft }),
      });
      await directoryState.reload();
    } catch (error) {
      setFormError(error instanceof Error ? error.message : 'Failed to save groups.');
    } finally {
      setGroupBusy(false);
    }
  };

  const toggleUserStatus = async () => {
    if (!viewModel.selectedUser) {
      return;
    }

    setStatusBusy(true);
    setFormError('');
    try {
      const endpoint = viewModel.selectedUser.isActive ? 'disable' : 'enable';
      await requestJson(`/api/admin/users/${encodeURIComponent(viewModel.selectedUser.id)}/${endpoint}`, {
        method: 'POST',
      });
      await directoryState.reload();
    } catch (error) {
      setFormError(error instanceof Error ? error.message : 'Failed to update account status.');
    } finally {
      setStatusBusy(false);
    }
  };

  if (directoryState.loading) {
    return (
      <Panel>
        <SectionTitle
          eyebrow={config?.userAdmin?.eyebrow || 'Admin'}
          title={config?.userAdmin?.title || 'Gebruikers en groepen'}
          description="Loading the current Authentik directory."
        />
        <p className="muted-copy">Twinbox is reading users and groups from Authentik.</p>
      </Panel>
    );
  }

  return (
    <div className="user-admin-layout">
      <Panel className="user-admin-overview">
        <SectionTitle
          eyebrow={config?.userAdmin?.eyebrow || 'Admin'}
          title={viewModel.title}
          description={viewModel.description}
        />
        <div className="user-admin-stats">
          <article>
            <strong>{viewModel.stats.totalUsers}</strong>
            <span>Total users</span>
          </article>
          <article>
            <strong>{viewModel.stats.activeUsers}</strong>
            <span>Active</span>
          </article>
          <article>
            <strong>{viewModel.stats.inactiveUsers}</strong>
            <span>Disabled</span>
          </article>
          <article>
            <strong>{viewModel.stats.manageableGroups}</strong>
            <span>Manageable groups</span>
          </article>
        </div>
        <div className="hero-actions">
          <button type="button" className="secondary-button" onClick={refreshDirectory} disabled={directoryState.refreshing}>
            {directoryState.refreshing ? 'Refreshing…' : 'Refresh'}
          </button>
          <button type="button" className="secondary-button" onClick={() => onNavigate('/admin')}>
            Back to admin apps
          </button>
        </div>
        {directoryState.error || formError ? (
          <div className="inline-notice is-danger">
            <strong>Something needs attention.</strong>
            <span>{formError || directoryState.error}</span>
          </div>
        ) : null}
        {temporaryPassword ? (
          <div className="inline-notice is-accent">
            <strong>Temporary password for {temporaryPassword.user?.name || temporaryPassword.user?.username}</strong>
            <code>{temporaryPassword.password}</code>
            <span>Show this once to the user. The portal does not keep a readable copy.</span>
            <button type="button" className="secondary-button" onClick={() => setTemporaryPassword(null)}>
              Hide password
            </button>
          </div>
        ) : null}
      </Panel>

      <div className="user-admin-columns">
        <div className="stack">
          <Panel>
            <SectionTitle
              eyebrow="Create"
              title="Add user"
              description="Create a normal Authentik user and optionally place them in the approved business groups."
            />
            <form className="user-admin-form" onSubmit={submitCreate}>
              <label>
                <span>Full name</span>
                <input
                  type="text"
                  value={createDraft.name}
                  onChange={(event) => setCreateDraft((current) => ({ ...current, name: event.target.value }))}
                  placeholder="Jane Example"
                  required
                />
              </label>
              <label>
                <span>Username</span>
                <input
                  type="text"
                  value={createDraft.username}
                  onChange={(event) => setCreateDraft((current) => ({ ...current, username: event.target.value }))}
                  placeholder="jane"
                  required
                />
              </label>
              <label>
                <span>Email address</span>
                <input
                  type="email"
                  value={createDraft.email}
                  onChange={(event) => setCreateDraft((current) => ({ ...current, email: event.target.value }))}
                  placeholder="jane@example.com"
                />
              </label>
              <div className="user-admin-group-picker">
                <span>Approved groups</span>
                {viewModel.emptyState ? (
                  <p className="muted-copy">{viewModel.emptyState.description}</p>
                ) : (
                  <div className="user-admin-checkboxes">
                    {viewModel.groups.map((group) => (
                      <label key={group.id} className="checkbox-card">
                        <input
                          type="checkbox"
                          checked={createDraft.groupNames.includes(group.name)}
                          onChange={() => toggleCreateGroup(group.name)}
                        />
                        <span>
                          <strong>{group.label}</strong>
                          {group.description ? <small>{group.description}</small> : null}
                        </span>
                      </label>
                    ))}
                  </div>
                )}
              </div>
              <div className="hero-actions">
                <button type="submit" className="primary-button" disabled={createBusy}>
                  {createBusy ? 'Creating…' : 'Create user'}
                </button>
                <span className="muted-copy">Twinbox will generate a temporary password and show it once.</span>
              </div>
            </form>
          </Panel>

          <Panel>
            <SectionTitle
              eyebrow="Directory"
              title="Users"
              description="Search by name, username, email, or visible group."
            />
            <div className="user-admin-search">
              <input
                type="search"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Search users"
              />
            </div>
            <div className="user-admin-list">
              {viewModel.filteredUsers.length === 0 ? (
                <div className="empty-card">
                  <strong>No matching users</strong>
                  <span>Adjust the search or create a new user.</span>
                </div>
              ) : (
                viewModel.filteredUsers.map((user) => (
                  <button
                    key={user.id}
                    type="button"
                    className={`user-list-row ${user.id === viewModel.selectedUser?.id ? 'is-selected' : ''}`}
                    onClick={() => startTransition(() => setSelectedUserId(user.id))}
                  >
                    <span className="user-list-copy">
                      <strong>{user.name}</strong>
                      <span>{user.username}{user.email ? ` · ${user.email}` : ''}</span>
                    </span>
                    <span className="user-list-meta">
                      <span className={`status-chip ${user.isActive ? 'is-live' : ''}`}>
                        {user.isActive ? 'active' : 'disabled'}
                      </span>
                    </span>
                  </button>
                ))
              )}
            </div>
          </Panel>
        </div>

        <Panel className="user-admin-detail">
          {viewModel.selectedUser ? (
            <>
              <SectionTitle
                eyebrow="Selected user"
                title={viewModel.selectedUser.name}
                description="Review the current account status and adjust only the approved group memberships."
              />
              <div className="user-admin-profile">
                <div>
                  <span>Username</span>
                  <strong>{viewModel.selectedUser.username}</strong>
                </div>
                <div>
                  <span>Email</span>
                  <strong>{viewModel.selectedUser.email || 'No email set'}</strong>
                </div>
                <div>
                  <span>Status</span>
                  <strong>{viewModel.selectedUser.isActive ? 'Active' : 'Disabled'}</strong>
                </div>
                <div>
                  <span>Hidden memberships</span>
                  <strong>{viewModel.selectedUser.hiddenGroupCount || 0}</strong>
                </div>
              </div>

              {viewModel.emptyState ? (
                <div className="empty-card">
                  <strong>{viewModel.emptyState.title}</strong>
                  <span>{viewModel.emptyState.description}</span>
                </div>
              ) : (
                <>
                  <div className="user-admin-group-picker">
                    <span>Visible group memberships</span>
                    <div className="user-admin-checkboxes">
                      {viewModel.groups.map((group) => (
                        <label key={group.id} className="checkbox-card">
                          <input
                            type="checkbox"
                            checked={groupDraft.includes(group.name)}
                            onChange={() => toggleSelectedGroup(group.name)}
                          />
                          <span>
                            <strong>{group.label}</strong>
                            {group.description ? <small>{group.description}</small> : null}
                          </span>
                        </label>
                      ))}
                    </div>
                  </div>
                  <div className="hero-actions">
                    <button type="button" className="primary-button" onClick={saveGroups} disabled={groupBusy}>
                      {groupBusy ? 'Saving…' : 'Save groups'}
                    </button>
                    <span className="muted-copy">Only the approved groups above are editable here.</span>
                  </div>
                </>
              )}

              <div className="hero-actions user-admin-status-actions">
                <button type="button" className="secondary-button" onClick={toggleUserStatus} disabled={statusBusy}>
                  {statusBusy
                    ? 'Updating…'
                    : viewModel.selectedUser.isActive
                      ? 'Disable account'
                      : 'Reactivate account'}
                </button>
                <span className="muted-copy">
                  Disabling keeps the account history intact and blocks new sign-ins.
                </span>
              </div>
            </>
          ) : (
            <div className="empty-card">
              <strong>No user selected</strong>
              <span>Pick a user from the directory to review details.</span>
            </div>
          )}
        </Panel>
      </div>
    </div>
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
  const userAdminEnabled = Boolean(sessionState.session?.isAdmin) && route === '/admin/users';
  const adminAppsEnabled = Boolean(sessionState.session?.isAdmin) && route === '/admin/apps';
  const userAdminState = useUserAdminData(userAdminEnabled);
  const adminAppsState = useAdminAppsData(adminAppsEnabled);
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
        {route === '/admin/apps' && isAdmin ? <AdminAppsPage onNavigate={navigate} adminAppsState={adminAppsState} /> : null}
        {route === '/admin/users' && isAdmin ? (
          <UserAdminPage config={config} directoryState={userAdminState} onNavigate={navigate} />
        ) : null}
        {route === '/admin' && !isAdmin ? (
          <Panel>
            <SectionTitle eyebrow="Access denied" title="Admins only" description="This part of Twinbox is reserved for the admins group." />
            <button type="button" className="secondary-button" onClick={() => navigate('/')}>Back home</button>
          </Panel>
        ) : null}
        {route === '/admin/users' && !isAdmin ? (
          <Panel>
            <SectionTitle eyebrow="Access denied" title="Admins only" description="User administration is only available to the admins group." />
            <button type="button" className="secondary-button" onClick={() => navigate('/')}>Back home</button>
          </Panel>
        ) : null}
        {route === '/admin/apps' && !isAdmin ? (
          <Panel>
            <SectionTitle eyebrow="Access denied" title="Admins only" description="App installs are only available to the admins group." />
            <button type="button" className="secondary-button" onClick={() => navigate('/')}>Back home</button>
          </Panel>
        ) : null}
      </section>
    </main>
  );
}

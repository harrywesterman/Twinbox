import { startTransition, useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from 'react';

import { buildAdminAppsViewModel } from './admin-apps-model.js';
import {
  buildAdminAppInstallPath,
  buildBundleInstallQueue,
  buildBundleInstallSummary,
  getAdminAppInstallButtonState,
  isAdminAppInstallEnabled,
  parseAdminAppInstallPath,
  resolveAdminCardIconUrl,
} from './admin-apps-install.js';
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

function buildAdminInstallRoute(kind, id) {
  return buildAdminAppInstallPath(kind, id);
}

function buildAdminIconCard(card = {}) {
  if (!card) {
    return {
      title: 'App',
      iconUrl: '',
      iconAlt: 'App icon',
      iconText: 'AP',
    };
  }

  return {
    ...card,
    iconUrl: resolveAdminCardIconUrl(card),
    iconAlt: card.iconAlt || `${card.title || 'App'} icon`,
  };
}

function buildAdminBundleIconCard(bundle = {}) {
  const bundleCards = Array.isArray(bundle?.cards) ? bundle.cards : [];
  const sourceCard = bundleCards.find((entry) => Boolean(resolveAdminCardIconUrl(entry))) || bundleCards[0] || {};
  const title = bundle?.title || sourceCard?.title || 'Bundle';

  return {
    ...sourceCard,
    title,
    iconUrl: bundle?.iconUrl || resolveAdminCardIconUrl(sourceCard),
    iconAlt: bundle?.iconAlt || `${title} icon`,
    iconText: sourceCard?.iconText || String(title).slice(0, 2).toUpperCase(),
  };
}

function buildBundleInstallButtonState(bundleCards = []) {
  const summary = buildBundleInstallSummary(bundleCards);
  if (summary.state === 'ready') {
    return {
      summary,
      enabled: true,
      label: 'Install',
    };
  }

  if (summary.state === 'installing') {
    return {
      summary,
      enabled: false,
      label: 'Installing',
    };
  }

  return {
    summary,
    enabled: false,
    label: 'Unavailable',
  };
}

function AdminInstallTile({
  iconCard,
  itemTitle,
  buttonLabel = 'Install',
  disabled = false,
  onInstall,
}) {
  return (
    <article className={`admin-install-tile ${disabled ? 'is-disabled' : ''}`} title={itemTitle}>
      <div className="admin-install-tile-media" aria-hidden="true">
        <AppIcon card={iconCard} className="admin-install-tile-icon" />
      </div>
      <button
        type="button"
        className="primary-button admin-install-tile-button"
        onClick={onInstall}
        disabled={disabled}
        aria-label={`${buttonLabel} ${itemTitle}`}
        title={`${buttonLabel} ${itemTitle}`}
      >
        {buttonLabel}
      </button>
    </article>
  );
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

function AuthRedirectScreen({ brand }) {
  return (
    <main className="loading-screen">
      <div className="loading-card">
        <span className="brand-mark" />
        <p className="eyebrow">{brand}</p>
        <h1>Redirecting to Authentik</h1>
        <p>Preparing secure sign-in.</p>
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

function statusTone(state) {
  switch (state) {
    case 'installed':
    case 'succeeded':
    case 'done':
      return 'is-live';
    case 'ready':
      return 'is-ok';
    case 'pending':
    case 'running':
    case 'cancel_requested':
      return 'is-warning';
    case 'installing':
      return 'is-warning';
    case 'blocked':
    case 'planned':
      return 'is-neutral';
    case 'failed':
    case 'canceled':
      return 'is-bad';
    default:
      return 'is-neutral';
  }
}

function statusLabel(state) {
  switch (state) {
    case 'installed':
    case 'succeeded':
    case 'done':
      return 'installed';
    case 'ready':
      return 'ready';
    case 'pending':
      return 'queued';
    case 'running':
      return 'running';
    case 'cancel_requested':
      return 'stopping';
    case 'installing':
      return 'installing';
    case 'blocked':
      return 'blocked';
    case 'planned':
      return 'coming soon';
    case 'failed':
      return 'failed';
    case 'canceled':
      return 'stopped';
    default:
      return 'planned';
  }
}

function LogViewport({ lines = [], emptyLabel = 'Waiting for output...', viewportRef, onScroll, className = '' }) {
  return (
    <div className={`admin-log-viewport ${className}`.trim()} ref={viewportRef} onScroll={onScroll}>
      {lines.length === 0 ? (
        <p className="muted-copy">{emptyLabel}</p>
      ) : (
        <pre className="admin-log-output">{lines.map((line) => (typeof line === 'string' ? line : line.line)).join('\n')}</pre>
      )}
    </div>
  );
}
function AdminAppsPage({ onNavigate, adminAppsState, installTarget }) {
  const appsState = adminAppsState || useAdminAppsData(true);
  const [activeTab, setActiveTab] = useState(() => (installTarget?.kind === 'bundle' ? 'bundles' : 'apps'));

  const viewModel = useMemo(() => buildAdminAppsViewModel({
    catalog: appsState.catalog,
    query: '',
    selectedAppId: '',
  }), [appsState.catalog]);

  useEffect(() => {
    if (installTarget?.kind === 'bundle') {
      setActiveTab('bundles');
      return;
    }
    if (installTarget?.kind === 'app') {
      setActiveTab('apps');
    }
  }, [installTarget?.kind]);

  const openInstall = (kind, id) => {
    if (!kind || !id) {
      return;
    }
    onNavigate(buildAdminInstallRoute(kind, id));
  };

  if (appsState.loading && !appsState.catalog) {
    return (
      <Panel>
        <SectionTitle
          eyebrow="Admin"
          title="App installs"
          description="Loading the app catalog."
        />
        <p className="muted-copy">Twinbox is building the install catalog from the current cluster state.</p>
      </Panel>
    );
  }

  return (
    <div className="admin-apps-layout">
      <Panel className="admin-apps-shell">
        <div className="admin-apps-shell-head">
          <SectionTitle
            eyebrow="Admin"
            title="App installs"
            description="Choose an icon and run installs from a clean in-page installer."
          />
          <div className="hero-actions admin-apps-shell-actions">
            <button type="button" className="secondary-button" onClick={() => appsState.reload()} disabled={appsState.refreshing}>
              {appsState.refreshing ? 'Refreshing…' : 'Refresh catalog'}
            </button>
            <button type="button" className="secondary-button" onClick={() => onNavigate('/')}>
              Back home
            </button>
          </div>
        </div>

        <div className="admin-apps-tabs" role="tablist" aria-label="Install catalog">
          <button
            type="button"
            role="tab"
            aria-selected={activeTab === 'apps'}
            className={activeTab === 'apps' ? 'is-active' : ''}
            onClick={() => setActiveTab('apps')}
          >
            Apps
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={activeTab === 'bundles'}
            className={activeTab === 'bundles' ? 'is-active' : ''}
            onClick={() => setActiveTab('bundles')}
          >
            Bundles
          </button>
        </div>

        {appsState.error ? (
          <div className="inline-notice is-danger">
            <strong>Something needs attention.</strong>
            <span>{appsState.error}</span>
          </div>
        ) : null}
        {viewModel.errors.length > 0 ? (
          <div className="inline-notice is-warning">
            <strong>Catalog warnings</strong>
            <span>{viewModel.errors.join(' | ')}</span>
          </div>
        ) : null}

        {activeTab === 'apps' ? (
          <div role="tabpanel" aria-label="Apps install grid" className="admin-install-grid">
            {viewModel.cards.length === 0 ? (
              <div className="empty-card">
                <strong>No installable apps yet</strong>
                <span>Refresh the catalog after adding new app definitions.</span>
              </div>
            ) : (
              viewModel.cards.map((card) => {
                const buttonState = getAdminAppInstallButtonState(card);
                return (
                  <AdminInstallTile
                    key={card.id}
                    iconCard={buildAdminIconCard(card)}
                    itemTitle={card.title || card.id}
                    buttonLabel={buttonState.label}
                    disabled={!buttonState.enabled}
                    onInstall={() => openInstall('app', card.id)}
                  />
                );
              })
            )}
          </div>
        ) : (
          <div role="tabpanel" aria-label="Bundle install grid" className="admin-install-grid">
            {viewModel.bundles.length === 0 ? (
              <div className="empty-card">
                <strong>No bundles available</strong>
                <span>Add bundle definitions to offer grouped installs.</span>
              </div>
            ) : (
              viewModel.bundles.map((bundle) => {
                const buttonState = buildBundleInstallButtonState(bundle.cards || []);
                return (
                  <AdminInstallTile
                    key={bundle.id}
                    iconCard={buildAdminBundleIconCard(bundle)}
                    itemTitle={bundle.title || bundle.id}
                    buttonLabel={buttonState.label}
                    disabled={!buttonState.enabled}
                    onInstall={() => openInstall('bundle', bundle.id)}
                  />
                );
              })
            )}
          </div>
        )}
      </Panel>

      {installTarget ? (
        <AdminAppInstallModal
          onNavigate={onNavigate}
          adminAppsState={appsState}
          installTarget={installTarget}
        />
      ) : null}
    </div>
  );
}

function AdminAppInstallModal({ onNavigate, adminAppsState, installTarget }) {
  const appsState = adminAppsState || useAdminAppsData(true);
  const logViewportRef = useRef(null);
  const autoScrollLogsRef = useRef(true);
  const [pageError, setPageError] = useState('');
  const [pageNotice, setPageNotice] = useState('');
  const [currentJob, setCurrentJob] = useState(null);
  const [jobLines, setJobLines] = useState([]);
  const [running, setRunning] = useState(false);
  const [activeAppId, setActiveAppId] = useState('');

  const viewModel = useMemo(() => buildAdminAppsViewModel({
    catalog: appsState.catalog,
    query: '',
    selectedAppId: '',
  }), [appsState.catalog]);

  const cardsById = useMemo(() => new Map(viewModel.cards.map((card) => [card.id, card])), [viewModel.cards]);
  const targetCard = installTarget?.kind === 'app' ? cardsById.get(installTarget.id) || null : null;
  const targetBundle = installTarget?.kind === 'bundle'
    ? viewModel.bundles.find((bundle) => bundle.id === installTarget.id) || null
    : null;
  const bundleQueue = useMemo(() => (
    targetBundle ? buildBundleInstallQueue(targetBundle, cardsById) : []
  ), [cardsById, targetBundle]);
  const installQueue = installTarget?.kind === 'bundle'
    ? bundleQueue
    : targetCard
      ? [targetCard]
      : [];
  const activeCard = cardsById.get(activeAppId) || installQueue[0] || null;
  const activeState = activeCard?.app_state || targetBundle?.app_state || targetCard?.app_state || 'planned';
  const installSummary = targetBundle
    ? buildBundleInstallSummary(targetBundle.cards || [])
    : null;
  const canInstall = Boolean(installQueue.length) && !running && (installTarget?.kind === 'bundle'
    ? installSummary?.state === 'ready'
    : isAdminAppInstallEnabled(targetCard));
  const title = targetBundle?.title || targetCard?.title || 'Install';
  const targetIconCard = installTarget?.kind === 'bundle'
    ? buildAdminBundleIconCard(targetBundle)
    : buildAdminIconCard(targetCard);

  if (appsState.loading && !appsState.catalog) {
    return (
      <div className="admin-install-modal-backdrop">
        <Panel className="admin-install-modal" role="dialog" aria-modal="true" aria-labelledby="admin-install-modal-title">
          <div className="admin-install-modal-head">
            <div className="admin-install-modal-copy">
              <p className="eyebrow">Install</p>
              <h2 id="admin-install-modal-title">Loading installer</h2>
            </div>
          </div>
          <p className="muted-copy">Twinbox is reading the app catalog before opening the installer.</p>
          <div className="hero-actions admin-install-modal-actions">
            <button type="button" className="secondary-button" onClick={() => onNavigate('/admin/apps')}>
              Back
            </button>
          </div>
        </Panel>
      </div>
    );
  }

  async function pollJob(jobId) {
    let latestJob = null;

    while (true) {
      const [jobPayload, logsPayload] = await Promise.all([
        requestJson(`/api/admin/apps/jobs/${encodeURIComponent(jobId)}`),
        requestJson(`/api/admin/apps/jobs/${encodeURIComponent(jobId)}/logs`),
      ]);

      latestJob = jobPayload;
      setCurrentJob(jobPayload);
      setJobLines(Array.isArray(logsPayload?.lines) ? logsPayload.lines : []);

      if (!['pending', 'running', 'cancel_requested'].includes(jobPayload.status)) {
        break;
      }

      await sleep(2000);
    }

    return latestJob;
  }

  useEffect(() => {
    const viewport = logViewportRef.current;
    if (!viewport || !currentJob?.id || !autoScrollLogsRef.current) {
      return;
    }

    viewport.scrollTop = viewport.scrollHeight;
  }, [currentJob?.id, jobLines]);

  useEffect(() => {
    if (currentJob?.id) {
      return undefined;
    }

    const resumeCard = installTarget?.kind === 'bundle'
      ? targetBundle?.cards.find((card) => card?.latest_job?.id && ['pending', 'running', 'cancel_requested'].includes(card.latest_job.status))
      : targetCard?.latest_job?.id && ['pending', 'running', 'cancel_requested'].includes(targetCard.latest_job.status)
        ? targetCard
        : null;

    if (!resumeCard?.latest_job?.id) {
      return undefined;
    }

    let cancelled = false;
    setActiveAppId(resumeCard.id);
    setCurrentJob(resumeCard.latest_job);
    setJobLines([]);
    setRunning(true);

    (async () => {
      try {
        const nextJob = await pollJob(resumeCard.latest_job.id);
        if (!cancelled && nextJob && nextJob.status === 'failed') {
          setPageError(nextJob.error || `${resumeCard.title} failed`);
        }
        if (!cancelled && nextJob && !['pending', 'running', 'cancel_requested'].includes(nextJob.status)) {
          setRunning(false);
          await appsState.reload({ silent: true });
        }
      } catch (error) {
        if (!cancelled) {
          setPageError(error instanceof Error ? error.message : 'Failed to load job progress.');
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [appsState, currentJob?.id, installQueue, installTarget, targetBundle, targetCard]);

  const handleLogScroll = () => {
    const viewport = logViewportRef.current;
    if (!viewport) {
      return;
    }

    const distanceFromBottom = viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
    autoScrollLogsRef.current = distanceFromBottom < 40;
  };

  const runInstall = async () => {
    if (!installQueue.length || running) {
      return;
    }

    setRunning(true);
    setPageError('');
    setPageNotice('');
    setJobLines([]);
    let stopped = false;

    try {
      for (let index = 0; index < installQueue.length; index += 1) {
        const card = installQueue[index];
        if (!card) {
          continue;
        }

        setActiveAppId(card.id);

        if (!isAdminAppInstallEnabled(card) && installTarget?.kind !== 'bundle') {
          throw new Error(`${card.title} is not installable yet`);
        }

        setPageNotice(`Installing ${card.title}${installTarget?.kind === 'bundle' ? ` (${index + 1}/${installQueue.length})` : ''}`);
        const response = await requestJson(`/api/admin/apps/${encodeURIComponent(card.id)}/install`, {
          method: 'POST',
        });

        const initialJob = {
          id: response.job_id,
          status: 'pending',
          step_id: card.id,
        };
        setCurrentJob(initialJob);
        setJobLines([{ line: `queued ${response.job_type || 'run_step'} for ${card.title}` }]);

        const terminalJob = await pollJob(response.job_id);
        if (terminalJob?.status === 'failed') {
          throw new Error(terminalJob.error || `${card.title} failed`);
        }

        if (terminalJob?.status === 'canceled') {
          setPageNotice(`${card.title} was stopped.`);
          stopped = true;
          break;
        }

        await appsState.reload({ silent: true });
      }

      if (!stopped) {
        setPageNotice(targetBundle ? `${targetBundle.title} finished installing.` : `${title} completed successfully.`);
      }
    } catch (error) {
      setPageError(error instanceof Error ? error.message : 'Failed to install.');
    } finally {
      setRunning(false);
    }
  };

  if (appsState.error) {
    return (
      <div className="admin-install-modal-backdrop">
        <Panel className="admin-install-modal" role="dialog" aria-modal="true" aria-labelledby="admin-install-modal-title">
          <div className="admin-install-modal-head">
            <div className="admin-install-modal-copy">
              <p className="eyebrow">Install</p>
              <h2 id="admin-install-modal-title">Catalog unavailable</h2>
            </div>
          </div>
          <div className="inline-notice is-danger">
            <strong>Catalog unavailable</strong>
            <span>{appsState.error}</span>
          </div>
          <div className="hero-actions admin-install-modal-actions">
            <button type="button" className="secondary-button" onClick={() => onNavigate('/admin/apps')}>
              Back
            </button>
          </div>
        </Panel>
      </div>
    );
  }

  if (!targetCard && !targetBundle) {
    return (
      <div className="admin-install-modal-backdrop">
        <Panel className="admin-install-modal" role="dialog" aria-modal="true" aria-labelledby="admin-install-modal-title">
          <div className="admin-install-modal-head">
            <div className="admin-install-modal-copy">
              <p className="eyebrow">Install</p>
              <h2 id="admin-install-modal-title">Install target not found</h2>
            </div>
          </div>
          <p className="muted-copy">This install target is not available in the current catalog.</p>
          <div className="hero-actions admin-install-modal-actions">
            <button type="button" className="secondary-button" onClick={() => onNavigate('/admin/apps')}>
              Back
            </button>
          </div>
        </Panel>
      </div>
    );
  }

  return (
    <div className="admin-install-modal-backdrop">
      <Panel className="admin-install-modal" role="dialog" aria-modal="true" aria-labelledby="admin-install-modal-title">
        <div className="admin-install-modal-head">
          <div className="admin-install-modal-target">
            <AppIcon card={targetIconCard} className="admin-install-modal-icon" />
            <div className="admin-install-modal-copy">
              <p className="eyebrow">{installTarget?.kind === 'bundle' ? 'Bundle install' : 'App install'}</p>
              <h2 id="admin-install-modal-title">{title}</h2>
            </div>
          </div>
          <span className={`status-chip ${statusTone(currentJob?.status || activeState)}`}>
            {statusLabel(currentJob?.status || activeState)}
          </span>
        </div>

        {installTarget?.kind === 'bundle' && installSummary ? (
          <p className="muted-copy">{installSummary.label}</p>
        ) : (
          <p className="muted-copy">Press Install to start the live install output.</p>
        )}

        <LogViewport
          className="admin-install-log-viewport admin-install-modal-log"
          viewportRef={logViewportRef}
          onScroll={handleLogScroll}
          lines={jobLines}
          emptyLabel={running ? 'Waiting for the first log line…' : 'Press Install to start the script output.'}
        />

        {pageError ? (
          <div className="inline-notice is-danger">
            <strong>Something needs attention.</strong>
            <span>{pageError}</span>
          </div>
        ) : null}
        {pageNotice ? (
          <div className="inline-notice is-accent">
            <strong>{pageNotice}</strong>
            <span>The install log remains visible here for this session.</span>
          </div>
        ) : null}

        <div className="hero-actions admin-install-modal-actions">
          <button
            type="button"
            className="primary-button"
            onClick={runInstall}
            disabled={!canInstall}
          >
            {running ? 'Install…' : 'Install'}
          </button>
          <button type="button" className="secondary-button" onClick={() => onNavigate('/admin/apps')}>
            Back
          </button>
        </div>
      </Panel>
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
          <button type="button" className="secondary-button" onClick={() => onNavigate('/admin/apps')}>
            Back to app installs
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
  const adminAppsEnabled = Boolean(sessionState.session?.isAdmin) && route.startsWith('/admin/apps');
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
  const adminRedirectUrl = config?.settings?.authentikAdminUrl || '';

  const currentApp = useMemo(() => {
    if (!config?.apps) {
      return null;
    }
    const slug = route.startsWith('/apps/') ? route.split('/').pop() : '';
    return config.apps.find((card) => card.slug === slug) || null;
  }, [config, route]);
  const adminInstallTarget = useMemo(() => parseAdminAppInstallPath(route), [route]);

  const logout = () => {
    window.location.href = '/auth/logout';
  };

  useEffect(() => {
    if (!sessionState.loading && !session) {
      window.location.replace(`/auth/login?returnTo=${encodeURIComponent(route || '/')}`);
    }
  }, [route, session, sessionState.loading]);

  useEffect(() => {
    if (route === '/admin' && adminRedirectUrl) {
      window.location.replace(adminRedirectUrl);
    }
  }, [adminRedirectUrl, route]);

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

  if (route === '/admin') {
    return null;
  }

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
    return <AuthRedirectScreen brand="Twinbox" />;
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
        {route.startsWith('/admin/apps') && isAdmin ? (
          <AdminAppsPage onNavigate={navigate} adminAppsState={adminAppsState} installTarget={adminInstallTarget} />
        ) : null}
        {route === '/admin/users' && isAdmin ? (
          <UserAdminPage config={config} directoryState={userAdminState} onNavigate={navigate} />
        ) : null}
        {route === '/admin/users' && !isAdmin ? (
          <Panel>
            <SectionTitle eyebrow="Access denied" title="Admins only" description="User administration is only available to the admins group." />
            <button type="button" className="secondary-button" onClick={() => navigate('/')}>Back home</button>
          </Panel>
        ) : null}
        {route.startsWith('/admin/apps') && !isAdmin ? (
          <Panel>
            <SectionTitle eyebrow="Access denied" title="Admins only" description="App installs are only available to the admins group." />
            <button type="button" className="secondary-button" onClick={() => navigate('/')}>Back home</button>
          </Panel>
        ) : null}
      </section>
    </main>
  );
}

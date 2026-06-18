import { onMount, preserveScrollForPage } from '../../../helpers';
import { PODKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT } from '../../../constants';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { showToast } from '../../../helpers/showToast';
import {
  renderRotateCcwIcon24,
  renderSearchIcon24,
  renderXIcon24,
} from '../../../icons';
import { renderButton } from '../../../partials';
import { PodkopShellMethods } from '../../methods';
import { logger, store, StoreType } from '../../services';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import { Podkop } from '../../types';

type UpdatesActionKey = keyof StoreType['updatesActions'];
type UpdateStatus = StoreType['updatesChecks'][Podkop.ComponentName]['status'];

interface ComponentActionButton {
  key: UpdatesActionKey;
  text: string;
  icon: () => SVGSVGElement;
  component: Podkop.ComponentName;
  action: Podkop.ComponentAction;
}

interface ComponentCard {
  title: string;
  version: string;
  releaseUrl?: string;
  description?: string;
  projectUrl?: string;
  tag?: {
    label: string;
    kind: 'neutral' | 'success' | 'warning';
  };
  actions: ComponentActionButton[];
}

interface HubModuleData {
  id?: string;
  name?: string;
  description?: string;
  category?: string;
  author?: string;
  project_url?: string;
  component?: string;
  repo?: string;
  version?: string;
  install_script?: string;
  update_script?: string;
  remove_script?: string;
  installed?: boolean;
  installed_version?: string;
}

const HUB_BASE_URL =
  'https://raw.githubusercontent.com/titovcode/krot/main/hub';

const hubModules: Map<string, HubModuleData> = new Map();

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

async function fetchWithRetry(url: string, retries = 2): Promise<Response | null> {
  for (let i = 0; i <= retries; i++) {
    try {
      const res = await fetch(url);
      if (res.ok) return res;
    } catch {
      // retry
    }
  }
  return null;
}

async function loadHubModulesFromBrowser(): Promise<boolean> {
  try {
    const ts = Date.now();
    const res = await fetchWithRetry(`${HUB_BASE_URL}/index.json?v=${ts}`);
    if (!res) return false;

    const index = (await res.json()) as { modules?: string[] };
    const ids = index.modules ?? [];
    if (!ids.length) return false;

    await Promise.all(
      ids.map(async (id: string) => {
        try {
          const modRes = await fetchWithRetry(`${HUB_BASE_URL}/${id}/module.json?v=${ts}`);
          if (modRes) {
            const data = (await modRes.json()) as HubModuleData;
            hubModules.set(data.component ?? id, data);
          }
        } catch {
          // skip individual module
        }
      }),
    );

    return hubModules.size > 0;
  } catch {
    return false;
  }
}

async function loadHubModulesFromBackend(): Promise<boolean> {
  try {
    const response = await PodkopShellMethods.hubGetModules();
    if (!response.success || !response.data) return false;

    const raw = response.data;
    const modules: HubModuleData[] = Array.isArray(raw)
      ? (raw as HubModuleData[])
      : typeof raw === 'string'
        ? (JSON.parse(raw) as HubModuleData[])
        : [];

    for (const data of modules) {
      if (data) hubModules.set(data.component ?? data.id ?? '', data);
    }

    return hubModules.size > 0;
  } catch {
    return false;
  }
}

async function loadHubModules(): Promise<void> {
  hubModules.clear();

  const RETRIES = 4;
  const RETRY_DELAY_MS = 15_000;

  for (let attempt = 0; attempt < RETRIES; attempt++) {
    if (attempt > 0) {
      await sleep(RETRY_DELAY_MS);
      // Stop retrying if user left the tab
      if (!updatesMounted) return;
    }

    const browserOk = await loadHubModulesFromBrowser();
    if (browserOk) break;

    // Wait for systemInfo before backend RPC — avoids two heavy krot processes competing
    for (let w = 0; w < 30 && !store.get().diagnosticsSystemInfo.loaded; w++) {
      if (!updatesMounted) return;
      await sleep(500);
    }
    if (!updatesMounted) return;

    const backendOk = await loadHubModulesFromBackend();
    if (backendOk) break;
  }

  // Mark installed modules
  const systemInfo = store.get().diagnosticsSystemInfo;
  const installedModules: Record<string, { installed: boolean; version: string }> = {};

  hubModules.forEach((data, key) => {
    const component = data.component ?? data.id ?? key;
    let installed = false;
    let version = '';

    // Prefer the flag the backend injected via `hub_get_modules` — it knows
    // about every module that declares `component` (zapret, byedpi, adguard, …).
    // Fall back to the diagnosticsSystemInfo mirror only when backend didn't set it.
    if (typeof data.installed === 'boolean') {
      installed = data.installed;
      version = data.installed_version ?? '';
    } else if (component === 'zapret') {
      installed = Boolean(systemInfo.zapret_installed);
      version = systemInfo.zapret_version;
    } else if (component === 'byedpi') {
      installed = Boolean(systemInfo.byedpi_installed);
      version = systemInfo.byedpi_version;
    } else if (component === 'adguard') {
      installed = Boolean(systemInfo.adguard_installed);
      version = systemInfo.adguard_version;
    }

    installedModules[key] = { installed, version };
  });

  const finalEntries = Object.fromEntries(
    Array.from(hubModules.entries()).map(([key, data]) => [
      key,
      {
        id: data.id ?? key,
        name: data.name ?? key,
        description: data.description ?? '',
        category: data.category ?? '',
        author: data.author ?? '',
        project_url: data.project_url ?? '',
        component: data.component ?? key,
        repo: data.repo ?? 'titovcode/krot',
        version: data.version ?? '',
        install_script: data.install_script ?? `hub/${data.id ?? key}/install.sh`,
        update_script: data.update_script,
        remove_script: data.remove_script,
        installed: installedModules[key]?.installed ?? false,
        installed_version: installedModules[key]?.version ?? '',
      },
    ]),
  );
  store.set({ hubModules: finalEntries });

  renderUpdatesComponents();
}

let updatesLifecycleRegistered = false;
let updatesControllerInitialized = false;
let updatesMounted = false;

function isNotInstalled(version: string | undefined) {
  return !version || version === 'not installed';
}

function getCheckTag(component: Podkop.ComponentName): ComponentCard['tag'] {
  const status = store.get().updatesChecks[component].status;

  if (!status) {
    return undefined;
  }

  if (status === 'latest') {
    return { label: _('Latest'), kind: 'success' };
  }

  if (status === 'outdated') {
    return { label: _('Outdated'), kind: 'warning' };
  }

  return { label: _('Dev'), kind: 'neutral' };
}

function shouldShowInstallAfterCheck(component: Podkop.ComponentName) {
  const status = store.get().updatesChecks[component].status;

  return status === 'outdated';
}

function getInstallActionText(component: Podkop.ComponentName) {
  const checkResult = store.get().updatesChecks[component];

  if (shouldShowInstallAfterCheck(component) && checkResult.latest_version) {
    return _('Install %s').replace('%s', checkResult.latest_version);
  }

  return _('Install');
}

function getGitHubReleaseUrl(component: Podkop.ComponentName) {
  const checkResult = store.get().updatesChecks[component];

  if (!shouldShowInstallAfterCheck(component) || !checkResult.release_url) {
    return undefined;
  }

  return checkResult.release_url;
}

function isAnyActionLoading() {
  return Object.values(store.get().updatesActions).some((item) => item.loading);
}

function isSystemInfoLoading() {
  const systemInfo = store.get().diagnosticsSystemInfo;

  return systemInfo.loading || !systemInfo.loaded;
}

function setActionLoading(action: UpdatesActionKey, loading: boolean) {
  const updatesActions = store.get().updatesActions;

  store.set({
    updatesActions: {
      ...updatesActions,
      [action]: { loading },
    },
  });
}

function setCheckResult(
  component: Podkop.ComponentName,
  status: UpdateStatus,
  latestVersion: string,
  releaseUrl: string = '',
) {
  const updatesChecks = store.get().updatesChecks;

  store.set({
    updatesChecks: {
      ...updatesChecks,
      [component]: {
        status,
        latest_version: latestVersion,
        release_url: releaseUrl,
      },
    },
  });
}

function resetCheckResult(component: Podkop.ComponentName) {
  setCheckResult(component, null, '');
}

function getExpectedLatestVersionForAction(button: ComponentActionButton) {
  if (button.component !== 'podkop' || button.action !== 'install') {
    return undefined;
  }

  return (
    store.get().updatesChecks[button.component].latest_version || undefined
  );
}

function getCheckToastMessage(status: UpdateStatus) {
  if (status === 'outdated') {
    return _('Update is available');
  }

  if (status === 'dev') {
    return _('Installed version is newer than release');
  }

  return _('Latest version is installed');
}

async function refreshSystemInfoAfterMutation() {
  await ensureSystemInfo({ force: true, silent: true });
}

function notifyActionProvidersAvailabilityChanged(
  systemInfo: StoreType['diagnosticsSystemInfo'],
) {
  if (typeof window === 'undefined' || typeof CustomEvent === 'undefined') {
    return;
  }

  window.dispatchEvent(
    new CustomEvent(PODKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
      detail: {
        zapretInstalled: Boolean(systemInfo.zapret_installed),
        byedpiInstalled: Boolean(systemInfo.byedpi_installed),
      },
    }),
  );
}

function reloadPageAfterPodkopUpdate() {
  window.setTimeout(() => {
    window.location.reload();
  }, 1200);
}

function patchSystemInfoAfterMutation(result: Podkop.ComponentActionResult) {
  const systemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = { ...systemInfo, loading: false, loaded: true };
  const version =
    result.current_version || result.latest_version || _('unknown');

  if (result.component === 'podkop' && result.action === 'install') {
    nextSystemInfo.podkop_version = version;
  }

  if (result.component === 'sing_box') {
    nextSystemInfo.sing_box_version = version;

    if (result.action === 'install_extended') {
      nextSystemInfo.sing_box_extended = 1;
    }

    if (result.action === 'install_stable') {
      nextSystemInfo.sing_box_extended = 0;
    }
  }

  if (result.component === 'zapret') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret_installed = 0;
      nextSystemInfo.zapret_version = 'not installed';
    } else {
      nextSystemInfo.zapret_installed = 1;
      nextSystemInfo.zapret_version = version;
    }
  }

  if (result.component === 'byedpi') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.byedpi_installed = 0;
      nextSystemInfo.byedpi_version = 'not installed';
    } else {
      nextSystemInfo.byedpi_installed = 1;
      nextSystemInfo.byedpi_version = version;
    }
  }

  if (result.component === 'hub') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'hub_install_zapret') {
      nextSystemInfo.zapret_installed = 1;
      nextSystemInfo.zapret_version = version;
    } else if (result.action === 'hub_remove_zapret') {
      nextSystemInfo.zapret_installed = 0;
      nextSystemInfo.zapret_version = 'not installed';
    } else if (result.action === 'hub_install_byedpi') {
      nextSystemInfo.byedpi_installed = 1;
      nextSystemInfo.byedpi_version = version;
    } else if (result.action === 'hub_remove_byedpi') {
      nextSystemInfo.byedpi_installed = 0;
      nextSystemInfo.byedpi_version = 'not installed';
    } else if (result.action === 'hub_install_adguard') {
      nextSystemInfo.adguard_installed = 1;
      nextSystemInfo.adguard_version = version || 'installed';
    } else if (result.action === 'hub_remove_adguard') {
      nextSystemInfo.adguard_installed = 0;
      nextSystemInfo.adguard_version = 'not installed';
    }
  }

  store.set({
    diagnosticsSystemInfo: nextSystemInfo,
  });

  // Mirror the result back into the local hubModules map so the Hub card
  // buttons (Install / Update / Remove) update without a full reload.
  if (result.component === 'hub') {
    const m = result.action.match(/^hub_(install|remove)_(.+)$/);
    if (m) {
      const op = m[1]; // install | remove
      const moduleId = m[2];
      const existing = hubModules.get(moduleId);
      if (existing) {
        hubModules.set(moduleId, {
          ...existing,
          installed: op === 'install',
          installed_version: op === 'install' ? version : '',
        });
      }
      void loadHubModules();
    }
  }

  if (
    result.component === 'zapret' ||
    result.component === 'byedpi' ||
    result.component === 'hub'
  ) {
    notifyActionProvidersAvailabilityChanged(nextSystemInfo);
  }
}

async function checkKrotVersionViaGithub(): Promise<{
  status: UpdateStatus;
  latestVersion: string;
  releaseUrl: string;
} | null> {
  try {
    const res = await fetch(`${KROT_LATEST_URL}?v=${Date.now()}`);
    if (!res.ok) return null;

    const data = (await res.json()) as {
      version?: string;
      url?: string;
    };
    if (!data.version) return null;

    const systemInfo = store.get().diagnosticsSystemInfo;
    const installedVersion = normalizeCompiledVersion(
      systemInfo.podkop_version || '',
    );
    const isKnownVersion = installedVersion && /^\d/.test(installedVersion);
    const cmp = isKnownVersion
      ? compareVersions(installedVersion, data.version)
      : -1;
    // cmp > 0 means installed > latest (stale CDN) — treat as latest, not dev
    const status: UpdateStatus = cmp <= 0 ? (cmp === 0 ? 'latest' : 'outdated') : 'latest';

    return {
      status,
      latestVersion: data.version,
      releaseUrl: data.url || `https://github.com/titovcode/krot/releases/tag/${data.version}`,
    };
  } catch {
    return null;
  }
}

async function handleCheckKrotFrontend(button: ComponentActionButton) {
  setActionLoading(button.key, true);

  try {
    const githubResult = await checkKrotVersionViaGithub();

    if (githubResult) {
      setCheckResult('podkop', githubResult.status, githubResult.latestVersion, githubResult.releaseUrl);
      showToast(getCheckToastMessage(githubResult.status), 'success');
      return;
    }

    // GitHub unreachable from browser — fallback to backend
    const response = await PodkopShellMethods.componentAction('podkop', 'check_update');

    if (!response.success) {
      showToast(_('Failed to check K.R.O.T. updates'), 'warning');
      return;
    }

    // treat 'dev' (installed > latest) as 'latest' — likely stale CDN
    let status = response.data.status || null;
    if (status === 'dev') status = 'latest';
    if (status === 'latest' || status === 'outdated') {
      setCheckResult('podkop', status, response.data.latest_version || '', response.data.release_url || '');
    }
    showToast(getCheckToastMessage(status), 'success');
  } catch {
    showToast(_('Failed to check K.R.O.T. updates'), 'warning');
  } finally {
    setActionLoading(button.key, false);
  }
}

async function handleComponentAction(button: ComponentActionButton) {
  if (isAnyActionLoading()) {
    return;
  }

  if (button.component === 'podkop' && button.action === 'check_update') {
    return handleCheckKrotFrontend(button);
  }

  setActionLoading(button.key, true);

  try {
    const response = await PodkopShellMethods.componentAction(
      button.component,
      button.action,
      getExpectedLatestVersionForAction(button),
    );

    if (!response.success) {
      setActionLoading(button.key, false);
      showToast(response.error || _('Failed to execute'), 'error');
      return;
    }

    const result = response.data;

    if (button.action === 'check_update') {
      const status = result.status || null;

      if (status === 'latest' || status === 'outdated' || status === 'dev') {
        setCheckResult(
          button.component,
          status,
          result.latest_version || '',
          result.release_url || '',
        );
      }

      setActionLoading(button.key, false);
      showToast(getCheckToastMessage(status), 'success');
      return;
    }

    if (
      button.action === 'install' ||
      button.action.startsWith('install_') ||
      button.action.startsWith('hub_install_')
    ) {
      setCheckResult(button.component, 'latest', result.latest_version || '');
    } else {
      resetCheckResult(button.component);
    }

    patchSystemInfoAfterMutation(result);
    setActionLoading(button.key, false);

    if (result.component === 'podkop' && result.action === 'install') {
      if (result.message) {
        showToast(result.message, 'success', 1200);
      }

      reloadPageAfterPodkopUpdate();
      return;
    }

    if (result.message) {
      showToast(result.message, 'success');
    }

    void refreshSystemInfoAfterMutation();
  } catch (error) {
    logger.error('[UPDATES]', 'handleComponentAction failed', error);
    setActionLoading(button.key, false);
    showToast(_('Failed to execute'), 'error');
  }
}

function getPrimaryUpdateAction(
  component: Podkop.ComponentName,
  checkKey: UpdatesActionKey,
  installKey: UpdatesActionKey,
): ComponentActionButton {
  if (shouldShowInstallAfterCheck(component)) {
    return {
      key: installKey,
      text: getInstallActionText(component),
      icon: renderRotateCcwIcon24,
      component,
      action: 'install',
    };
  }

  return {
    key: checkKey,
    text: _('Check update'),
    icon: renderSearchIcon24,
    component,
    action: 'check_update',
  };
}

function getComponentCards(): ComponentCard[] {
  const systemInfo = store.get().diagnosticsSystemInfo;
  const systemInfoLoading = isSystemInfoLoading();
  const singBoxInstallAction: ComponentActionButton =
    systemInfo.sing_box_extended
      ? {
          key: 'singBoxInstallStable',
          text: _('Install stable'),
          icon: renderRotateCcwIcon24,
          component: 'sing_box',
          action: 'install_stable',
        }
      : {
          key: 'singBoxInstallExtended',
          text: _('Install extended'),
          icon: renderRotateCcwIcon24,
          component: 'sing_box',
          action: 'install_extended',
        };

  const builtInCards: ComponentCard[] = [
    {
      title: 'K.R.O.T.',
      version: normalizeCompiledVersion(systemInfo.podkop_version),
      releaseUrl: getGitHubReleaseUrl('podkop'),
      tag: getCheckTag('podkop'),
      actions: [
        getPrimaryUpdateAction('podkop', 'podkopCheck', 'podkopInstall'),
      ],
    },
    {
      title: 'Sing-box',
      version: isNotInstalled(systemInfo.sing_box_version)
        ? _('Not installed')
        : systemInfo.sing_box_version,
      releaseUrl: getGitHubReleaseUrl('sing_box'),
      tag: getCheckTag('sing_box'),
      actions: [
        getPrimaryUpdateAction('sing_box', 'singBoxCheck', 'singBoxInstall'),
        singBoxInstallAction,
      ],
    },
  ];

  // All hub modules (zapret, byedpi, and third-party)
  const hubModuleCards: ComponentCard[] = [];
  const hubModulesStore = store.get().hubModules;

  Object.entries(hubModulesStore).forEach(([key, moduleData]) => {
    // Determine installed status from systemInfo (for zapret/byedpi)
    let installed = moduleData.installed ?? false;
    let version = moduleData.installed_version ?? '';

    if (key === 'zapret') {
      installed = Boolean(systemInfo.zapret_installed);
      version = systemInfo.zapret_version;
    } else if (key === 'byedpi') {
      installed = Boolean(systemInfo.byedpi_installed);
      version = systemInfo.byedpi_version;
    }

    const displayVersion = systemInfoLoading || !version
      ? '—'
      : installed
        ? version || _('Installed')
        : _('Not installed');

    hubModuleCards.push({
      title: moduleData.name ?? key,
      version: displayVersion,
      description: moduleData.description,
      projectUrl: moduleData.project_url,
      actions: installed
        ? [
            {
              key: `${key}Install` as UpdatesActionKey,
              text: _('Update'),
              icon: renderRotateCcwIcon24,
              component: 'hub' as Podkop.ComponentName,
              action: `hub_install_${key}` as Podkop.ComponentAction,
            },
            {
              key: `${key}Remove` as UpdatesActionKey,
              text: _('Remove'),
              icon: renderXIcon24,
              component: 'hub' as Podkop.ComponentName,
              action: `hub_remove_${key}` as Podkop.ComponentAction,
            },
          ]
        : [
            {
              key: `${key}Install` as UpdatesActionKey,
              text: _('Install'),
              icon: renderRotateCcwIcon24,
              component: 'hub' as Podkop.ComponentName,
              action: `hub_install_${key}` as Podkop.ComponentAction,
            },
          ],
    });
  });

  hubModuleCards.sort((a, b) => (a.title ?? '').localeCompare(b.title ?? ''));

  return [...builtInCards, ...hubModuleCards];
}

function renderComponentTag(card: ComponentCard) {
  if (!card.tag) {
    return null;
  }

  return E(
    'span',
    {
      class: [
        'pdk_updates-page__component__tag',
        card.tag.kind === 'success'
          ? 'pdk_updates-page__component__tag--success'
          : '',
        card.tag.kind === 'warning'
          ? 'pdk_updates-page__component__tag--warning'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    card.tag.label,
  );
}

function renderComponentCard(card: ComponentCard) {
  const updatesActions = store.get().updatesActions;
  const anyActionLoading = isAnyActionLoading();
  const systemInfoLoading = isSystemInfoLoading();
  const tag = renderComponentTag(card);
  const headerChildren: Node[] = [
    E('b', { class: 'pdk_updates-page__component__title' }, card.title),
  ];
  const statusChildren: Node[] = [];

  if (card.releaseUrl) {
    statusChildren.push(
      E(
        'a',
        {
          class: 'pdk_updates-page__component__release-link',
          href: card.releaseUrl,
          target: '_blank',
          rel: 'noopener noreferrer',
        },
        _('Latest release'),
      ),
    );
  }

  if (tag) {
    statusChildren.push(tag);
  }

  if (statusChildren.length > 0) {
    headerChildren.push(
      E(
        'div',
        { class: 'pdk_updates-page__component__status' },
        statusChildren,
      ),
    );
  }

  const descriptionEl =
    card.description || card.projectUrl
      ? E('div', { class: 'pdk_updates-page__component__meta' }, [
          ...(card.description
            ? [
                E(
                  'span',
                  { class: 'pdk_updates-page__component__description' },
                  card.description,
                ),
              ]
            : []),
          ...(card.projectUrl
            ? [
                E(
                  'a',
                  {
                    class: 'pdk_updates-page__component__project-link',
                    href: card.projectUrl,
                    target: '_blank',
                    rel: 'noopener noreferrer',
                  },
                  _('Project page'),
                ),
              ]
            : []),
        ])
      : null;

  return E('div', { class: 'pdk_updates-page__component' }, [
    E('div', { class: 'pdk_updates-page__component__header' }, headerChildren),
    ...(descriptionEl ? [descriptionEl] : []),
    E('div', { class: 'pdk_updates-page__component__version' }, [
      E(
        'span',
        { class: 'pdk_updates-page__component__version__label' },
        _('Version'),
      ),
      E(
        'span',
        { class: 'pdk_updates-page__component__version__value' },
        card.version,
      ),
    ]),
    E(
      'div',
      { class: 'pdk_updates-page__component__actions' },
      card.actions.map((action) => {
        const loading = (updatesActions[action.key] ?? { loading: false }).loading;

        return renderButton({
          text: action.text,
          icon: action.icon,
          loading,
          disabled: systemInfoLoading || (anyActionLoading && !loading),
          onClick: () => void handleComponentAction(action),
        });
      }),
    ),
  ]);
}

function renderHubModuleRow(
  key: string,
  moduleData: StoreType['hubModules'][string],
  rowIndex: number = 0,
) {
  const updatesActions = store.get().updatesActions;
  const systemInfo = store.get().diagnosticsSystemInfo;
  const systemInfoLoading = isSystemInfoLoading();
  const anyActionLoading = isAnyActionLoading();

  let installed = moduleData.installed ?? false;
  let version = moduleData.installed_version ?? '';

  if (key === 'zapret') {
    installed = Boolean(systemInfo.zapret_installed);
    version = systemInfo.zapret_version;
  } else if (key === 'byedpi') {
    installed = Boolean(systemInfo.byedpi_installed);
    version = systemInfo.byedpi_version;
  } else if (key === 'adguard') {
    installed = Boolean(systemInfo.adguard_installed);
    version = systemInfo.adguard_version;
  }

  const displayVersion = systemInfoLoading || !version
    ? '—'
    : installed
      ? version || _('Installed')
      : _('Not installed');

  const actions = installed
    ? [
        {
          key: `${key}Install` as UpdatesActionKey,
          text: _('Update'),
          icon: renderRotateCcwIcon24,
          component: 'hub' as Podkop.ComponentName,
          action: `hub_install_${key}` as Podkop.ComponentAction,
        },
        {
          key: `${key}Remove` as UpdatesActionKey,
          text: _('Remove'),
          icon: renderXIcon24,
          component: 'hub' as Podkop.ComponentName,
          action: `hub_remove_${key}` as Podkop.ComponentAction,
        },
      ]
    : [
        {
          key: `${key}Install` as UpdatesActionKey,
          text: _('Install'),
          icon: renderRotateCcwIcon24,
          component: 'hub' as Podkop.ComponentName,
          action: `hub_install_${key}` as Podkop.ComponentAction,
        },
      ];

  return E('tr', { class: 'tr' }, [
    E('td', { class: 'td col-5 left', 'data-title': _('Module') }, [
      E('b', {}, moduleData.name ?? key),
      ...(moduleData.project_url
        ? [
            E(
              'a',
              {
                class: 'pdk_updates-page__hub-project-link',
                href: moduleData.project_url,
                target: '_blank',
                rel: 'noopener noreferrer',
              },
              _('Project page'),
            ),
          ]
        : []),
      ...(moduleData.description
        ? [
            E('span', {
              class: 'pdk_updates-page__hub-desc',
            }, moduleData.description),
          ]
        : []),
    ]),
    E('td', { class: 'td col-2 left', 'data-title': _('Version') }, displayVersion),
    E('td', {
      class: 'td col-2 right cbi-section-actions',
    }, [
      E('div', { class: 'pdk_updates-page__hub-actions' }, [
        ...actions.map((action) => {
          const loading = (updatesActions[action.key] ?? { loading: false }).loading;
          return renderButton({
            text: action.text,
            icon: action.icon,
            loading,
            disabled: systemInfoLoading || (anyActionLoading && !loading),
            onClick: () => void handleComponentAction(action),
          });
        }),
      ]),
    ]),
  ]);
}

function renderUpdatesComponents() {
  const top = document.getElementById('pdk_updates-top');
  const table = document.getElementById('pdk_updates-hub-table');

  if (!top || !table) {
    return;
  }

  const [krotCard, singboxCard, ...moduleCards] = getComponentCards();

  const hubModulesStore = store.get().hubModules;
  const moduleEntries = Object.entries(hubModulesStore)
    .sort(([aKey, aData], [bKey, bData]) =>
      (aData.name ?? aKey).localeCompare(bData.name ?? bKey),
    );

  return preserveScrollForPage(() => {
    top.replaceChildren(
      renderComponentCard(krotCard),
      renderComponentCard(singboxCard),
    );

    const thead = E('thead', {}, [
      E('tr', { class: 'tr cbi-section-table-titles' }, [
        E('th', { class: 'th col-5 left' }, _('Module')),
        E('th', { class: 'th col-2 left' }, _('Version')),
        E('th', { class: 'th col-2 right cbi-section-actions' }, '\u00a0'),
      ]),
    ]);

    const tbody = E(
      'tbody',
      {},
      moduleEntries.map(([key, data], index) => renderHubModuleRow(key, data, index)),
    );

    table.replaceChildren(thead, tbody);
  });
}

function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.diagnosticsSystemInfo || diff.updatesActions || diff.updatesChecks || diff.hubModules) {
    renderUpdatesComponents();
  }
}

async function ensureSystemInfoWithRetry() {
  const MAX_RETRIES = 5;
  const RETRY_DELAY_MS = 4_000;

  for (let i = 0; i < MAX_RETRIES; i++) {
    if (!updatesMounted) return;
    await ensureSystemInfo();
    if (store.get().diagnosticsSystemInfo.loaded) return;
    await sleep(RETRY_DELAY_MS);
  }
}

async function onPageMountAsync() {
  // System info first — no competition with hub RPC calls
  await ensureSystemInfoWithRetry();
  if (!updatesMounted) return;
  // Hub modules and auto-check after system info is ready
  void loadHubModules();
  void autoCheckKrot();
}

function onPageMount() {
  onPageUnmount();

  updatesMounted = true;
  store.subscribe(onStoreUpdate);
  renderUpdatesComponents();
  void onPageMountAsync();
}

const KROT_LATEST_URL =
  'https://raw.githubusercontent.com/titovcode/krot/main/latest.json';

let autoCheckKrotInProgress = false;

function compareVersions(a: string, b: string): -1 | 0 | 1 {
  const pa = a.split('.').map(Number);
  const pb = b.split('.').map(Number);
  const len = Math.max(pa.length, pb.length);

  for (let i = 0; i < len; i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff < 0) return -1;
    if (diff > 0) return 1;
  }

  return 0;
}

async function autoCheckKrot() {
  if (autoCheckKrotInProgress) {
    return;
  }

  autoCheckKrotInProgress = true;

  try {
    // Wait for systemInfo to be freshly loaded (up to 10s)
    for (let i = 0; i < 20; i++) {
      if (store.get().diagnosticsSystemInfo.loaded) break;
      await sleep(500);
    }

    const systemInfo = store.get().diagnosticsSystemInfo;
    const installedVersion = normalizeCompiledVersion(
      systemInfo.podkop_version || '',
    );

    if (!installedVersion || installedVersion === 'dev' || !/^\d/.test(installedVersion)) {
      return;
    }

    const result = await checkKrotVersionViaGithub();
    if (result) {
      setCheckResult('podkop', result.status, result.latestVersion, result.releaseUrl);
    }
  } catch {
    // silent — user can still click manually
  } finally {
    autoCheckKrotInProgress = false;
  }
}

function onPageUnmount() {
  updatesMounted = false;
  store.unsubscribe(onStoreUpdate);
}

function registerLifecycleListeners() {
  if (updatesLifecycleRegistered) {
    return;
  }

  updatesLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      const isUpdatesVisible = next.tabService.current === 'updates';

      if (isUpdatesVisible) {
        return onPageMount();
      }

      if (updatesMounted) {
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (updatesControllerInitialized) {
    return;
  }

  updatesControllerInitialized = true;

  onMount('updates-status').then(() => {
    logger.debug('[UPDATES]', 'initController', 'onMount');
    onPageMount();
    registerLifecycleListeners();
  });
}

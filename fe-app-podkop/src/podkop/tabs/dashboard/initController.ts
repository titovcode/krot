import {
  getClashWsUrl,
  isCopyableProxyLink,
  onMount,
  preserveScrollForPage,
  withTimeout,
} from '../../../helpers';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import { showToast } from '../../../helpers/showToast';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { CustomPodkopMethods, PodkopShellMethods } from '../../methods';
import { logger, socket, store, StoreType } from '../../services';
import { renderSections, renderWidget } from './partials';
import { fetchServicesInfo } from '../../fetchers/fetchServicesInfo';
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { getOutboundTagBySection } from '../../runtimeTags';
import { Podkop } from '../../types';

const SECTIONS_REFRESH_INTERVAL_MS = 10000;
const LATENCY_REFRESH_INTERVAL_MS = 3000;
const SECTION_TRAFFIC_REFRESH_INTERVAL_MS = 5000;
let sectionsRefreshTimer: ReturnType<typeof setInterval> | null = null;
let latencyRefreshTimer: ReturnType<typeof setInterval> | null = null;
let sectionsRefreshPromise: Promise<boolean> | null = null;
let sectionsRefreshQueued = false;
let latencyRefreshRunning = false;
let dashboardMounted = false;
let dashboardMountId = 0;
let lastSectionTrafficUpdateAt = 0;
let lastSectionTraffic: Record<string, { upload: number; download: number }> =
  {};

type ClashDashboardConnection = {
  chains?: string[];
  download?: number;
  rule?: string;
  upload?: number;
};

type ClashDashboardConnectionsPayload = {
  connections?: ClashDashboardConnection[];
};

function applyLastSectionTraffic(
  sections: Podkop.OutboundGroup[],
): Podkop.OutboundGroup[] {
  return sections.map((section) => {
    const previous = lastSectionTraffic[section.sectionName];

    if (!previous) {
      return section;
    }

    return {
      ...section,
      traffic: previous,
    };
  });
}

// Fetchers

async function fetchDashboardSectionsOnce(mountId: number) {
  const prev = store.get().sectionsWidget;
  const hasRenderedData = prev.data.length > 0;

  store.set({
    sectionsWidget: {
      ...prev,
      failed: false,
      loading: prev.loading && !hasRenderedData,
    },
  });

  try {
    const { data, success } = await CustomPodkopMethods.getDashboardSections();

    if (!dashboardMounted || mountId !== dashboardMountId) {
      return false;
    }

    if (!success) {
      throw new Error('failed to fetch dashboard sections');
    }

    const current = store.get().sectionsWidget;
    const nextData = data.length || !current.data.length ? data : current.data;

    store.set({
      sectionsWidget: {
        ...current,
        loading: false,
        failed: false,
        data: applyLastSectionTraffic(nextData),
      },
    });

    return true;
  } catch (error) {
    logger.error('[DASHBOARD]', 'fetchDashboardSections: failed', error);

    if (!dashboardMounted || mountId !== dashboardMountId) {
      return false;
    }

    const current = store.get().sectionsWidget;

    store.set({
      sectionsWidget: {
        ...current,
        loading: false,
        failed: current.data.length === 0,
        data: current.data,
      },
    });

    return false;
  }
}

async function fetchDashboardSections(options: { force?: boolean } = {}) {
  if (sectionsRefreshPromise) {
    if (options.force) {
      sectionsRefreshQueued = true;
    }

    return sectionsRefreshPromise;
  }

  const mountId = dashboardMountId;
  const promise = (async () => {
    let success = false;

    do {
      sectionsRefreshQueued = false;
      success = await fetchDashboardSectionsOnce(mountId);
    } while (
      sectionsRefreshQueued &&
      dashboardMounted &&
      mountId === dashboardMountId
    );

    return success;
  })();

  sectionsRefreshPromise = promise;

  try {
    return await promise;
  } finally {
    if (sectionsRefreshPromise === promise) {
      sectionsRefreshPromise = null;
    }
  }
}

function setSubscriptionUpdating(sectionName: string, updating: boolean) {
  const sectionsWidget = store.get().sectionsWidget;
  const subscriptionUpdatingSections = {
    ...sectionsWidget.subscriptionUpdatingSections,
  };

  if (updating) {
    subscriptionUpdatingSections[sectionName] = true;
  } else {
    delete subscriptionUpdatingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      subscriptionUpdatingSections,
    },
  });
}

function setSelectorSwitching(sectionName: string, tag?: string) {
  const sectionsWidget = store.get().sectionsWidget;
  const selectorSwitchingSections = {
    ...sectionsWidget.selectorSwitchingSections,
  };

  if (tag) {
    selectorSwitchingSections[sectionName] = tag;
  } else {
    delete selectorSwitchingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      selectorSwitchingSections,
    },
  });
}

function setLatencyFetching(sectionName: string, fetching: boolean) {
  const sectionsWidget = store.get().sectionsWidget;
  const latencyFetchingSections = {
    ...sectionsWidget.latencyFetchingSections,
  };

  if (fetching) {
    latencyFetchingSections[sectionName] = true;
  } else {
    delete latencyFetchingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      latencyFetchingSections,
    },
  });
}

async function connectToClashSockets() {
  const clashApiSecret = await getClashApiSecret();

  socket.subscribe(
    `${getClashWsUrl()}/traffic?token=${clashApiSecret}`,
    (msg) => {
      const parsedMsg = JSON.parse(msg);

      store.set({
        bandwidthWidget: {
          loading: false,
          failed: false,
          data: { up: parsedMsg.up, down: parsedMsg.down },
        },
      });
    },
    (_err) => {
      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - traffic: failed to connect to',
        getClashWsUrl(),
      );
      store.set({
        bandwidthWidget: {
          loading: false,
          failed: true,
          data: { up: 0, down: 0 },
        },
      });
    },
  );

  socket.subscribe(
    `${getClashWsUrl()}/connections?token=${clashApiSecret}`,
    (msg) => {
      const parsedMsg = JSON.parse(msg) as ClashDashboardConnectionsPayload & {
        downloadTotal?: number;
        memory?: number;
        uploadTotal?: number;
      };

      store.set({
        trafficTotalWidget: {
          loading: false,
          failed: false,
          data: {
            downloadTotal: parsedMsg.downloadTotal,
            uploadTotal: parsedMsg.uploadTotal,
          },
        },
        systemInfoWidget: {
          loading: false,
          failed: false,
          data: {
            connections: parsedMsg.connections?.length,
            memory: parsedMsg.memory,
          },
        },
      });
      const now = Date.now();
      if (
        now - lastSectionTrafficUpdateAt >=
        SECTION_TRAFFIC_REFRESH_INTERVAL_MS
      ) {
        lastSectionTrafficUpdateAt = now;
        updateSectionTraffic(parsedMsg);
      }
    },
    (_err) => {
      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - connections: failed to connect to',
        getClashWsUrl(),
      );
      store.set({
        trafficTotalWidget: {
          loading: false,
          failed: true,
          data: { downloadTotal: 0, uploadTotal: 0 },
        },
        systemInfoWidget: {
          loading: false,
          failed: true,
          data: {
            connections: 0,
            memory: 0,
          },
        },
      });
    },
  );
}

function getRouteTagFromRule(rule?: string): string {
  const match = `${rule || ''}`.trim().match(/=>\s*route\(([^)]+)\)/);
  return `${match?.[1] || ''}`.trim().replace(/^['"]|['"]$/g, '');
}

function normalizeTrafficKey(value?: string) {
  return `${value || ''}`.trim().toLowerCase().replace(/-out$/, '');
}

function getSectionTrafficTags(section: Podkop.OutboundGroup) {
  const sectionName = section.sectionName;
  const displayName = section.displayName;

  if (section.action === 'direct') {
    return ['direct', 'direct-out', sectionName, displayName]
      .map(normalizeTrafficKey)
      .filter(Boolean);
  }

  return [
    section.code,
    sectionName,
    displayName,
    getOutboundTagBySection(sectionName),
    getOutboundTagBySection(`${sectionName}-urltest`),
  ]
    .map(normalizeTrafficKey)
    .filter(Boolean);
}

function updateSectionTraffic(payload: ClashDashboardConnectionsPayload) {
  const sectionsWidget = store.get().sectionsWidget;
  const connections = Array.isArray(payload.connections)
    ? payload.connections
    : [];

  if (!sectionsWidget.data.length) {
    return;
  }

  const nextData = sectionsWidget.data.map((section) => {
    const tags = new Set(getSectionTrafficTags(section));
    let upload = 0;
    let download = 0;
    connections.forEach((connection) => {
      const chains = Array.isArray(connection.chains) ? connection.chains : [];
      const routeTag = getRouteTagFromRule(connection.rule);
      const matched = [...chains, routeTag]
        .map(normalizeTrafficKey)
        .some((tag) => tags.has(tag));

      if (!matched) {
        return;
      }

      upload += Number(connection.upload) || 0;
      download += Number(connection.download) || 0;
    });

    if (upload > 0 || download > 0) {
      lastSectionTraffic[section.sectionName] = { upload, download };
    } else {
      const previous = lastSectionTraffic[section.sectionName];

      if (previous) {
        upload = previous.upload;
        download = previous.download;
      }
    }

    return {
      ...section,
      traffic: { upload, download },
    };
  });

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      data: nextData,
    },
  });
}

// Handlers

async function handleChooseOutbound(
  sectionName: string,
  selector: string,
  tag: string,
) {
  const sectionsWidget = store.get().sectionsWidget;
  const section = sectionsWidget.data.find(
    (item) => item.sectionName === sectionName,
  );

  if (
    !section?.withTagSelect ||
    sectionsWidget.selectorSwitchingSections[sectionName] ||
    section.outbounds.some(
      (outbound) => outbound.code === tag && outbound.selected,
    )
  ) {
    return;
  }

  setSelectorSwitching(sectionName, tag);

  try {
    await PodkopShellMethods.setClashApiGroupProxy(selector, tag);
    await PodkopShellMethods.getClashApiProxyLatency(tag);
    await fetchDashboardSections({ force: true });
  } finally {
    setSelectorSwitching(sectionName);
  }
}

async function handleTestGroupLatency(
  sectionName: string,
  tag: string,
  options: { force?: boolean; quick?: boolean } = {},
) {
  if (
    store.get().sectionsWidget.latencyFetchingSections[sectionName] &&
    !options.force
  ) {
    return store
      .get()
      .sectionsWidget.data.find(
        (section) => section.sectionName === sectionName,
      );
  }

  setLatencyFetching(sectionName, true);

  try {
    let result;

    try {
      result = await withTimeout(
        PodkopShellMethods.getClashApiGroupLatency(
          tag,
          options.quick ? { timeout: '5000', quick: true } : {},
        ),
        options.quick ? 8000 : 30000,
        `dashboard group latency ${tag}`,
      );
    } catch (error) {
      logger.warn(
        '[DASHBOARD]',
        `Group latency check timed out for ${tag}: ${(error as Error).message}`,
      );
      return store
        .get()
        .sectionsWidget.data.find(
          (section) => section.sectionName === sectionName,
        );
    }

    if (!result.success) {
      return store
        .get()
        .sectionsWidget.data.find(
          (section) => section.sectionName === sectionName,
        );
    }

    await fetchDashboardSections({ force: true });
    return store
      .get()
      .sectionsWidget.data.find(
        (section) => section.sectionName === sectionName,
      );
  } finally {
    setLatencyFetching(sectionName, false);
  }
}

async function handleTestProxyLatency(
  sectionName: string,
  tag: string,
  options: { force?: boolean; quick?: boolean } = {},
) {
  if (
    store.get().sectionsWidget.latencyFetchingSections[sectionName] &&
    !options.force
  ) {
    return store
      .get()
      .sectionsWidget.data.find(
        (section) => section.sectionName === sectionName,
      );
  }

  setLatencyFetching(sectionName, true);

  try {
    let result;

    try {
      result = await withTimeout(
        PodkopShellMethods.getClashApiProxyLatency(
          tag,
          options.quick ? { timeout: '2500', quick: true } : {},
        ),
        options.quick ? 4000 : 15000,
        `dashboard proxy latency ${tag}`,
      );
    } catch (error) {
      logger.warn(
        '[DASHBOARD]',
        `Latency check timed out for ${tag}: ${(error as Error).message}`,
      );
      return store
        .get()
        .sectionsWidget.data.find(
          (section) => section.sectionName === sectionName,
        );
    }

    if (!result.success) {
      return store
        .get()
        .sectionsWidget.data.find(
          (section) => section.sectionName === sectionName,
        );
    }

    await fetchDashboardSections({ force: true });
    return store
      .get()
      .sectionsWidget.data.find(
        (section) => section.sectionName === sectionName,
      );
  } finally {
    setLatencyFetching(sectionName, false);
  }
}

function getDashboardLatencyTarget(section: Podkop.OutboundGroup) {
  if (section.latencyTestCode) {
    return {
      sectionName: section.sectionName,
      tag: section.latencyTestCode,
      group: section.withTagSelect,
    };
  }

  if (section.outbounds.length) {
    return {
      sectionName: section.sectionName,
      tag: section.outbounds[0].code,
      group: false,
    };
  }

  return undefined;
}

function getDashboardOutboundLatencyTargets(sections: Podkop.OutboundGroup[]) {
  return sections.flatMap((section) => {
    return section.outbounds
      .filter((outbound) => outbound.showLatency !== false)
      .filter((outbound) => outbound.code)
      .map((outbound) => ({
        sectionName: section.sectionName,
        tag: outbound.code,
      }));
  });
}

const OUTBOUND_LATENCY_CONCURRENCY = 12;

async function runWithConcurrency<T>(
  tasks: (() => Promise<T>)[],
  limit: number,
) {
  let cursor = 0;

  async function worker() {
    while (cursor < tasks.length) {
      const index = cursor;
      cursor += 1;
      try {
        await tasks[index]();
      } catch {
        // ignore individual latency failures so one bad proxy
        // doesn't stop the rest of the batch
      }
    }
  }

  const workers = Array.from({ length: Math.min(limit, tasks.length) }, () =>
    worker(),
  );

  await Promise.all(workers);
}

let updateCheckRunning = false;
let updateCheckDone = false;

async function checkForUpdates() {
  if (updateCheckRunning || updateCheckDone) return;
  updateCheckRunning = true;

  try {
    const response = await PodkopShellMethods.componentAction(
      'podkop',
      'check_update',
    );

    if (response.success && response.data?.status === 'outdated') {
      const latest = response.data.latest_version || '';
      showToast(
        _('New version available: %s').replace('%s', latest),
        'success',
        5000,
      );
    }
  } catch (_error) {
    // silently ignore — update check is best-effort
  } finally {
    updateCheckRunning = false;
    updateCheckDone = true;
  }
}

async function refreshDashboardLatencies() {
  if (latencyRefreshRunning) {
    return;
  }

  const mountId = dashboardMountId;
  const sections = store.get().sectionsWidget.data;
  const sectionTargets = sections
    .map(getDashboardLatencyTarget)
    .filter(Boolean) as {
    sectionName: string;
    tag: string;
    group: boolean;
  }[];
  const outboundTargets = getDashboardOutboundLatencyTargets(sections);

  if (!sectionTargets.length && !outboundTargets.length) {
    return;
  }

  latencyRefreshRunning = true;

  try {
    await Promise.all(
      sectionTargets.map((target) =>
        target.group
          ? PodkopShellMethods.getClashApiGroupLatency(target.tag)
          : PodkopShellMethods.getClashApiProxyLatency(target.tag),
      ),
    );

    await runWithConcurrency(
      outboundTargets.map(
        (target) => () =>
          PodkopShellMethods.getClashApiProxyLatency(target.tag),
      ),
      OUTBOUND_LATENCY_CONCURRENCY,
    );

    if (dashboardMounted && mountId === dashboardMountId) {
      await fetchDashboardSections({ force: true });
    }
  } finally {
    latencyRefreshRunning = false;
  }
}

async function handleCopyOutbound(
  section: Podkop.OutboundGroup,
  outbound: Podkop.Outbound,
) {
  const link = outbound.link;

  if (link && isCopyableProxyLink(link)) {
    copyToClipboard(link);
    return;
  }

  const response = await PodkopShellMethods.getOutboundLink(
    section.sectionName,
    outbound.code,
  );

  if (response.success && isCopyableProxyLink(response.data.link)) {
    copyToClipboard(response.data.link);
    return;
  }

  showToast(_('Proxy link is unavailable'), 'error');
}

async function handleUpdateSubscription(section: Podkop.OutboundGroup) {
  if (
    store.get().sectionsWidget.subscriptionUpdatingSections[section.sectionName]
  ) {
    return;
  }

  setSubscriptionUpdating(section.sectionName, true);

  try {
    const response = await PodkopShellMethods.subscriptionUpdate(
      section.sectionName,
    );

    if (!response.success) {
      setSubscriptionUpdating(section.sectionName, false);
      showToast(_('Failed to update subscriptions'), 'error');
      return;
    }

    setSubscriptionUpdating(section.sectionName, false);
    showToast(_('Subscription update completed'), 'success');
    void fetchDashboardSections({ force: true });
    void fetchServicesInfo();
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleUpdateSubscription: failed', error);
    setSubscriptionUpdating(section.sectionName, false);
    showToast(_('Failed to update subscriptions'), 'error');
  }
}

// Renderer

async function renderSectionsWidget() {
  logger.debug('[DASHBOARD]', 'renderSectionsWidget');
  const sectionsWidget = store.get().sectionsWidget;
  const container = document.getElementById('dashboard-sections-grid');

  if (!container) {
    return;
  }

  if (sectionsWidget.loading || sectionsWidget.failed) {
    const renderedWidget = renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section: {
        code: '',
        sectionName: '',
        displayName: '',
        outbounds: [],
        withTagSelect: false,
      },
      onTestLatency: async () => undefined,
      onTestOutboundLatency: async () => undefined,
      onChooseOutbound: () => {},
      onCopyOutbound: () => {},
      onUpdateSubscription: () => {},
      latencyFetching: false,
      subscriptionUpdating: false,
      selectorSwitchingTag: undefined,
    });

    return preserveScrollForPage(() => {
      container.replaceChildren(renderedWidget);
    });
  }

  const renderedWidgets = sectionsWidget.data.map((section) =>
    renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section,
      latencyFetching: Boolean(
        sectionsWidget.latencyFetchingSections[section.sectionName],
      ),
      subscriptionUpdating: Boolean(
        sectionsWidget.subscriptionUpdatingSections[section.sectionName],
      ),
      selectorSwitchingTag:
        sectionsWidget.selectorSwitchingSections[section.sectionName],
      onTestLatency: (tag, options) => {
        if (section.withTagSelect) {
          return handleTestGroupLatency(section.sectionName, tag, options);
        }

        return handleTestProxyLatency(section.sectionName, tag, options);
      },
      onTestOutboundLatency: (tag, options) =>
        handleTestProxyLatency(section.sectionName, tag, options),
      onChooseOutbound: (sectionName, selector, tag) => {
        void handleChooseOutbound(sectionName, selector, tag);
      },
      onCopyOutbound: (section, outbound) => {
        void handleCopyOutbound(section, outbound);
      },
      onUpdateSubscription: (section) => {
        void handleUpdateSubscription(section);
      },
    }),
  );
  const renderedSubscriptionDetails = sectionsWidget.data
    .filter((section) => section.subscriptionSourceCount)
    .map((section) =>
      renderSections({
        loading: sectionsWidget.loading,
        failed: sectionsWidget.failed,
        section,
        detailsOnly: true,
        latencyFetching: Boolean(
          sectionsWidget.latencyFetchingSections[section.sectionName],
        ),
        subscriptionUpdating: Boolean(
          sectionsWidget.subscriptionUpdatingSections[section.sectionName],
        ),
        selectorSwitchingTag:
          sectionsWidget.selectorSwitchingSections[section.sectionName],
        onTestLatency: (tag, options) => {
          if (section.withTagSelect) {
            return handleTestGroupLatency(section.sectionName, tag, options);
          }

          return handleTestProxyLatency(section.sectionName, tag, options);
        },
        onTestOutboundLatency: (tag, options) =>
          handleTestProxyLatency(section.sectionName, tag, options),
        onChooseOutbound: (sectionName, selector, tag) => {
          void handleChooseOutbound(sectionName, selector, tag);
        },
        onCopyOutbound: (section, outbound) => {
          void handleCopyOutbound(section, outbound);
        },
        onUpdateSubscription: (section) => {
          void handleUpdateSubscription(section);
        },
      }),
    );

  return preserveScrollForPage(() => {
    container.replaceChildren(
      ...renderedWidgets,
      ...renderedSubscriptionDetails,
    );
  });
}

async function renderBandwidthWidget() {
  logger.debug('[DASHBOARD]', 'renderBandwidthWidget');
  const traffic = store.get().bandwidthWidget;

  const container = document.getElementById('dashboard-widget-traffic');

  if (!container) {
    return;
  }

  if (traffic.loading || traffic.failed) {
    const renderedWidget = renderWidget({
      loading: traffic.loading,
      failed: traffic.failed,
      title: _('Traffic'),
      items: [
        { key: _('Uplink'), value: '...' },
        { key: _('Downlink'), value: '...' },
      ],
    });

    return container.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: traffic.loading,
    failed: traffic.failed,
    title: _('Traffic'),
    items: [
      { key: _('Uplink'), value: `${prettyBytes(traffic.data.up)}/s` },
      { key: _('Downlink'), value: `${prettyBytes(traffic.data.down)}/s` },
    ],
  });

  container.replaceChildren(renderedWidget);
}

async function renderTrafficTotalWidget() {
  logger.debug('[DASHBOARD]', 'renderTrafficTotalWidget');
  const trafficTotalWidget = store.get().trafficTotalWidget;

  const container = document.getElementById('dashboard-widget-traffic-total');

  if (!container) {
    return;
  }

  if (trafficTotalWidget.loading || trafficTotalWidget.failed) {
    const renderedWidget = renderWidget({
      loading: trafficTotalWidget.loading,
      failed: trafficTotalWidget.failed,
      title: _('Traffic Total'),
      items: [
        { key: _('Uplink'), value: '...' },
        { key: _('Downlink'), value: '...' },
      ],
    });

    return container.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: trafficTotalWidget.loading,
    failed: trafficTotalWidget.failed,
    title: _('Traffic Total'),
    items: [
      {
        key: _('Uplink'),
        value: String(prettyBytes(trafficTotalWidget.data.uploadTotal)),
      },
      {
        key: _('Downlink'),
        value: String(prettyBytes(trafficTotalWidget.data.downloadTotal)),
      },
    ],
  });

  container.replaceChildren(renderedWidget);
}

async function renderSystemInfoWidget() {
  logger.debug('[DASHBOARD]', 'renderSystemInfoWidget');
  const systemInfoWidget = store.get().systemInfoWidget;

  const container = document.getElementById('dashboard-widget-system-info');

  if (!container) {
    return;
  }

  if (systemInfoWidget.loading || systemInfoWidget.failed) {
    const renderedWidget = renderWidget({
      loading: systemInfoWidget.loading,
      failed: systemInfoWidget.failed,
      title: _('System info'),
      items: [
        { key: _('Active Connections'), value: '...' },
        { key: _('Memory Usage'), value: '...' },
      ],
    });

    return container.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: systemInfoWidget.loading,
    failed: systemInfoWidget.failed,
    title: _('System info'),
    items: [
      {
        key: _('Active Connections'),
        value: String(systemInfoWidget.data.connections),
      },
      {
        key: _('Memory Usage'),
        value: String(prettyBytes(systemInfoWidget.data.memory)),
      },
    ],
  });

  container.replaceChildren(renderedWidget);
}

async function renderServicesInfoWidget() {
  logger.debug('[DASHBOARD]', 'renderServicesInfoWidget');
  const servicesInfoWidget = store.get().servicesInfoWidget;

  const container = document.getElementById('dashboard-widget-service-info');

  if (!container) {
    return;
  }

  if (servicesInfoWidget.loading || servicesInfoWidget.failed) {
    const renderedWidget = renderWidget({
      loading: servicesInfoWidget.loading,
      failed: servicesInfoWidget.failed,
      title: _('Services info'),
      items: [
        { key: 'K.R.O.T.', value: '...' },
        { key: 'Sing-box', value: '...' },
      ],
    });

    return container.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: servicesInfoWidget.loading,
    failed: servicesInfoWidget.failed,
    title: _('Services info'),
    items: [
      {
        key: 'K.R.O.T.',
        value: servicesInfoWidget.data.podkopRunning
          ? _('✔ Running')
          : _('✘ Stopped'),
        attributes: {
          class: servicesInfoWidget.data.podkopRunning
            ? 'pdk_dashboard-page__widgets-section__item__row--success'
            : 'pdk_dashboard-page__widgets-section__item__row--error',
        },
      },
      {
        key: 'Sing-box',
        value: servicesInfoWidget.data.singbox
          ? _('✔ Running')
          : _('✘ Stopped'),
        attributes: {
          class: servicesInfoWidget.data.singbox
            ? 'pdk_dashboard-page__widgets-section__item__row--success'
            : 'pdk_dashboard-page__widgets-section__item__row--error',
        },
      },
    ],
  });

  container.replaceChildren(renderedWidget);
}

async function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.sectionsWidget) {
    renderSectionsWidget();
  }

  if (diff.bandwidthWidget) {
    renderBandwidthWidget();
  }

  if (diff.trafficTotalWidget) {
    renderTrafficTotalWidget();
  }

  if (diff.systemInfoWidget) {
    renderSystemInfoWidget();
  }

  if (diff.servicesInfoWidget) {
    renderServicesInfoWidget();
  }
}

async function onPageMount() {
  // Cleanup before mount
  onPageUnmount();

  dashboardMounted = true;
  dashboardMountId += 1;

  // Add new listener
  store.subscribe(onStoreUpdate);

  void fetchDashboardSections({ force: true });
  void fetchServicesInfo();
  void connectToClashSockets();
  void checkForUpdates();

  sectionsRefreshTimer = setInterval(() => {
    void fetchDashboardSections();
  }, SECTIONS_REFRESH_INTERVAL_MS);

  latencyRefreshTimer = setInterval(() => {
    void refreshDashboardLatencies();
  }, LATENCY_REFRESH_INTERVAL_MS);
}

function onPageUnmount() {
  dashboardMounted = false;
  dashboardMountId += 1;

  if (sectionsRefreshTimer) {
    clearInterval(sectionsRefreshTimer);
    sectionsRefreshTimer = null;
  }
  if (latencyRefreshTimer) {
    clearInterval(latencyRefreshTimer);
    latencyRefreshTimer = null;
  }
  latencyRefreshRunning = false;
  sectionsRefreshQueued = false;
  sectionsRefreshPromise = null;
  lastSectionTrafficUpdateAt = 0;
  lastSectionTraffic = {};
  // Remove old listener
  store.unsubscribe(onStoreUpdate);
  // Clear store
  store.reset([
    'bandwidthWidget',
    'trafficTotalWidget',
    'systemInfoWidget',
    'servicesInfoWidget',
    'sectionsWidget',
  ]);
  socket.resetAll();
}

let dashboardLifecycleRegistered = false;
let dashboardControllerInitialized = false;

function registerLifecycleListeners() {
  if (dashboardLifecycleRegistered) {
    return;
  }

  dashboardLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      logger.debug(
        '[DASHBOARD]',
        'active tab diff event, active tab:',
        diff.tabService.current,
      );
      const isDashboardVisible = next.tabService.current === 'dashboard';

      if (isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageMount',
        );
        return onPageMount();
      }

      if (!isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageUnmount',
        );
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (dashboardControllerInitialized) {
    return;
  }

  dashboardControllerInitialized = true;

  onMount('dashboard-status').then(() => {
    logger.debug('[DASHBOARD]', 'initController', 'onMount');
    onPageMount();
    registerLifecycleListeners();
  });
}

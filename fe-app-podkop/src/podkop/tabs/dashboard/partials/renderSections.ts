import {
  renderLoaderCircleIcon24,
  renderCopyIcon24,
  renderLinkIcon24,
  renderRotateCcwIcon24,
} from '../../../../icons';
import { isCopyableProxyLink, svgEl } from '../../../../helpers';
import { showToast } from '../../../../helpers/showToast';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import { Podkop } from '../../../types';

interface IRenderSectionsProps {
  loading: boolean;
  failed: boolean;
  section: Podkop.OutboundGroup;
  onTestLatency: (
    tag: string,
    options?: { force?: boolean; quick?: boolean },
  ) => Promise<Podkop.OutboundGroup | undefined>;
  onTestOutboundLatency: (
    tag: string,
    options?: { force?: boolean; quick?: boolean },
  ) => Promise<Podkop.OutboundGroup | undefined>;
  onChooseOutbound: (
    sectionName: string,
    selector: string,
    tag: string,
  ) => void;
  onCopyOutbound: (
    section: Podkop.OutboundGroup,
    outbound: Podkop.Outbound,
  ) => void;
  onUpdateSubscription: (section: Podkop.OutboundGroup) => void;
  latencyFetching: boolean;
  subscriptionUpdating: boolean;
  selectorSwitchingTag?: string;
  detailsOnly?: boolean;
}

const REGION_NAME_FALLBACKS: Record<string, string> = {
  XK: 'Kosovo',
};
const regionDisplayNamesCache: Record<string, string> = {};
const SECTION_ICON_PATHS: Record<string, string> = {
  port_up: '/luci-static/resources/icons/port_up.svg',
  port_down: '/luci-static/resources/icons/port_down.svg',
  switch: '/luci-static/resources/icons/switch.svg',
  bridge: '/luci-static/resources/icons/bridge.svg',
  ethernet: '/luci-static/resources/icons/ethernet.svg',
  wifi: '/luci-static/resources/icons/wifi.svg',
  'signal-000-000': '/luci-static/resources/icons/signal-000-000.svg',
  'signal-025-050': '/luci-static/resources/icons/signal-025-050.svg',
  'signal-050-075': '/luci-static/resources/icons/signal-050-075.svg',
  'signal-075-100': '/luci-static/resources/icons/signal-075-100.svg',
};

function getSectionIconPath(section: Podkop.OutboundGroup) {
  const icon = `${section.icon || 'port_up'}`.replace(/\.svg$/, '');

  if (SECTION_ICON_PATHS[icon]) {
    return SECTION_ICON_PATHS[icon];
  }

  if (/^[A-Za-z0-9_.-]+$/.test(icon)) {
    return `/luci-static/resources/icons/${icon}.svg`;
  }

  return SECTION_ICON_PATHS.port_up;
}

function getLuciLanguage() {
  const luci = (globalThis as { L?: { env?: { lang?: string } } }).L;

  if (luci?.env?.lang) {
    return `${luci.env.lang}`.replace('_', '-');
  }

  if (document.documentElement.lang) {
    return document.documentElement.lang;
  }

  return navigator.language || 'en';
}

function getCountryDisplayName(country?: string) {
  const code = `${country || ''}`.trim().toUpperCase();

  if (!/^[A-Z]{2}$/.test(code)) {
    return '';
  }

  const language = getLuciLanguage();
  const cacheKey = `${language}:${code}`;

  if (regionDisplayNamesCache[cacheKey]) {
    return regionDisplayNamesCache[cacheKey];
  }

  try {
    const displayNamesConstructor = (
      Intl as unknown as {
        DisplayNames?: new (
          locales: string[],
          options: { type: 'region' },
        ) => { of(code: string): string | undefined };
      }
    ).DisplayNames;

    if (displayNamesConstructor) {
      const displayNames = new displayNamesConstructor([language, 'en'], {
        type: 'region',
      });
      const displayName = displayNames.of(code);

      if (displayName && displayName !== code) {
        regionDisplayNamesCache[cacheKey] = displayName;
        return displayName;
      }
    }
  } catch (_error) {
    // Fall through to the static fallback.
  }

  const fallback = REGION_NAME_FALLBACKS[code] || code;
  regionDisplayNamesCache[cacheKey] = fallback;
  return fallback;
}

function getCountryFlagEmoji(country?: string) {
  const code = `${country || ''}`.trim().toUpperCase();

  if (!/^[A-Z]{2}$/.test(code)) {
    return '';
  }

  return String.fromCodePoint(
    ...code.split('').map((char) => 0x1f1e6 + char.charCodeAt(0) - 65),
  );
}

function renderCountryFlag(country?: string) {
  const countryFlag = getCountryFlagEmoji(country);

  if (!countryFlag) {
    return undefined;
  }

  const countryName = getCountryDisplayName(country);

  return E(
    'span',
    {
      class: 'pdk_dashboard-page__outbound-grid__item__country',
      title: countryName || undefined,
      'aria-label': countryName || undefined,
    },
    countryFlag,
  );
}

function renderFailedState() {
  return E(
    'div',
    {
      class: 'pdk_dashboard-page__outbound-section centered',
      style: 'height: 127px',
    },
    E('span', {}, [E('span', {}, _('Dashboard currently unavailable'))]),
  );
}

function renderLoadingState() {
  return E([]);
}

function isValidHttpUrl(url?: string) {
  return Boolean(url && /^https?:\/\/\S+$/i.test(url));
}

function formatBytes(value?: number) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    return undefined;
  }

  return prettyBytes(value);
}

function formatDate(seconds?: number) {
  if (
    typeof seconds !== 'number' ||
    !Number.isFinite(seconds) ||
    seconds <= 0
  ) {
    return undefined;
  }

  const date = new Date(seconds * 1000);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }

  return date.toLocaleDateString(undefined, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
}

function renderMetadataAction(label: string, url?: string) {
  if (!isValidHttpUrl(url)) {
    return undefined;
  }

  return E(
    'a',
    {
      class: 'btn cbi-button pdk_dashboard-page__subscription-meta__action',
      href: url,
      target: '_blank',
      rel: 'noopener noreferrer',
      title: label,
      'aria-label': label,
    },
    renderLinkIcon24(),
  );
}

function renderSubscriptionMetadata(
  metadata: Podkop.SubscriptionMetadata | undefined,
  extraActions: HTMLElement[] = [],
) {
  if (!metadata || Object.keys(metadata).length <= 1) {
    return undefined;
  }

  const title = metadata.title || metadata.fileName;
  const traffic = metadata.traffic;
  const used = formatBytes(traffic?.used) || '0 B';
  const total = traffic?.isUnlimited
    ? '∞'
    : formatBytes(traffic?.total) || '0 B';
  const expire = formatDate(metadata.expire);
  const refillDate = formatDate(metadata.refillDate);

  const rows = [
    traffic
      ? {
          label: _('Traffic'),
          value: `${used} / ${total}`,
        }
      : undefined,
    expire ? { label: _('Expires'), value: expire } : undefined,
    refillDate ? { label: _('Refill'), value: refillDate } : undefined,
  ].filter(Boolean) as { label: string; value: string }[];

  const actions = [
    renderMetadataAction('Profile', metadata.webPageUrl),
    renderMetadataAction('Support', metadata.supportUrl),
    renderMetadataAction('More details', metadata.announceUrl),
    ...extraActions,
  ].filter(Boolean) as HTMLElement[];

  return E('div', { class: 'pdk_dashboard-page__subscription-meta' }, [
    E('div', { class: 'pdk_dashboard-page__subscription-meta__main' }, [
      E(
        'div',
        { class: 'pdk_dashboard-page__subscription-meta__heading' },
        _('Subscription info:'),
      ),
      title
        ? E(
            'div',
            { class: 'pdk_dashboard-page__subscription-meta__title' },
            title,
          )
        : '',
      rows.length
        ? E(
            'div',
            { class: 'pdk_dashboard-page__subscription-meta__facts' },
            rows.map((row) =>
              E(
                'div',
                { class: 'pdk_dashboard-page__subscription-meta__fact' },
                [
                  E(
                    'span',
                    {
                      class: 'pdk_dashboard-page__subscription-meta__fact-key',
                    },
                    row.label,
                  ),
                  E(
                    'span',
                    {
                      class:
                        'pdk_dashboard-page__subscription-meta__fact-value',
                    },
                    row.value,
                  ),
                ],
              ),
            ),
          )
        : '',
      actions.length
        ? E(
            'div',
            { class: 'pdk_dashboard-page__subscription-meta__actions' },
            actions,
          )
        : '',
    ]),
  ]);
}

function renderSubscriptionUpdateAction(
  section: Podkop.OutboundGroup,
  subscriptionUpdating: boolean,
  onUpdateSubscription: (section: Podkop.OutboundGroup) => void,
) {
  if (!section.subscriptionSourceCount) {
    return undefined;
  }

  return E(
    'button',
    {
      type: 'button',
      class:
        'btn cbi-button pdk_dashboard-page__outbound-section__subscription-update',
      title: _('Update subscriptions'),
      'aria-label': _('Update subscriptions'),
      disabled: subscriptionUpdating ? true : undefined,
      click: (event: MouseEvent) => {
        event.preventDefault();
        event.stopPropagation();
        if (subscriptionUpdating) {
          return;
        }

        onUpdateSubscription(section);
      },
    },
    subscriptionUpdating ? renderLoaderCircleIcon24() : renderRotateCcwIcon24(),
  );
}

function renderDefaultState({
  section,
  onTestLatency,
  onTestOutboundLatency,
  onChooseOutbound,
  onCopyOutbound,
  onUpdateSubscription,
  subscriptionUpdating,
  selectorSwitchingTag,
  detailsOnly,
}: IRenderSectionsProps) {
  function renderOutbound(outbound: Podkop.Outbound) {
    const sectionEnabled = section.enabled !== false;

    function getLatencyClass() {
      if (!outbound.latency) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--empty';
      }

      if (outbound.latency < 800) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--green';
      }

      if (outbound.latency < 1500) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--yellow';
      }

      return 'pdk_dashboard-page__outbound-grid__item__latency--red';
    }

    function getStatusColor() {
      if (!sectionEnabled) {
        return '240, 144, 144';
      }

      if (outbound.selected) {
        return '144, 240, 144';
      }

      if (outboundSwitching) {
        return '255, 221, 128';
      }

      return '192, 192, 192';
    }

    const canCopyLink =
      Boolean(outbound.canCopyLink) || isCopyableProxyLink(outbound.link);
    const countryFlag = renderCountryFlag(outbound.country);
    const selectorSwitching = Boolean(selectorSwitchingTag);
    const outboundSwitching = selectorSwitchingTag === outbound.code;
    const canChooseOutbound =
      sectionEnabled &&
      section.withTagSelect &&
      !selectorSwitching &&
      !outbound.selected;
    const className = [
      'ifacebox',
      'pdk_dashboard-page__outbound-grid__item',
      outbound.selected
        ? 'pdk_dashboard-page__outbound-grid__item--active'
        : '',
      canChooseOutbound
        ? 'pdk_dashboard-page__outbound-grid__item--selectable'
        : '',
      !sectionEnabled || (section.withTagSelect && !canChooseOutbound)
        ? 'pdk_dashboard-page__outbound-grid__item--disabled'
        : '',
      outboundSwitching
        ? 'pdk_dashboard-page__outbound-grid__item--switching'
        : '',
    ]
      .filter(Boolean)
      .join(' ');
    const typeChildren = countryFlag
      ? ([countryFlag, outbound.type ? ` ${outbound.type}` : ''] as (
          | Node
          | string
        )[])
      : ([outbound.type].filter(Boolean) as string[]);
    const showLatency = outbound.showLatency !== false;
    const trafficUpload = section.traffic?.upload || 0;
    const trafficDownload = section.traffic?.download || 0;
    const trafficTooltip = [
      E('strong', {}, _('Section: ')),
      section.displayName,
      E('br'),
      E('strong', {}, _('Status: ')),
      sectionEnabled ? _('Enabled') : _('Disabled'),
      E('br'),
      E('strong', {}, _('Downloaded: ')),
      prettyBytes(trafficDownload),
      E('br'),
      E('strong', {}, _('Uploaded: ')),
      prettyBytes(trafficUpload),
    ];

    return E(
      'div',
      {
        class: className,
        'aria-busy': outboundSwitching ? 'true' : undefined,
        'aria-disabled':
          !sectionEnabled || (section.withTagSelect && !canChooseOutbound)
            ? 'true'
            : undefined,
        click: () =>
          canChooseOutbound &&
          onChooseOutbound(section.sectionName, section.code, outbound.code),
      },
      [
        ...(outboundSwitching
          ? [
              svgEl(
                'svg',
                { class: 'pdk_dashboard-page__outbound-grid__item__snake' },
                [
                  svgEl('rect', {
                    width: '100%',
                    height: '100%',
                    fill: 'none',
                    rx: 4,
                    ry: 4,
                    pathLength: 100,
                  }),
                ],
              ),
            ]
          : []),
        E(
          'div',
          {
            class:
              'ifacebox-head center pdk_dashboard-page__outbound-grid__item__header',
            style: 'font-weight:bold;text-align:center',
          },
          [
            E('strong', {}, section.displayName),
            ...(canCopyLink
              ? [
                  E(
                    'button',
                    {
                      type: 'button',
                      class:
                        'btn cbi-button pdk_dashboard-page__outbound-grid__item__copy-button',
                      title: _('Copy proxy link'),
                      'aria-label': _('Copy proxy link'),
                      click: (event: MouseEvent) => {
                        event.stopPropagation();
                        onCopyOutbound(section, outbound);
                      },
                    },
                    renderCopyIcon24(),
                  ),
                ]
              : []),
          ],
        ),
        E(
          'div',
          {
            class:
              'ifacebox-body pdk_dashboard-page__outbound-grid__item__body',
          },
          [
            E('img', {
              src: getSectionIconPath(section),
              alt: '',
            }),
            E('br'),
            E(
              'span',
              {
                class: 'pdk_dashboard-page__outbound-grid__item__name',
                title: outbound.displayName,
              },
              outbound.displayName,
            ),
          ],
        ),
        E(
          'div',
          {
            class:
              'ifacebox-head cbi-tooltip-container pdk_dashboard-page__outbound-grid__item__status',
            style: 'display:flex',
          },
          [
            E('div', {
              class: 'zonebadge',
              style: `cursor:help;flex:1;height:3px;opacity:1;--zone-color-rgb:${getStatusColor()};background-color:rgb(var(--zone-color-rgb))`,
            }),
            E(
              'span',
              { class: 'cbi-tooltip left' },
              sectionEnabled ? _('Enabled') : _('Disabled'),
            ),
          ],
        ),
        E('div', { class: 'ifacebox-body' }, [
          E(
            'div',
            {
              class:
                'pdk_dashboard-page__outbound-grid__item__stats cbi-tooltip-container',
              style: 'text-align:left;font-size:80%',
            },
            [
              ...(showLatency
                ? [
                    E(
                      'span',
                      { class: getLatencyClass() },
                      outbound.latency ? `${outbound.latency}ms` : 'N/A',
                    ),
                    E('br'),
                  ]
                : []),
              `▲ ${prettyBytes(trafficUpload)}`,
              E('br'),
              `▼ ${prettyBytes(trafficDownload)}`,
              E('span', { class: 'cbi-tooltip left' }, trafficTooltip),
            ],
          ),
        ]),
      ],
    );
  }

  const subscriptionUpdateAction = renderSubscriptionUpdateAction(
    section,
    subscriptionUpdating,
    onUpdateSubscription,
  );
  const metadataNodes = (section.subscriptionMetadata || [])
    .map((metadata, index) =>
      renderSubscriptionMetadata(
        metadata,
        index === 0 && subscriptionUpdateAction
          ? [subscriptionUpdateAction]
          : [],
      ),
    )
    .filter(Boolean) as HTMLElement[];
  const selectedOutbound =
    section.outbounds.find((outbound) => outbound.selected) ||
    section.outbounds[0];
  const subscriptionTitle =
    section.subscriptionMetadata?.find((metadata) => metadata.title)?.title ||
    section.displayName;

  function renderSubscriptionSummary() {
    if (!section.subscriptionSourceCount || !selectedOutbound) {
      return '';
    }

    const sectionEnabled = section.enabled !== false;
    const countryFlag = renderCountryFlag(selectedOutbound.country);
    const trafficUpload = section.traffic?.upload || 0;
    const trafficDownload = section.traffic?.download || 0;
    const latency = selectedOutbound.latency;
    const latencyClass = !latency
      ? 'pdk_dashboard-page__outbound-grid__item__latency--empty'
      : latency < 800
        ? 'pdk_dashboard-page__outbound-grid__item__latency--green'
        : latency < 1500
          ? 'pdk_dashboard-page__outbound-grid__item__latency--yellow'
          : 'pdk_dashboard-page__outbound-grid__item__latency--red';

    return E(
      'div',
      {
        class:
          'ifacebox pdk_dashboard-page__outbound-grid__item pdk_dashboard-page__outbound-grid__item--active',
      },
      [
        E(
          'div',
          {
            class:
              'ifacebox-head center pdk_dashboard-page__outbound-grid__item__header',
            style: 'font-weight:bold;text-align:center',
            title: subscriptionTitle,
          },
          [E('strong', {}, subscriptionTitle)],
        ),
        E(
          'div',
          {
            class:
              'ifacebox-body pdk_dashboard-page__outbound-grid__item__body',
          },
          [
            E('img', {
              src: getSectionIconPath(section),
              alt: '',
            }),
            E('br'),
            E(
              'span',
              {
                class: 'pdk_dashboard-page__outbound-grid__item__name',
                title: selectedOutbound.displayName,
              },
              [
                ...(countryFlag ? [countryFlag, ' '] : []),
                selectedOutbound.displayName,
              ],
            ),
          ],
        ),
        E(
          'div',
          {
            class:
              'ifacebox-head cbi-tooltip-container pdk_dashboard-page__outbound-grid__item__status',
            style: 'display:flex',
          },
          [
            E('div', {
              class: 'zonebadge',
              style: `cursor:help;flex:1;height:3px;opacity:1;--zone-color-rgb:${
                sectionEnabled ? '144, 240, 144' : '240, 144, 144'
              };background-color:rgb(var(--zone-color-rgb))`,
            }),
            E(
              'span',
              { class: 'cbi-tooltip left' },
              sectionEnabled ? _('Enabled') : _('Disabled'),
            ),
          ],
        ),
        E('div', { class: 'ifacebox-body' }, [
          E(
            'div',
            {
              class:
                'pdk_dashboard-page__outbound-grid__item__stats cbi-tooltip-container',
              style: 'text-align:left;font-size:80%',
            },
            [
              E(
                'span',
                { class: latencyClass },
                latency ? `${latency}ms` : 'N/A',
              ),
              E('br'),
              `▲ ${prettyBytes(trafficUpload)}`,
              E('br'),
              `▼ ${prettyBytes(trafficDownload)}`,
            ],
          ),
        ]),
      ],
    );
  }

  function renderSubscriptionDetails() {
    if (!section.subscriptionSourceCount) {
      return '';
    }

    let currentSection = section;
    let latencyRefreshRunning = false;

    function getSortedOutbounds(outbounds: Podkop.Outbound[]) {
      return [...outbounds].sort((left, right) => {
        const leftLatency =
          Number.isFinite(left.latency) && left.latency > 0
            ? left.latency
            : Number.POSITIVE_INFINITY;
        const rightLatency =
          Number.isFinite(right.latency) && right.latency > 0
            ? right.latency
            : Number.POSITIVE_INFINITY;

        if (leftLatency !== rightLatency) {
          return leftLatency - rightLatency;
        }

        return left.displayName.localeCompare(right.displayName);
      });
    }

    function renderLatency(outbound: Podkop.Outbound) {
      const latency = outbound.latency;
      const latencyClass = !latency
        ? 'pdk_dashboard-page__outbound-grid__item__latency--empty'
        : latency < 800
          ? 'pdk_dashboard-page__outbound-grid__item__latency--green'
          : latency < 1500
            ? 'pdk_dashboard-page__outbound-grid__item__latency--yellow'
            : 'pdk_dashboard-page__outbound-grid__item__latency--red';

      return E(
        'span',
        { class: latencyClass },
        latency ? `${latency}ms` : 'N/A',
      );
    }

    function renderAction(outbound: Podkop.Outbound, closeOnSelect = false) {
      const sectionEnabled = currentSection.enabled !== false;
      const selectorSwitching = Boolean(selectorSwitchingTag);
      const outboundSwitching = selectorSwitchingTag === outbound.code;
      const canChooseOutbound =
        sectionEnabled &&
        currentSection.withTagSelect &&
        !selectorSwitching &&
        !outbound.selected;
      const canCopyLink =
        Boolean(outbound.canCopyLink) || isCopyableProxyLink(outbound.link);
      const actions: (HTMLElement | string)[] = [];

      if (canChooseOutbound || outbound.selected || outboundSwitching) {
        actions.push(
          E(
            'button',
            {
              type: 'button',
              class: 'cbi-button cbi-button-apply',
              disabled: !canChooseOutbound ? true : undefined,
              click: (event: MouseEvent) => {
                event.preventDefault();
                event.stopPropagation();
                if (canChooseOutbound) {
                  onChooseOutbound(
                    currentSection.sectionName,
                    currentSection.code,
                    outbound.code,
                  );
                  if (closeOnSelect) {
                    ui.hideModal();
                  }
                }
              },
            },
            outboundSwitching
              ? _('Switching...')
              : outbound.selected
                ? _('Selected')
                : _('Select'),
          ),
        );
      }

      if (canCopyLink) {
        actions.push(
          E(
            'button',
            {
              type: 'button',
              class: 'cbi-button pdk_dashboard-page__subscription-copy-button',
              title: _('Copy proxy link'),
              'aria-label': _('Copy proxy link'),
              click: (event: MouseEvent) => {
                event.preventDefault();
                event.stopPropagation();
                onCopyOutbound(currentSection, outbound);
              },
            },
            renderCopyIcon24(),
          ),
        );
      }

      return E(
        'div',
        { class: 'pdk_dashboard-page__subscription-actions' },
        actions.length ? actions : '',
      );
    }

    function renderOutboundsTable() {
      const visibleOutbounds = latencyRefreshRunning
        ? currentSection.outbounds
        : getSortedOutbounds(currentSection.outbounds);

      return E(
        'table',
        { class: 'table pdk_dashboard-page__subscription-table' },
        [
          E('tr', { class: 'tr table-titles' }, [
            E('th', { class: 'th' }, _('Name')),
            E('th', { class: 'th' }, _('Type')),
            E('th', { class: 'th' }, _('Latency')),
            E('th', { class: 'th cbi-section-actions' }, _('Action')),
          ]),
          ...(visibleOutbounds.length
            ? visibleOutbounds.map((outbound, index) => {
                const countryFlag = renderCountryFlag(outbound.country);

                return E(
                  'tr',
                  {
                    class: `tr cbi-rowstyle-${(index % 2) + 1}`,
                  },
                  [
                    E('td', { class: 'td', 'data-title': _('Name') }, [
                      ...(countryFlag ? [countryFlag, ' '] : []),
                      E(
                        'span',
                        { title: outbound.displayName },
                        outbound.displayName,
                      ),
                    ]),
                    E(
                      'td',
                      { class: 'td', 'data-title': _('Type') },
                      outbound.type || '',
                    ),
                    E(
                      'td',
                      { class: 'td', 'data-title': _('Latency') },
                      renderLatency(outbound),
                    ),
                    E(
                      'td',
                      {
                        class: 'td cbi-section-actions',
                        'data-title': _('Action'),
                      },
                      renderAction(outbound, true),
                    ),
                  ],
                );
              })
            : [
                E('tr', { class: 'tr placeholder' }, [
                  E(
                    'td',
                    { class: 'td', colspan: 4 },
                    E('em', {}, _('There are no subscriptions')),
                  ),
                ]),
              ]),
        ],
      );
    }

    function openSubscriptionModal() {
      let table = renderOutboundsTable();
      const refreshButton = E(
        'button',
        {
          class: 'btn',
          click: refreshLatency,
        },
        _('Refresh latency'),
      ) as HTMLButtonElement;

      function replaceTable() {
        const nextTable = renderOutboundsTable();
        table.replaceWith(nextTable);
        table = nextTable;
      }

      function mergeFreshSectionPreservingOrder(
        freshSection: Podkop.OutboundGroup,
      ) {
        const freshByCode = new Map(
          freshSection.outbounds.map((outbound) => [outbound.code, outbound]),
        );

        currentSection = {
          ...freshSection,
          outbounds: currentSection.outbounds.map(
            (outbound) => freshByCode.get(outbound.code) || outbound,
          ),
        };
      }

      async function refreshLatency(event?: MouseEvent) {
        event?.preventDefault();

        if (refreshButton?.disabled) {
          return;
        }

        if (refreshButton) {
          const savedWidth = refreshButton.offsetWidth;
          refreshButton.disabled = true;
          refreshButton.style.minWidth = savedWidth + 'px';
          refreshButton.replaceChildren(
            renderLoaderCircleIcon24(),
            ' ',
            _('Refresh latency'),
          );
        }

        try {
          latencyRefreshRunning = true;
          replaceTable();

          const outboundsToTest = currentSection.outbounds.filter(
            (outbound) => outbound.showLatency !== false && outbound.code,
          );

          const groupResult = await onTestLatency(currentSection.code, {
            force: true,
          });
          console.log(
            '[KROT] refreshLatency: groupResult=',
            groupResult
              ? {
                  code: groupResult.code,
                  outbounds: groupResult.outbounds?.length,
                  latencies: groupResult.outbounds?.map((o) => o.latency),
                }
              : null,
          );
          if (groupResult) {
            mergeFreshSectionPreservingOrder(groupResult);
          }

          const CONCURRENCY = 4;
          let cursor = 0;
          const tasks = outboundsToTest.map((outbound) => async () => {
            const result = await onTestOutboundLatency(outbound.code, {
              force: true,
            });
            console.log(
              '[KROT] refreshLatency: outboundResult',
              outbound.code,
              result
                ? {
                    latencies: result.outbounds?.map((o) => ({
                      code: o.code,
                      latency: o.latency,
                    })),
                  }
                : null,
            );
            if (result) {
              mergeFreshSectionPreservingOrder(result);
              replaceTable();
            }
          });

          async function runWorker() {
            while (cursor < tasks.length) {
              const i = cursor++;
              await tasks[i]();
            }
          }

          await Promise.allSettled(
            Array.from(
              { length: Math.min(CONCURRENCY, tasks.length) },
              runWorker,
            ),
          );

          latencyRefreshRunning = false;
          replaceTable();
        } catch (err) {
          showToast(
            _('Failed to refresh latency') +
              ': ' +
              (err instanceof Error ? err.message : String(err)),
            'error',
          );
        } finally {
          latencyRefreshRunning = false;
          if (refreshButton) {
            refreshButton.disabled = false;
            refreshButton.style.minWidth = '';
            refreshButton.replaceChildren(_('Refresh latency'));
          }
        }
      }

      ui.showModal(_('Subscription') + `: ${subscriptionTitle}`, [
        E('div', { class: 'pdk_dashboard-page__subscription-modal' }, table),
        E('div', { class: 'right' }, [
          refreshButton,
          ' ',
          E(
            'button',
            {
              class: 'btn',
              click: () => ui.hideModal(),
            },
            _('Dismiss'),
          ),
        ]),
      ]);

      const modal = document.querySelector('#modal_overlay .modal');
      if (modal instanceof HTMLElement) {
        modal.style.width = 'min(1100px, calc(100vw - 48px))';
      }
    }

    const firstMetadata = section.subscriptionMetadata?.[0];
    const shareUrl =
      section.subscriptionUrls?.[0] ||
      firstMetadata?.webPageUrl ||
      firstMetadata?.supportUrl ||
      firstMetadata?.announceUrl;
    const shareAction = renderMetadataAction(_('Share'), shareUrl);
    const subscriptionTrafficText = firstMetadata?.traffic
      ? firstMetadata.traffic.isUnlimited
        ? `${formatBytes(firstMetadata.traffic.used) || '0 B'} / ∞`
        : `${formatBytes(firstMetadata.traffic.used) || '0 B'} / ${
            formatBytes(firstMetadata.traffic.total) || '0 B'
          }`
      : '';
    const subscriptionExpireText = firstMetadata?.expire
      ? formatDate(firstMetadata.expire)
      : '';
    const subscriptionFactText = [
      subscriptionTrafficText
        ? `${_('Traffic')}: ${subscriptionTrafficText}`
        : '',
      subscriptionExpireText
        ? `${_('Expires')}: ${subscriptionExpireText}`
        : '',
    ]
      .filter(Boolean)
      .join(' · ');
    const subscriptionInfo = firstMetadata
      ? [
          E('strong', {}, firstMetadata.title || subscriptionTitle),
          ...(subscriptionFactText
            ? [E('br'), E('span', {}, subscriptionFactText)]
            : []),
        ]
      : subscriptionTitle;

    return E(
      'div',
      { class: 'cbi-section pdk_dashboard-page__subscription-section' },
      [
        E('h3', {}, _('Subscription')),
        E(
          'table',
          { class: 'table pdk_dashboard-page__subscription-summary-table' },
          [
            E('tr', { class: 'tr table-titles' }, [
              E('th', { class: 'th' }, _('Name')),
              E('th', { class: 'th' }, _('Subscription info')),
              E('th', { class: 'th' }, _('Latency')),
              E('th', { class: 'th cbi-section-actions' }, _('Action')),
            ]),
            E('tr', { class: 'tr cbi-rowstyle-1' }, [
              E('td', { class: 'td', 'data-title': _('Name') }, [
                E('strong', {}, subscriptionTitle),
                ...(selectedOutbound
                  ? [
                      E('br'),
                      E('small', {}, [
                        ...(renderCountryFlag(selectedOutbound.country)
                          ? [renderCountryFlag(selectedOutbound.country)!, ' ']
                          : []),
                        E(
                          'span',
                          { title: selectedOutbound.displayName },
                          selectedOutbound.displayName,
                        ),
                      ]),
                    ]
                  : []),
              ]),
              E(
                'td',
                { class: 'td', 'data-title': _('Subscription info') },
                subscriptionInfo,
              ),
              E(
                'td',
                { class: 'td', 'data-title': _('Latency') },
                selectedOutbound ? renderLatency(selectedOutbound) : 'N/A',
              ),
              E(
                'td',
                { class: 'td cbi-section-actions', 'data-title': _('Action') },
                E(
                  'div',
                  { class: 'right pdk_dashboard-page__subscription-actions' },
                  [
                    E(
                      'button',
                      {
                        class: 'cbi-button cbi-button-action important',
                        click: (event: MouseEvent) => {
                          event.preventDefault();
                          openSubscriptionModal();
                        },
                      },
                      _('Select server'),
                    ),
                    ...(subscriptionUpdateAction
                      ? [subscriptionUpdateAction]
                      : []),
                    ...(shareAction ? [shareAction] : []),
                  ],
                ),
              ),
            ]),
          ],
        ),
      ],
    );
  }

  if (detailsOnly) {
    return renderSubscriptionDetails();
  }

  const fallbackOutbound = {
    code: section.code || section.sectionName,
    displayName: section.action || section.displayName,
    latency: 0,
    type: section.action || '',
    selected: false,
    canCopyLink: false,
    showLatency: false,
  };
  const sectionCards = section.subscriptionSourceCount
    ? [renderSubscriptionSummary() || renderOutbound(fallbackOutbound)]
    : section.outbounds.length
      ? section.outbounds.map((outbound) => renderOutbound(outbound))
      : [renderOutbound(fallbackOutbound)];

  return E('div', { class: 'pdk_dashboard-page__outbound-section' }, [
    E('div', { class: 'pdk_dashboard-page__outbound-grid' }, [
      ...(!section.subscriptionSourceCount ? metadataNodes : []),
      ...sectionCards,
    ]),
  ]);
}

export function renderSections(props: IRenderSectionsProps) {
  if (props.failed) {
    return renderFailedState();
  }

  if (props.loading) {
    return renderLoadingState();
  }

  return renderDefaultState(props);
}

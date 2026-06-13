import { renderSections, renderWidget } from './partials';
import { MonitoringTab } from '../monitoring';

export function render() {
  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'pdk_dashboard-page',
    },
    [
      // Widgets section
      E('div', { class: 'network-status-table pdk_dashboard-page__widgets-section' }, [
        E(
          'div',
          { id: 'dashboard-widget-traffic' },
          renderWidget({
            loading: true,
            failed: false,
            title: _('Traffic'),
            items: [
              { key: _('Uplink'), value: '...' },
              { key: _('Downlink'), value: '...' },
            ],
          }),
        ),
        E(
          'div',
          { id: 'dashboard-widget-traffic-total' },
          renderWidget({
            loading: true,
            failed: false,
            title: _('Traffic Total'),
            items: [
              { key: _('Uplink'), value: '...' },
              { key: _('Downlink'), value: '...' },
            ],
          }),
        ),
        E(
          'div',
          { id: 'dashboard-widget-system-info' },
          renderWidget({
            loading: true,
            failed: false,
            title: _('System info'),
            items: [
              { key: _('Active Connections'), value: '...' },
              { key: _('Memory Usage'), value: '...' },
            ],
          }),
        ),
        E(
          'div',
          { id: 'dashboard-widget-service-info' },
          renderWidget({
            loading: true,
            failed: false,
            title: _('Services info'),
            items: [
              { key: 'Podkop Plus', value: '...' },
              { key: 'Sing-box', value: '...' },
            ],
          }),
        ),
      ]),
      // All outbounds
      E('h3', {}, _('Proxy status')),
      E(
        'div',
        { id: 'dashboard-sections-grid' },
        renderSections({
          loading: true,
          failed: false,
          section: {
            code: '',
            sectionName: '',
            displayName: '',
            outbounds: [],
            withTagSelect: false,
          },
          onTestLatency: () => {},
          onChooseOutbound: () => {},
          onCopyOutbound: () => {},
          onUpdateSubscription: () => {},
          latencyFetching: false,
          subscriptionUpdating: false,
          selectorSwitchingTag: undefined,
        }),
      ),
      E('div', { class: 'pdk_dashboard-page__monitoring-section' }, [
        MonitoringTab.render(),
      ]),
    ],
  );
}

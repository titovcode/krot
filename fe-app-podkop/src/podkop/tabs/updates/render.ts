export function render() {
  return E('div', { id: 'updates-status', class: 'pdk_updates-page' }, [
    E('div', {
      id: 'pdk_updates-top',
      class: 'pdk_updates-page__top',
    }),
    E('div', {
      id: 'pdk_updates-components',
      class: 'pdk_updates-page__components',
    }),
    E('table', {
      id: 'pdk_updates-hub-table',
      class: 'table cbi-section-table',
    }),
  ]);
}

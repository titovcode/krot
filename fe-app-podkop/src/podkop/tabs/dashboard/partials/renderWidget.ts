interface IRenderWidgetProps {
  loading: boolean;
  failed: boolean;
  title: string;
  items: Array<{
    key: string;
    value: string;
    attributes?: {
      class?: string;
    };
  }>;
}

function renderFailedState(title: string) {
  return E(
    'div',
    {
      id: '',
      class: 'ifacebox pdk_dashboard-page__widgets-section__item',
    },
    [
      E(
        'div',
        {
          class:
            'ifacebox-head center active pdk_dashboard-page__widgets-section__item__title',
        },
        E('strong', {}, title || _('Status')),
      ),
      E('div', { class: 'ifacebox-body left' }, _('Currently unavailable')),
    ],
  );
}

function renderLoadingState(title: string) {
  return renderDefaultState({
    loading: true,
    failed: false,
    title,
    items: [{ key: _('Status'), value: '...' }],
  });
}

function renderDefaultState({ title, items }: IRenderWidgetProps) {
  return E(
    'div',
    { class: 'ifacebox pdk_dashboard-page__widgets-section__item' },
    [
      E(
        'div',
        {
          class:
            'ifacebox-head center active pdk_dashboard-page__widgets-section__item__title',
        },
        E('strong', {}, title),
      ),
      E(
        'div',
        { class: 'ifacebox-body left' },
        items.map((item) =>
          E(
            'span',
            {
              class: `pdk_dashboard-page__widgets-section__item__row nowrap ${item?.attributes?.class || ''}`,
            },
            [
              E('strong', {}, `${item.key}: `),
              E(
                'span',
                {
                  class:
                    'pdk_dashboard-page__widgets-section__item__row__value',
                },
                item.value,
              ),
              E('br'),
            ],
          ),
        ),
      ),
    ],
  );
}

export function renderWidget(props: IRenderWidgetProps) {
  if (props.loading) {
    return props.items.length
      ? renderDefaultState(props)
      : renderLoadingState(props.title);
  }

  if (props.failed) {
    return renderFailedState(props.title);
  }

  return renderDefaultState(props);
}

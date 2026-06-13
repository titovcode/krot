import { renderButton } from '../../../../partials';
import { renderDownloadIcon24, renderUploadIcon24 } from '../../../../icons';

interface IRenderConfigBackupProps {
  exportLoading: boolean;
  importLoading: boolean;
  onExport: () => void;
  onImport: (config: string) => void;
}

export function renderConfigBackup({
  exportLoading,
  importLoading,
  onExport,
  onImport,
}: IRenderConfigBackupProps) {
  const fileInput = E('input', {
    type: 'file',
    accept: '.txt,.conf,.cfg',
    style: 'display:none',
    change: (e: Event) => {
      const input = e.target as HTMLInputElement;
      const file = input.files?.[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = (ev) => {
        const text = ev.target?.result;
        if (typeof text === 'string') {
          onImport(text);
        }
      };
      reader.readAsText(file);
      input.value = '';
    },
  }) as HTMLInputElement;

  return E('div', { class: 'pdk_diagnostic-page__right-bar__system-info' }, [
    E('b', { class: 'pdk_diagnostic-page__right-bar__system-info__title' }, _('Config backup')),
    fileInput,
    renderButton({
      onClick: onExport,
      icon: renderDownloadIcon24,
      text: _('Export config'),
      loading: exportLoading,
      disabled: exportLoading || importLoading,
    }),
    renderButton({
      onClick: () => fileInput.click(),
      icon: renderUploadIcon24,
      text: _('Import config'),
      loading: importLoading,
      disabled: exportLoading || importLoading,
    }),
  ]);
}

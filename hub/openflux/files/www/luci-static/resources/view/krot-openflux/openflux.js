'use strict';
'require view';
'require ui';
'require uci';
'require fs';
'require rpc';
'require dom';

const UCI_CONFIG = 'krot_openflux';
const INIT_SCRIPT = '/etc/init.d/krot-openflux';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: { name: 'krot-openflux' },
	expect: { '': {} },
});

const TRANSPORTS = {
	yandex:     { label: 'Yandex Docs (WS)',            needsUrl: 'doc-url',  hint: 'https://disk.yandex.ru/d/...' },
	vyandex:    { label: 'Yandex Volga (HTTP relay+WS)', needsUrl: 'doc-url',  hint: 'https://disk.yandex.ru/d/...' },
	oneme:      { label: 'MAX / OneMe (DataChannel)',   needsUrl: 'tokens' },
	cupsonline: { label: 'Cups.online (rooms)',         needsUrl: 'rooms',    hint: 'base64 room list printed by the exit node' },
	mailru:     { label: 'Mail.ru Docs (WS)',           needsUrl: 'doc-url',  hint: 'https://cloud.mail.ru/public/...' },
};

function toast(message, kind) {
	ui.addNotification(null, E('p', {}, message), kind || 'info');
}

function transportInfo(transport) {
	return TRANSPORTS[transport] || TRANSPORTS.yandex;
}

function copyText(text) {
	const textarea = document.createElement('textarea');
	textarea.value = text;
	textarea.style.position = 'fixed';
	textarea.style.opacity = '0';
	document.body.appendChild(textarea);
	textarea.select();

	try {
		document.execCommand('copy');
		toast(_('Copied to clipboard'), 'info');
	} catch (error) {
		toast(_('Failed to copy'), 'error');
	}

	document.body.removeChild(textarea);
}

function fieldRow(labelText, input) {
	return E('div', { style: 'display:flex;flex-direction:column;gap:4px;margin-bottom:10px' }, [
		E('label', { style: 'font-weight:600;font-size:12px;opacity:0.75' }, labelText),
		input,
	]);
}

function textInput(value, placeholder) {
	return E('input', {
		type: 'text',
		class: 'cbi-input-text',
		value: value || '',
		placeholder: placeholder || '',
		style: 'width:100%',
	});
}

function checkboxInput(value) {
	return E('input', { type: 'checkbox', checked: value ? '' : null });
}

function selectInput(options, value) {
	return E(
		'select',
		{ class: 'cbi-input-select', style: 'width:100%' },
		options.map(([optionValue, optionLabel]) =>
			E('option', { value: optionValue, selected: optionValue === value ? '' : null }, optionLabel),
		),
	);
}

function instanceStatusText(enabled, running) {
	if (!enabled) {
		return _('Disabled');
	}
	return running ? _('Running') : _('Starting');
}

return view.extend({
	load() {
		return Promise.all([
			uci.load(UCI_CONFIG),
			fs.exec(INIT_SCRIPT, ['status']).then((res) => `${res.stdout || ''}`.trim()).catch(() => ''),
		]);
	},

	handleService(action) {
		return fs
			.exec(INIT_SCRIPT, [action])
			.then(() => {
				toast(_('Service action completed: %s').format(action), 'info');
				return this.refreshPage();
			})
			.catch((error) => toast(_('Service action failed: %s').format(error && error.message ? error.message : action), 'error'));
	},

	refreshPage() {
		return Promise.all([this.load(), this.listRunningInstances()]).then(([data, runningInstanceNames]) => {
			const root = document.getElementById('openflux-root');
			if (root) {
				dom.content(root, this.renderContent(data, runningInstanceNames));
			}
		});
	},

	handleSaveInstance(sid, values) {
		const sectionId = sid || `of${Date.now().toString(36)}`;

		if (!sid) {
			uci.add(UCI_CONFIG, 'instance', sectionId);
		}

		['label', 'transport', 'exit_mode', 'url', 'max_token', 'max_uid', 'listen_port', 'codec', 'encryption_key', 'local_ip'].forEach((key) => {
			const value = `${values[key] || ''}`.trim();
			if (value) {
				uci.set(UCI_CONFIG, sectionId, key, value);
			} else {
				uci.unset(UCI_CONFIG, sectionId, key);
			}
		});

		uci.set(UCI_CONFIG, sectionId, 'enabled', values.enabled ? '1' : '0');
		uci.set(UCI_CONFIG, sectionId, 'debug', values.debug ? '1' : '0');

		return uci.save()
			.then(() => uci.apply())
			.then(() => fs.exec(INIT_SCRIPT, ['restart']).catch(() => null))
			.then(() => this.refreshPage());
	},

	handleRemoveInstance(sid) {
		if (!window.confirm(_('Delete instance %s?').format(sid))) {
			return Promise.resolve();
		}

		uci.remove(UCI_CONFIG, sid);

		return uci.save()
			.then(() => uci.apply())
			.then(() => fs.exec(INIT_SCRIPT, ['restart']).catch(() => null))
			.then(() => this.refreshPage());
	},

	handleSaveSettings(values) {
		const keys = ['bin_base', 'use_iptables', 'suppress_rst'];

		keys.forEach((key) => {
			const value = `${values[key] || ''}`.trim();
			if (value) {
				uci.set(UCI_CONFIG, 'settings', key, value);
			} else {
				uci.unset(UCI_CONFIG, 'settings', key);
			}
		});

		return uci.save()
			.then(() => uci.apply())
			.then(() => fs.exec(INIT_SCRIPT, ['restart']).catch(() => null))
			.then(() => this.refreshPage())
			.then(() => toast(_('Settings saved'), 'info'));
	},

	openInstanceModal(sid) {
		const isNew = !sid;
		const get = (key, fallback) => uci.get(UCI_CONFIG, sid, key) || fallback;
		const self = this;

		const inputs = {
			label: textInput(get('label', ''), _('My phone')),
			transport: selectInput(
				Object.entries(TRANSPORTS).map(([value, info]) => [value, info.label]),
				get('transport', 'yandex'),
			),
			exit_mode: selectInput(
				[
					['l3', _('l3: raw SNAT/DNAT (fast, needs root; Linux only)')],
					['l4', _('l4: gVisor proxy (works without root)')],
				],
				get('exit_mode', 'l3'),
			),
			url: textInput(get('url', ''), 'https://...'),
			max_token: textInput(get('max_token', ''), _('MAX authorization token')),
			max_uid: textInput(get('max_uid', ''), _('MAX user id')),
			listen_port: textInput(get('listen_port', '4545'), '4545'),
			codec: selectInput(
				[
					['batched', _('batched + zstd (default)')],
					['legacy', _('legacy per-packet LZ4 (old clients)')],
				],
				get('codec', 'batched'),
			),
			encryption_key: textInput(get('encryption_key', ''), _('optional shared secret (AES-256-GCM)')),
			local_ip: textInput(get('local_ip', ''), _('optional egress IP for l3 SNAT/RST filter')),
			enabled: checkboxInput(get('enabled', '1') !== '0'),
			debug: checkboxInput(get('debug', '0') === '1'),
		};

		const urlRow = fieldRow(_('Transport URL / rooms base64'), inputs.url);
		const tokenRow = fieldRow(_('MAX token'), inputs.max_token);
		const uidRow = fieldRow(_('MAX user ID'), inputs.max_uid);

		const syncRows = () => {
			const info = transportInfo(inputs.transport.value);
			const needs = info.needsUrl;
			urlRow.style.display = needs === 'doc-url' || needs === 'rooms' ? '' : 'none';
			if (needs === 'rooms') {
				inputs.url.placeholder = info.hint || '';
			} else if (needs === 'doc-url') {
				inputs.url.placeholder = info.hint || 'https://...';
			}
			tokenRow.style.display = needs === 'tokens' ? '' : 'none';
			uidRow.style.display = needs === 'tokens' ? '' : 'none';
		};

		inputs.transport.addEventListener('change', syncRows);
		syncRows();

		ui.showModal(isNew ? _('Add exit node instance') : _('Edit instance'), [
			E('div', { style: 'min-width:320px' }, [
				fieldRow(_('Name'), inputs.label),
				fieldRow(_('Transport'), inputs.transport),
				fieldRow(_('Exit mode'), inputs.exit_mode),
				urlRow,
				tokenRow,
				uidRow,
				fieldRow(
					_('Codec'),
					E('div', {}, [
						inputs.codec,
						E('small', { style: 'opacity:0.7' }, _('Must match the codec chosen on the client (OpenFluxAndroid).')),
					]),
				),
				fieldRow(_('l4 fallback SOCKS port (localhost only)'), inputs.listen_port),
				fieldRow(_('Encryption key'), inputs.encryption_key),
				fieldRow(_('Egress IP (l3)'), inputs.local_ip),
				E('div', { style: 'display:flex;gap:18px;margin-bottom:10px' }, [
					E('label', { style: 'display:flex;align-items:center;gap:6px' }, [inputs.enabled, _('Enabled')]),
					E('label', { style: 'display:flex;align-items:center;gap:6px' }, [inputs.debug, _('Debug logging')]),
				]),
			]),
			E('div', { class: 'button-row', style: 'display:flex;gap:8px;justify-content:flex-end' }, [
				E('button', { class: 'btn cbi-button cbi-button-neutral', type: 'button', click: () => ui.hideModal() }, _('Cancel')),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-positive',
						type: 'button',
						click: () => {
							const values = { enabled: inputs.enabled.checked, debug: inputs.debug.checked };
							['label', 'transport', 'exit_mode', 'url', 'max_token', 'max_uid', 'listen_port', 'codec', 'encryption_key', 'local_ip'].forEach((key) => {
								values[key] = inputs[key].value;
							});
							ui.hideModal();
							this.handleSaveInstance(sid, values);
						},
					},
					_('Save'),
				),
			]),
		]);
	},

	renderContent(data, runningInstanceNames) {
		const [, serviceStatus] = data;
		const instances = uci.sections(UCI_CONFIG, 'instance');
		const self = this;

		const serviceRunning = /running/.test(serviceStatus || '');
		runningInstanceNames = runningInstanceNames || [];

		const instanceRows = instances.map((section) => {
			const sid = section['.name'];
			const info = transportInfo(section.transport);
			const enabled = section.enabled !== '0';
			const running = enabled && runningInstanceNames.indexOf(sid) !== -1;

			return E('tr', { class: 'tr' }, [
				E('td', { class: 'td', 'data-title': _('Name') }, E('strong', {}, section.label || sid)),
				E('td', { class: 'td', 'data-title': _('Transport') }, info.label),
				E('td', { class: 'td', 'data-title': _('Exit mode') }, `${section.exit_mode || 'l3'}`.toUpperCase()),
				E('td', { class: 'td', 'data-title': _('State') }, [
					E('span', { style: `display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;background:${!enabled ? 'rgba(128,128,128,0.2)' : running ? 'rgba(55,169,105,0.2)' : 'rgba(221,160,44,0.2)'}` },
						instanceStatusText(enabled, running)),
				]),
				E('td', { class: 'td cbi-section-actions', style: 'white-space:nowrap' }, [
					E('button', { class: 'btn cbi-button cbi-button-edit', type: 'button', style: 'margin-right:4px', click: () => self.openInstanceModal(sid) }, _('Edit')),
					E('button', { class: 'btn cbi-button cbi-button-remove', type: 'button', click: () => self.handleRemoveInstance(sid) }, _('Delete')),
				]),
			]);
		});

		const binBase = uci.get(UCI_CONFIG, 'settings', 'bin_base') || '';
		const useIptables = uci.get(UCI_CONFIG, 'settings', 'use_iptables') === '1';
		const suppressRst = uci.get(UCI_CONFIG, 'settings', 'suppress_rst') !== '0';

		const settingsInputs = {
			bin_base: textInput(binBase, 'https://example.com/my-openflux-builds'),
			use_iptables: checkboxInput(useIptables),
			suppress_rst: checkboxInput(suppressRst),
		};

		return E('div', {}, [
			E('h2', {}, _('OpenFlux: exit node')),
			E('p', { style: 'opacity:0.8' }, _('Runs an OpenFlux exit node on the router. Phones running OpenFluxAndroid tunnel their traffic through whitelisted transports (Yandex Docs/Volga, MAX, Cups.online, Mail.ru) to this router and out through its WAN.')),

			E('div', { class: 'cbi-section', style: 'margin-bottom:18px' }, [
				E('h3', {}, _('Service')),
				E('div', { style: 'display:flex;align-items:center;gap:12px' }, [
					E('span', { style: `display:inline-block;padding:2px 10px;border-radius:4px;font-size:12px;background:${serviceRunning ? 'rgba(55,169,105,0.2)' : 'rgba(200,60,60,0.2)'}` }, serviceRunning ? _('running') : _('stopped')),
					E('button', { class: 'btn cbi-button', type: 'button', click: () => this.handleService('restart') }, _('Restart')),
					E('small', { style: 'opacity:0.7' }, _('Logs: logread -e krot-openflux')),
				]),
			]),

			E('div', { class: 'cbi-section', style: 'margin-bottom:18px' }, [
				E('h3', {}, _('Settings')),
				E('div', { style: 'display:flex;flex-direction:column;gap:10px;max-width:520px' }, [
					fieldRow(_('Binary base URL (bin_base)'), E('div', {}, [
						settingsInputs.bin_base,
						E('small', { style: 'opacity:0.7' }, _('URL serving openflux-linux-<arch> files. Empty = upstream releases (Linux assets are not published there yet). Build binaries with hub/openflux/build-binaries.sh.')),
					])),
					E('label', { style: 'display:flex;align-items:center;gap:6px' }, [
						settingsInputs.suppress_rst, _('Suppress kernel TCP RSTs (l3 mode, see OpenFlux issue #44)'),
					]),
					E('label', { style: 'display:flex;align-items:center;gap:6px' }, [
						settingsInputs.use_iptables, _('Use iptables instead of nftables'),
					]),
					E('div', {}, [
						E('button', { class: 'btn cbi-button cbi-button-positive', type: 'button', click: () => this.handleSaveSettings({
							bin_base: settingsInputs.bin_base.value,
							use_iptables: settingsInputs.use_iptables.checked ? '1' : '',
							suppress_rst: settingsInputs.suppress_rst.checked ? '1' : '0',
						}) }, _('Save settings')),
					]),
				]),
			]),

			E('div', { class: 'cbi-section', style: 'margin-bottom:18px' }, [
				E('h3', {}, _('Exit node instances')),
				E('table', { class: 'table' }, [
					E('tr', { class: 'tr table-titles' }, [
						E('th', { class: 'th' }, _('Name')),
						E('th', { class: 'th' }, _('Transport')),
						E('th', { class: 'th' }, _('Exit mode')),
						E('th', { class: 'th' }, _('State')),
						E('th', { class: 'th cbi-section-actions' }, ' '),
					]),
					...(instanceRows.length ? instanceRows : [E('tr', { class: 'tr placeholder' }, E('td', { class: 'td', colspan: 5 }, E('em', {}, _('No instances yet'))))]),
				]),
				E('div', { style: 'margin-top:10px' }, [
					E('button', { class: 'btn cbi-button cbi-button-positive', type: 'button', click: () => this.openInstanceModal(null) }, _('Add instance')),
				]),
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('How it works')),
				E('ol', { style: 'font-size:12px;opacity:0.85;line-height:1.7' }, [
					E('li', {}, _('Build or obtain an openflux-linux binary for this router (see hub/openflux/build-binaries.sh) and set bin_base, or copy it to /usr/lib/krot-openflux/bin/openflux.')),
					E('li', {}, _('Add an instance: pick a transport and paste its URL/token (Yandex doc URL, MAX token+uid, Cups.online rooms base64).')),
					E('li', {}, _('In l3 mode the router needs root (OpenWrt always has it); the runner suppresses kernel TCP RSTs automatically.')),
					E('li', {}, _('On the phone install OpenFluxAndroid and connect it to this router with the same transport/URL/codec.')),
				]),
			]),
		]);
	},

	listRunningInstances() {
		// procd names instances "krot-openflux-<section>"; parse ubus service list.
		return callServiceList().then((list) => {
			const instances = (list && list['krot-openflux'] && list['krot-openflux'].instances) || {};
			return Object.keys(instances).map((name) => `${name}`.replace(/^krot-openflux-/, ''));
		}).catch(() => []);
	},

	render(data) {
		return this.listRunningInstances().then((runningInstanceNames) =>
			E('div', { id: 'openflux-root' }, this.renderContent(data, runningInstanceNames)),
		);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
});

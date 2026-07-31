'use strict';
'require view';
'require ui';
'require uci';
'require fs';
'require dom';

const UCI_CONFIG = 'krot_wlb';
const INIT_SCRIPT = '/etc/init.d/krot-wlb';
const NOTIFY_SCRIPT = '/usr/lib/krot-wlb/wlb-notify.sh';
const YANDEX_LOGIN_SCRIPT = '/usr/lib/krot-wlb/wlb-yandex-login.sh';
const RUN_DIR = '/var/run/krot-wlb';
const YANDEX_LOGIN_DIR = `${RUN_DIR}/yandex-login`;

const PLATFORMS = {
	telemost: { label: 'Yandex Telemost', account: 'Yandex', cookies: '/etc/krot-wlb/cookies-yandex.json' },
	vk:       { label: 'VK Call',         account: 'VK',     cookies: '/etc/krot-wlb/cookies-vk.json' },
	wbstream: { label: 'WB Stream',       account: 'WB',     cookies: '/etc/krot-wlb/cookies-wbstream.json' },
	dion:     { label: 'DION',            account: 'DION',   cookies: '/etc/krot-wlb/cookies-dion.json' },
};

function linkFilePath(sid) {
	return `${RUN_DIR}/${sid}.link`;
}

function platformInfo(platform) {
	return PLATFORMS[platform] || PLATFORMS.telemost;
}

function toast(message, kind) {
	ui.addNotification(null, E('p', {}, message), kind || 'info');
}

/* ---------------------------------------------------------------------------
 * Minimal self-contained QR generator (error level L), SVG data-URI output.
 * Same implementation as in luci-app-krot's server view.
 * ------------------------------------------------------------------------- */

const QR_EC_CODEWORDS_PER_BLOCK_LOW = [
	-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28,
	28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
	30, 30,
];
const QR_NUM_ERROR_CORRECTION_BLOCKS_LOW = [
	-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10,
	12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
];

function qrGetBit(value, index) {
	return ((value >>> index) & 1) !== 0;
}

function qrAppendBits(buffer, value, length) {
	for (let i = length - 1; i >= 0; i -= 1) {
		buffer.push(qrGetBit(value, i));
	}
}

function qrRawDataModules(version) {
	let result = (16 * version + 128) * version + 64;

	if (version >= 2) {
		const numAlign = Math.floor(version / 7) + 2;
		result -= (25 * numAlign - 10) * numAlign - 55;
		if (version >= 7) {
			result -= 36;
		}
	}

	return result;
}

function qrRawCodewords(version) {
	return Math.floor(qrRawDataModules(version) / 8);
}

function qrDataCodewords(version) {
	return (
		qrRawCodewords(version) -
		QR_EC_CODEWORDS_PER_BLOCK_LOW[version] *
			QR_NUM_ERROR_CORRECTION_BLOCKS_LOW[version]
	);
}

function qrBuildDataCodewords(bytes, version) {
	const capacity = qrDataCodewords(version);
	const bits = [];
	const countBits = version <= 9 ? 8 : 16;

	qrAppendBits(bits, 4, 4);
	qrAppendBits(bits, bytes.length, countBits);
	bytes.forEach((value) => qrAppendBits(bits, value, 8));
	qrAppendBits(bits, 0, Math.min(4, capacity * 8 - bits.length));

	while (bits.length % 8 !== 0) {
		bits.push(false);
	}

	const result = [];
	for (let i = 0; i < bits.length; i += 8) {
		let value = 0;
		for (let j = 0; j < 8; j += 1) {
			value = (value << 1) | (bits[i + j] ? 1 : 0);
		}
		result.push(value);
	}

	for (let pad = 0xec; result.length < capacity; pad ^= 0xfd) {
		result.push(pad);
	}

	return result;
}

function qrMultiply(x, y) {
	let z = 0;

	for (let i = 7; i >= 0; i -= 1) {
		z = (z << 1) ^ ((z >>> 7) * 0x11d);
		z ^= ((y >>> i) & 1) * x;
	}

	return z;
}

function qrReedSolomonDivisor(degree) {
	const result = Array(degree).fill(0);
	result[degree - 1] = 1;

	let root = 1;
	for (let i = 0; i < degree; i += 1) {
		for (let j = 0; j < degree; j += 1) {
			result[j] = qrMultiply(result[j], root);
			if (j + 1 < degree) {
				result[j] ^= result[j + 1];
			}
		}
		root = qrMultiply(root, 2);
	}

	return result;
}

function qrReedSolomonRemainder(data, divisor) {
	const result = Array(divisor.length).fill(0);

	data.forEach((value) => {
		const factor = value ^ result.shift();
		result.push(0);
		for (let i = 0; i < result.length; i += 1) {
			result[i] ^= qrMultiply(divisor[i], factor);
		}
	});

	return result;
}

function qrAddErrorCorrection(data, version) {
	const numBlocks = QR_NUM_ERROR_CORRECTION_BLOCKS_LOW[version];
	const blockEccLen = QR_EC_CODEWORDS_PER_BLOCK_LOW[version];
	const rawCodewords = qrRawCodewords(version);
	const numShortBlocks = numBlocks - (rawCodewords % numBlocks);
	const shortBlockDataLen = Math.floor(rawCodewords / numBlocks) - blockEccLen;
	const divisor = qrReedSolomonDivisor(blockEccLen);
	const blocks = [];

	for (let i = 0, offset = 0; i < numBlocks; i += 1) {
		const dataLen = shortBlockDataLen + (i < numShortBlocks ? 0 : 1);
		const blockData = data.slice(offset, offset + dataLen);
		offset += dataLen;
		blocks.push({
			data: blockData,
			ecc: qrReedSolomonRemainder(blockData, divisor),
		});
	}

	const result = [];
	const maxDataLen = Math.max(...blocks.map((block) => block.data.length));

	for (let i = 0; i < maxDataLen; i += 1) {
		blocks.forEach((block) => {
			if (i < block.data.length) {
				result.push(block.data[i]);
			}
		});
	}

	for (let i = 0; i < blockEccLen; i += 1) {
		blocks.forEach((block) => result.push(block.ecc[i]));
	}

	return result;
}

function qrAlignmentPatternPositions(version) {
	if (version === 1) {
		return [];
	}

	const size = version * 4 + 17;
	const numAlign = Math.floor(version / 7) + 2;
	const step =
		version === 32 ? 26 : Math.ceil((version * 4 + 4) / (numAlign * 2 - 2)) * 2;
	const result = [6];

	for (let pos = size - 7; result.length < numAlign; pos -= step) {
		result.splice(1, 0, pos);
	}

	return result;
}

function qrMakeMatrix(version, dataCodewords) {
	const size = version * 4 + 17;
	const modules = Array.from({ length: size }, () => Array(size).fill(false));
	const isFunction = Array.from({ length: size }, () =>
		Array(size).fill(false),
	);

	function setFunction(x, y, dark) {
		modules[y][x] = dark;
		isFunction[y][x] = true;
	}

	function drawFinder(cx, cy) {
		for (let dy = -4; dy <= 4; dy += 1) {
			for (let dx = -4; dx <= 4; dx += 1) {
				const x = cx + dx;
				const y = cy + dy;
				if (x < 0 || x >= size || y < 0 || y >= size) {
					continue;
				}
				const dist = Math.max(Math.abs(dx), Math.abs(dy));
				setFunction(x, y, dist !== 2 && dist !== 4);
			}
		}
	}

	function drawAlignment(cx, cy) {
		for (let dy = -2; dy <= 2; dy += 1) {
			for (let dx = -2; dx <= 2; dx += 1) {
				setFunction(
					cx + dx,
					cy + dy,
					Math.max(Math.abs(dx), Math.abs(dy)) !== 1,
				);
			}
		}
	}

	drawFinder(3, 3);
	drawFinder(size - 4, 3);
	drawFinder(3, size - 4);

	for (let i = 8; i < size - 8; i += 1) {
		setFunction(6, i, i % 2 === 0);
		setFunction(i, 6, i % 2 === 0);
	}

	const alignPositions = qrAlignmentPatternPositions(version);
	alignPositions.forEach((x) => {
		alignPositions.forEach((y) => {
			const overlapsFinder =
				(x === 6 && y === 6) ||
				(x === 6 && y === size - 7) ||
				(x === size - 7 && y === 6);
			if (!overlapsFinder) {
				drawAlignment(x, y);
			}
		});
	});

	if (version >= 7) {
		let rem = version;
		for (let i = 0; i < 12; i += 1) {
			rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
		}
		const bits = (version << 12) | rem;
		for (let i = 0; i < 18; i += 1) {
			const bit = qrGetBit(bits, i);
			const a = size - 11 + (i % 3);
			const b = Math.floor(i / 3);
			setFunction(a, b, bit);
			setFunction(b, a, bit);
		}
	}

	function drawFormatBits(mask) {
		const formatData = (1 << 3) | mask;
		let rem = formatData;

		for (let i = 0; i < 10; i += 1) {
			rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
		}

		const formatBits = ((formatData << 10) | rem) ^ 0x5412;

		for (let i = 0; i <= 5; i += 1) {
			setFunction(8, i, qrGetBit(formatBits, i));
		}
		setFunction(8, 7, qrGetBit(formatBits, 6));
		setFunction(8, 8, qrGetBit(formatBits, 7));
		setFunction(7, 8, qrGetBit(formatBits, 8));
		for (let i = 9; i < 15; i += 1) {
			setFunction(14 - i, 8, qrGetBit(formatBits, i));
		}
		for (let i = 0; i < 8; i += 1) {
			setFunction(size - 1 - i, 8, qrGetBit(formatBits, i));
		}
		for (let i = 8; i < 15; i += 1) {
			setFunction(8, size - 15 + i, qrGetBit(formatBits, i));
		}
		setFunction(8, size - 8, true);
	}

	drawFormatBits(0);

	const codewords = qrAddErrorCorrection(dataCodewords, version);
	let bitIndex = 0;
	for (let right = size - 1; right >= 1; right -= 2) {
		if (right === 6) {
			right = 5;
		}
		for (let vert = 0; vert < size; vert += 1) {
			for (let j = 0; j < 2; j += 1) {
				const x = right - j;
				const upward = ((right + 1) & 2) === 0;
				const y = upward ? size - 1 - vert : vert;
				if (!isFunction[y][x] && bitIndex < codewords.length * 8) {
					modules[y][x] = qrGetBit(
						codewords[Math.floor(bitIndex / 8)],
						7 - (bitIndex % 8),
					);
					bitIndex += 1;
				}
			}
		}
	}

	for (let y = 0; y < size; y += 1) {
		for (let x = 0; x < size; x += 1) {
			if (!isFunction[y][x] && (x + y) % 2 === 0) {
				modules[y][x] = !modules[y][x];
			}
		}
	}

	drawFormatBits(0);

	return modules;
}

function qrSvgDataUri(text) {
	const bytes = Array.from(new TextEncoder().encode(text));
	let version = 1;

	for (; version <= 40; version += 1) {
		const countBits = version <= 9 ? 8 : 16;
		if (4 + countBits + bytes.length * 8 <= qrDataCodewords(version) * 8) {
			break;
		}
	}

	if (version > 40) {
		return '';
	}

	const matrix = qrMakeMatrix(version, qrBuildDataCodewords(bytes, version));
	const border = 4;
	const size = matrix.length;
	const viewSize = size + border * 2;
	const path = [];

	matrix.forEach((row, y) => {
		row.forEach((dark, x) => {
			if (dark) {
				path.push(`M${x + border},${y + border}h1v1h-1z`);
			}
		});
	});

	const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${viewSize} ${viewSize}" shape-rendering="crispEdges"><path fill="#fff" d="M0 0h${viewSize}v${viewSize}H0z"/><path fill="#000" d="${path.join(' ')}"/></svg>`;
	return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

/* ------------------------------------------------------------------------- */

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

function readActiveLink(sid) {
	return fs
		.read(linkFilePath(sid))
		.then((content) => {
			const lines = `${content || ''}`
				.split('\n')
				.map((line) => line.trim())
				.filter(Boolean);
			return lines.length ? lines[lines.length - 1] : '';
		})
		.catch(() => '');
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

return view.extend({
	load() {
		return Promise.all([
			uci.load(UCI_CONFIG),
			fs.exec(INIT_SCRIPT, ['status']).then((res) => `${res.stdout || ''}`.trim()).catch(() => ''),
			Promise.all(
				Object.keys(PLATFORMS).map((platform) =>
					fs
						.stat(platformInfo(platform).cookies)
						.then((stat) => [platform, stat && stat.size ? stat.size : 0])
						.catch(() => [platform, 0]),
				),
			),
			Promise.all(
				uci.sections(UCI_CONFIG, 'instance').map((section) =>
					readActiveLink(section['.name']),
				),
			),
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
		return this.load().then((data) => {
			const root = document.getElementById('wlb-root');
			if (root) {
				dom.content(root, this.renderContent(data));
			}
		});
	},

	handleSaveInstance(sid, values) {
		const sectionId = sid || `w${Date.now().toString(36)}`;

		if (!sid) {
			uci.add(UCI_CONFIG, 'instance', sectionId);
		}

		const stringOptions = [
			'label',
			'platform',
			'resources',
			'cookies',
			'upstream_socks',
			'notify_telegram_token',
			'notify_telegram_chat',
			'notify_ntfy',
			'notify_cmd',
		];

		stringOptions.forEach((key) => {
			const value = `${values[key] || ''}`.trim();
			if (value) {
				uci.set(UCI_CONFIG, sectionId, key, value);
			} else {
				uci.unset(UCI_CONFIG, sectionId, key);
			}
		});

		uci.set(UCI_CONFIG, sectionId, 'enabled', values.enabled ? '1' : '0');
		uci.set(UCI_CONFIG, sectionId, 'rejoin', values.rejoin ? '1' : '0');
		uci.set(UCI_CONFIG, sectionId, 'notify_via_proxy', values.notify_via_proxy ? '1' : '0');

		return uci
			.save(UCI_CONFIG)
			.then(() => fs.exec(INIT_SCRIPT, ['reload']))
			.then(() => this.refreshPage())
			.then(() => toast(_('Instance saved'), 'info'))
			.catch((error) => toast(_('Failed to save: %s').format(error && error.message ? error.message : ''), 'error'));
	},

	handleRemoveInstance(sid) {
		if (!window.confirm(_('Delete this instance? The phone using it will lose access.'))) {
			return Promise.resolve();
		}

		uci.remove(UCI_CONFIG, sid);
		return uci
			.save(UCI_CONFIG)
			.then(() => fs.exec(INIT_SCRIPT, ['reload']))
			.then(() => this.refreshPage());
	},

	openInstanceModal(sid) {
		const isNew = !sid;
		const get = (key, fallback) => (sid ? uci.get(UCI_CONFIG, sid, key) || fallback : fallback);

		const inputs = {
			label: textInput(get('label', ''), _('e.g. My phone')),
			platform: selectInput(
				Object.entries(PLATFORMS).map(([value, info]) => [value, info.label]),
				get('platform', 'telemost'),
			),
			resources: selectInput(
				[
					['moderate', _('Moderate (64 MB, recommended for routers)')],
					['default', _('Default (128 MB)')],
					['unlimited', _('Unlimited (256 MB)')],
				],
				get('resources', 'moderate'),
			),
			cookies: textInput(get('cookies', ''), platformInfo(get('platform', 'telemost')).cookies),
			upstream_socks: textInput(get('upstream_socks', ''), '127.0.0.1:4534'),
			notify_telegram_token: textInput(get('notify_telegram_token', ''), _('Bot token (optional)')),
			notify_telegram_chat: textInput(get('notify_telegram_chat', ''), _('Chat ID (optional)')),
			notify_ntfy: textInput(get('notify_ntfy', ''), 'https://ntfy.sh/my-topic'),
			notify_cmd: textInput(get('notify_cmd', ''), _('Custom command, link in $WLB_LINK')),
			enabled: checkboxInput(get('enabled', '1') !== '0'),
			rejoin: checkboxInput(get('rejoin', '1') !== '0'),
			notify_via_proxy: checkboxInput(get('notify_via_proxy', '0') === '1'),
		};

		inputs.platform.addEventListener('change', () => {
			if (!`${inputs.cookies.value || ''}`.trim()) {
				inputs.cookies.placeholder = platformInfo(inputs.platform.value).cookies;
			}
		});

		ui.showModal(isNew ? _('Add mobile device') : _('Edit instance'), [
			E('div', { style: 'min-width:320px' }, [
				fieldRow(_('Name'), inputs.label),
				fieldRow(_('Platform'), inputs.platform),
				fieldRow(_('Resource mode'), inputs.resources),
				fieldRow(_('Cookies file'), inputs.cookies),
				fieldRow(
					_('Upstream SOCKS (egress)'),
					E('div', {}, [
						inputs.upstream_socks,
						E('small', { style: 'opacity:0.7' }, _('Leave empty for direct egress. Use 127.0.0.1:4534 to route the phone traffic through the K.R.O.T. rules.')),
					]),
				),
				E('div', { style: 'display:flex;gap:18px;margin-bottom:10px' }, [
					E('label', { style: 'display:flex;align-items:center;gap:6px' }, [inputs.enabled, _('Enabled')]),
					E('label', { style: 'display:flex;align-items:center;gap:6px' }, [inputs.rejoin, _('Keep link across restarts')]),
					E('label', { style: 'display:flex;align-items:center;gap:6px' }, [inputs.notify_via_proxy, _('Notify via K.R.O.T. proxy')]),
				]),
				E('h4', { style: 'margin:12px 0 6px' }, _('Link update notifications')),
				E('small', { style: 'opacity:0.7;display:block;margin-bottom:8px' }, _('When the conference link changes, the module pushes the new one to all configured targets.')),
				fieldRow(_('Telegram bot token'), inputs.notify_telegram_token),
				fieldRow(_('Telegram chat ID'), inputs.notify_telegram_chat),
				fieldRow(_('ntfy topic URL (pushes to macOS/iOS/Android app)'), inputs.notify_ntfy),
				fieldRow(_('Custom notify command'), inputs.notify_cmd),
			]),
			E('div', { class: 'button-row', style: 'display:flex;gap:8px;justify-content:flex-end' }, [
				E('button', { class: 'btn cbi-button cbi-button-neutral', type: 'button', click: () => ui.hideModal() }, _('Cancel')),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-positive',
						type: 'button',
						click: () => {
							const values = { enabled: inputs.enabled.checked, rejoin: inputs.rejoin.checked, notify_via_proxy: inputs.notify_via_proxy.checked };
							['label', 'platform', 'resources', 'cookies', 'upstream_socks', 'notify_telegram_token', 'notify_telegram_chat', 'notify_ntfy', 'notify_cmd'].forEach((key) => {
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

	openQrModal(sid) {
		const label = uci.get(UCI_CONFIG, sid, 'label') || sid;

		readActiveLink(sid).then((link) => {
			if (!link) {
				ui.showModal(_('Connection link'), [
					E('p', {}, _('No active link yet. The creator is probably still starting up (or authorization failed). Give it 10-20 seconds and try again. Check: logread -e krot-wlb')),
					E('div', { class: 'button-row' }, [
						E('button', { class: 'btn cbi-button cbi-button-neutral', type: 'button', click: () => ui.hideModal() }, _('Close')),
					]),
				]);
				return;
			}

			const qr = qrSvgDataUri(link);
			ui.showModal(_('Scan with the mobile app'), [
				E('div', { style: 'display:flex;flex-direction:column;align-items:center;gap:14px' }, [
					E('div', { style: 'font-weight:600' }, label),
					qr
						? E('img', { src: qr, alt: 'QR', style: 'width:220px;height:220px;image-rendering:pixelated' })
						: E('em', {}, _('QR code is too large')),
					E('textarea', { class: 'cbi-input-textarea', readonly: 'readonly', rows: 2, style: 'width:100%;font-family:monospace;font-size:11px', click: (ev) => ev.currentTarget.select() }, link),
					E('small', { style: 'opacity:0.7' }, _('whitelist-bypass app: tap the QR button and point the camera here. One instance serves exactly one phone.')),
				]),
				E('div', { class: 'button-row', style: 'display:flex;gap:8px;justify-content:flex-end' }, [
					E('button', { class: 'btn cbi-button cbi-button-neutral', type: 'button', click: () => copyText(link) }, _('Copy link')),
					E('button', { class: 'btn cbi-button cbi-button-neutral', type: 'button', click: () => ui.hideModal() }, _('Close')),
				]),
			]);
		});
	},

	openCookiesModal(platform) {
		const info = platformInfo(platform);
		const path = info.cookies;

		fs.read(path)
			.catch(() => '')
			.then((current) => {
				const textarea = E(
					'textarea',
					{ class: 'cbi-input-textarea', rows: 10, style: 'width:100%;font-family:monospace;font-size:11px', placeholder: '[{"name":"Session_id","value":"..."}, ...]' },
					current || '',
				);

				ui.showModal(_('%s authorization (%s)').format(info.label, info.account), [
					E('div', { style: 'min-width:340px' }, [
						E('p', { style: 'font-size:12px' }, [
							_('Paste the cookies JSON exported from the whitelist-bypass desktop app (Export Cookies button) or from a browser extension.'),
							' ',
							_('For Telemost this is your Yandex account cookies (Session_id and friends). File: %s').format(path),
						]),
						textarea,
					]),
					E('div', { class: 'button-row', style: 'display:flex;gap:8px;justify-content:flex-end' }, [
						E('button', { class: 'btn cbi-button cbi-button-neutral', type: 'button', click: () => ui.hideModal() }, _('Cancel')),
						E(
							'button',
							{
								class: 'btn cbi-button cbi-button-positive',
								type: 'button',
								click: () => {
									ui.hideModal();
									fs.write(path, textarea.value)
										.then(() => fs.exec('/bin/chmod', ['600', path]))
										.then(() => fs.exec(INIT_SCRIPT, ['reload']))
										.then(() => this.refreshPage())
										.then(() => toast(_('Cookies saved; instances restarted'), 'info'))
										.catch((error) => toast(_('Failed to save cookies: %s').format(error && error.message ? error.message : ''), 'error'));
								},
							},
							_('Save'),
						),
					]),
				]);
			});
	},

	openYandexLoginModal() {
		const STATUS_FILE = `${YANDEX_LOGIN_DIR}/status`;
		const STATE_FILE = `${YANDEX_LOGIN_DIR}/state`;
		const QR_FILE = `${YANDEX_LOGIN_DIR}/qr.txt`;

		let timer = null;
		let qrRendered = false;

		const qrBox = E(
			'div',
			{ style: 'display:flex;justify-content:center;align-items:center;min-height:230px' },
			E('em', {}, _('Starting the login flow...')),
		);
		const statusLine = E('div', { style: 'text-align:center;font-weight:600' }, '');
		const stateLine = E('div', { style: 'text-align:center;font-size:11px;opacity:0.6' }, '');

		const stopPolling = () => {
			if (timer) {
				window.clearInterval(timer);
				timer = null;
			}
		};

		const cancel = () => {
			stopPolling();
			fs.exec(YANDEX_LOGIN_SCRIPT, ['stop']).catch(() => null);
			ui.hideModal();
		};

		const renderQr = (link) => {
			const qr = qrSvgDataUri(link);
			dom.content(
				qrBox,
				qr
					? E('img', { src: qr, alt: 'Yandex login QR', style: 'width:230px;height:230px;image-rendering:pixelated' })
					: E('em', {}, _('QR code is too large')),
			);
			qrRendered = true;
		};

		const poll = () => {
			// Stop if the modal was closed by other means.
			if (!document.querySelector('#modal_overlay .modal')) {
				stopPolling();
				return;
			}

			fs.read(STATUS_FILE)
				.catch(() => '')
				.then((raw) => {
					const status = `${raw || ''}`.trim();
					if (!status || status === 'idle') {
						return;
					}

					if (status === 'waiting') {
						statusLine.textContent = _('Scan the QR code with the Yandex app and confirm the login');
						if (!qrRendered) {
							fs.read(QR_FILE)
								.then((link) => renderQr(`${link || ''}`.trim()))
								.catch(() => null);
						}
						fs.read(STATE_FILE)
							.catch(() => '')
							.then((state) => {
								stateLine.textContent = `${state || ''}`.trim();
							});
						return;
					}

					if (status === 'authorized') {
						statusLine.textContent = _('Confirmed, saving cookies...');
						return;
					}

					if (status === 'done') {
						stopPolling();
						ui.hideModal();
						toast(_('Yandex authorization saved; restarting instances'), 'info');
						fs.exec(INIT_SCRIPT, ['reload'])
							.catch(() => null)
							.then(() => this.refreshPage());
						return;
					}

					if (status.startsWith('error')) {
						stopPolling();
						statusLine.textContent = _('Login failed: %s').format(status.slice(6) || status);
						statusLine.style.color = '#c0392b';
					}
				});
		};

		ui.showModal(_('Login with Yandex (QR)'), [
			E('div', { style: 'display:flex;flex-direction:column;gap:12px;min-width:300px' }, [
				E('p', { style: 'font-size:12px;margin:0' }, _('Open the Yandex app on your phone (where you are logged in), tap the scanner and point it at this QR code. No password is typed anywhere.')),
				qrBox,
				statusLine,
				stateLine,
			]),
			E('div', { class: 'button-row', style: 'display:flex;justify-content:flex-end' }, [
				E('button', { class: 'btn cbi-button cbi-button-neutral', type: 'button', click: cancel }, _('Cancel')),
			]),
		]);

		fs.exec(YANDEX_LOGIN_SCRIPT, ['start'])
			.then(() => {
				timer = window.setInterval(poll, 2000);
				poll();
			})
			.catch((error) => {
				dom.content(qrBox, E('em', {}, _('Failed to start the login flow')));
				statusLine.textContent = (error && error.message) || '';
				statusLine.style.color = '#c0392b';
			});
	},

	handleDeleteCookies(platform) {
		const path = platformInfo(platform).cookies;
		if (!window.confirm(_('Delete %s?').format(path))) {
			return Promise.resolve();
		}
		return fs
			.write(path, '')
			.then(() => fs.exec(INIT_SCRIPT, ['reload']))
			.then(() => this.refreshPage());
	},

	handlePushLink(sid) {
		return readActiveLink(sid).then((link) => {
			if (!link) {
				toast(_('No active link to push'), 'warning');
				return;
			}
			return fs
				.exec(NOTIFY_SCRIPT, [sid, link])
				.then(() => toast(_('Link pushed to the configured targets'), 'info'))
				.catch(() => toast(_('Push failed (check notification settings)'), 'error'));
		});
	},

	renderContent(data) {
		const [, serviceStatus, cookieStats, instanceLinks] = data;
		const cookieSizes = Object.fromEntries(cookieStats || []);
		const instances = uci.sections(UCI_CONFIG, 'instance');

		const serviceRunning = /running/.test(serviceStatus || '');

		const instanceRows = instances.map((section, index) => {
			const sid = section['.name'];
			const info = platformInfo(section.platform);
			const enabled = section.enabled !== '0';
			const hasLink = Boolean((instanceLinks || [])[index]);

			return E('tr', { class: 'tr' }, [
				E('td', { class: 'td', 'data-title': _('Name') }, E('strong', {}, section.label || sid)),
				E('td', { class: 'td', 'data-title': _('Platform') }, info.label),
				E('td', { class: 'td', 'data-title': _('State') }, [
					E('span', { style: `display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;background:${enabled ? (hasLink ? 'rgba(55,169,105,0.2)' : 'rgba(221,160,44,0.2)') : 'rgba(128,128,128,0.2)'}` },
						!enabled ? _('Disabled') : hasLink ? _('Link ready') : _('Starting')),
				]),
				E('td', { class: 'td cbi-section-actions', style: 'white-space:nowrap' }, [
					E('button', { class: 'btn cbi-button', type: 'button', style: 'margin-right:4px', title: _('Show QR code'), click: () => this.openQrModal(sid) }, 'QR'),
					E('button', { class: 'btn cbi-button', type: 'button', style: 'margin-right:4px', title: _('Push the link to configured targets now'), click: () => this.handlePushLink(sid) }, '⇪'),
					E('button', { class: 'btn cbi-button cbi-button-edit', type: 'button', style: 'margin-right:4px', click: () => this.openInstanceModal(sid) }, _('Edit')),
					E('button', { class: 'btn cbi-button cbi-button-remove', type: 'button', click: () => this.handleRemoveInstance(sid) }, _('Delete')),
				]),
			]);
		});

		const cookieRows = Object.entries(PLATFORMS).map(([platform, info]) => {
			const size = cookieSizes[platform] || 0;
			return E('tr', { class: 'tr' }, [
				E('td', { class: 'td', 'data-title': _('Platform') }, [E('strong', {}, info.account), E('br'), E('small', { style: 'opacity:0.7' }, info.label)]),
				E('td', { class: 'td', 'data-title': _('File') }, E('code', { style: 'font-size:11px' }, info.cookies)),
				E('td', { class: 'td', 'data-title': _('Status') }, size > 0 ? _('Saved (%d bytes)').format(size) : E('em', {}, _('Not set'))),
				E('td', { class: 'td cbi-section-actions', style: 'white-space:nowrap' }, [
					platform === 'telemost'
						? E('button', { class: 'btn cbi-button cbi-button-action important', type: 'button', style: 'margin-right:4px', title: _('Login with the Yandex app by scanning a QR code'), click: () => this.openYandexLoginModal() }, _('QR Login'))
						: '',
					E('button', { class: 'btn cbi-button cbi-button-edit', type: 'button', style: 'margin-right:4px', click: () => this.openCookiesModal(platform) }, size > 0 ? _('Replace') : _('Paste')),
					size > 0
						? E('button', { class: 'btn cbi-button cbi-button-remove', type: 'button', click: () => this.handleDeleteCookies(platform) }, _('Delete'))
						: '',
				]),
			]);
		});

		return E('div', {}, [
			E('h2', {}, _('Whitelist Bypass: mobile access')),
			E('p', { style: 'opacity:0.8' }, _('Tunnels mobile traffic through whitelisted video-call platforms (Yandex Telemost, VK Call, WB Stream, DION). The router is the tunnel creator; phones join by scanning a QR code. One instance = one phone.')),

			E('div', { class: 'cbi-section', style: 'margin-bottom:18px' }, [
				E('h3', {}, _('Service')),
				E('div', { style: 'display:flex;align-items:center;gap:12px' }, [
					E('span', { style: `display:inline-block;padding:2px 10px;border-radius:4px;font-size:12px;background:${serviceRunning ? 'rgba(55,169,105,0.2)' : 'rgba(200,60,60,0.2)'}` }, serviceRunning ? _('running') : _('stopped')),
					E('button', { class: 'btn cbi-button', type: 'button', click: () => this.handleService('restart') }, _('Restart')),
					E('small', { style: 'opacity:0.7' }, _('Logs: logread -e krot-wlb')),
				]),
			]),

			E('div', { class: 'cbi-section', style: 'margin-bottom:18px' }, [
				E('h3', {}, _('Authorization (cookies)')),
				E('p', { style: 'font-size:12px;opacity:0.8' }, _('Export cookies from the whitelist-bypass desktop app (Export Cookies) or a browser extension and paste them here. Stored on the router with mode 600.')),
				E('table', { class: 'table' }, [
					E('tr', { class: 'tr table-titles' }, [
						E('th', { class: 'th' }, _('Platform')),
						E('th', { class: 'th' }, _('File')),
						E('th', { class: 'th' }, _('Status')),
						E('th', { class: 'th cbi-section-actions' }, ' '),
					]),
					...cookieRows,
				]),
			]),

			E('div', { class: 'cbi-section', style: 'margin-bottom:18px' }, [
				E('h3', {}, _('Mobile devices (instances)')),
				E('table', { class: 'table' }, [
					E('tr', { class: 'tr table-titles' }, [
						E('th', { class: 'th' }, _('Name')),
						E('th', { class: 'th' }, _('Platform')),
						E('th', { class: 'th' }, _('State')),
						E('th', { class: 'th cbi-section-actions' }, ' '),
					]),
					...(instanceRows.length ? instanceRows : [E('tr', { class: 'tr placeholder' }, E('td', { class: 'td', colspan: 4 }, E('em', {}, _('No instances yet'))))]),
				]),
				E('div', { style: 'margin-top:10px' }, [
					E('button', { class: 'btn cbi-button cbi-button-positive', type: 'button', click: () => this.openInstanceModal(null) }, _('Add mobile device')),
				]),
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('How it works')),
				E('ol', { style: 'font-size:12px;opacity:0.85;line-height:1.7' }, [
					E('li', {}, _('Paste cookies for the platform (Yandex for Telemost).')),
					E('li', {}, _('Add a mobile device; the router creates a video call through the whitelisted platform.')),
					E('li', {}, _('Press QR and scan it with the whitelist-bypass mobile app. All phone traffic now looks like a video call.')),
					E('li', {}, _('If the call link changes, the module pushes the new one to Telegram / ntfy / your custom command automatically.')),
				]),
			]),
		]);
	},

	render(data) {
		return E('div', { id: 'wlb-root' }, this.renderContent(data));
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
});

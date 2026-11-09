'use strict';

'require view';
'require form';
'require dom';
'require uci';
'require rpc';
'require poll';
'require ui';


/* =========================================================
 * Раздел: Глобальное состояние
 * =========================================================
 */

var cfg_tcp_v4 = [];
var cfg_tcp_v6 = [];
var cfg_udp_v4 = [];
var cfg_udp_v6 = [];

var backup_tcp_v4 = [];
var backup_tcp_v6 = [];
var backup_udp_v4 = [];
var backup_udp_v6 = [];

var subscriptionNames = {};
var subscriptionRoles = {};
var subscriptionMetadata = {};

var runtimeOutboundsPromise = null;
var runtimeOutboundsLogSnapshot = null;
var balancerRuntimeCfg = null;
var balancerServerSections = null;
var balancerServerSectionsGeneration = null;
var balancerMetadataRefreshPromise = null;
var balancerMetadataRefreshRetryAfter = 0;
var lastBalancerPollData = null;
var runtimeSnapshotWarningShown = false;
var balancerPollStarted = false;
var manualRefreshRequestPending = false;
var manualRefreshLastStatus = null;
var manualRefreshStatusGeneration = 0;
var manualRefreshRequestAt = 0;
var manualRefreshAwaitingStatus = false;
var manualRefreshPollStarted = false;
var pendingChanges = {
	xrayCore: false,
	xrayExt: false
};

var BALANCER_POLL_INTERVAL = 5;
/* Current-selection tags are comparatively expensive: each xray CLI call costs ~0.4 s on this router. */
/* Query one balancer per cycle; four balancers are refreshed every ~20 seconds. */
var BALANCER_SELECTION_POLL_INTERVAL = 5;
var balancerCurrentTags = [ null, null, null, null ];
var balancerCurrentTagsPromise = null;
var balancerCurrentTagIndex = 0;
var balancerFastRefreshPromise = null;
/* Set during render from the existing IPv6 availability check. */
var ipv6_enabled = false;

/* =========================================================
 * Раздел: Дополнительные стили
 * =========================================================
 */

function addCustomStyles() {
    if (document.getElementById('xray-ext-styles'))
        return;

    var style = E(
        'style',
        { 'id': 'xray-ext-styles' },
        `
        .cbi-section-table {
            width: 100%;
        }

        .cbi-section-table td[data-name="url"] {
            width: 500px;
            max-width: 25vw;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .xray-ext-server-missing td {
            color: #ccc !important;
        }

        .xray-ext-server-missing td code,
        .xray-ext-server-missing td strong {
            color: inherit !important;
        }

        .xray-ext-subscription-meta td {
            background: rgba(127, 127, 127, 0.08);
            white-space: normal;
        }

        .xray-ext-subscription-meta .meta-title {
            font-weight: bold;
            margin-bottom: 0.25em;
        }

        .xray-ext-subscription-meta .meta-details {
            display: flex;
            flex-wrap: wrap;
            gap: 0.35em 1.2em;
        }

        .xray-ext-subscription-meta .meta-announce {
            margin-top: 0.35em;
            white-space: pre-wrap;
        }

        .xray-ext-manual-refresh {
            display: flex;
            align-items: center;
            flex-wrap: wrap;
            gap: 0.7em 1em;
            padding: 0.2em 0;
        }

        .xray-ext-manual-refresh-status {
            display: inline-block;
            max-width: 100%;
        }

		.xray-ext-server-cb:indeterminate {
		    appearance: none;
		    -webkit-appearance: none;
		    position: relative;
		}

		.xray-ext-server-cb:indeterminate::after {
		    content: '';
		    position: absolute;
		    height: 10px;
		    background: currentColor;
		}
        `
    );

    document.head.appendChild(style);
}

/* =========================================================
 * Раздел: RPC
 * =========================================================
 */

var exec = rpc.declare({
    object: 'file',
    method: 'exec',
    params: [ 'command', 'params' ]
});

var xrayExtdRefresh = rpc.declare({
    object: 'xray_extd',
    method: 'refresh',
    params: []
});

var xrayExtdStatus = rpc.declare({
    object: 'xray_extd',
    method: 'status',
    params: []
});

/* Читаем актуальные секции xray_core напрямую через ubus.
 * Не делаем uci.unload()/uci.load(), чтобы не затронуть локальные изменения формы.
 */
var getFreshXrayServers = rpc.declare({
    object: 'uci',
    method: 'get',
    params: [ 'config', 'type' ],
    expect: { values: {} },
    reject: true
});

function manualRefreshIsBusy(status) {
    return !!status && [ 'queued', 'waiting_wan', 'running' ].indexOf(status.state) !== -1;
}

function manualRefreshButtonLabel(state) {
    switch (state) {
    case 'queued':
        return _('Queued…');
    case 'waiting_wan':
        return _('Waiting for WAN…');
    case 'running':
        return _('Refreshing…');
    default:
        return _('Refresh now');
    }
}

function updateManualRefreshPanel(status, container) {
    container = container || document.getElementById('xray-extd-manual-refresh-panel');
    if (!container || !status)
        return;

    var button = container.querySelector('#xray-extd-manual-refresh-button');
    var output = container.querySelector('#xray-extd-manual-refresh-status');
    if (!button || !output)
        return;

    var state = status.state || 'unknown';
    var total = Number(status.total || 0);
    var completed = Number(status.completed || 0);
    var succeeded = Number(status.succeeded || 0);
    var failed = Number(status.failed || 0);
    var message;

	switch (state) {
	case 'idle':
	    message = _('Ready to start. No update has been requested yet.');
	    break;
	case 'queued':
	    message = _('Request accepted, waiting for execution…');
	    break;
	case 'waiting_wan':
	    message = _('WAN is unavailable. The request is waiting for the connection to be restored.');
	    break;
	case 'running':
	    message = total > 0
	        ? _('Subscription update: processed %d of %d; successful: %d, failed: %d.')
	            .format(completed, total, succeeded, failed)
	        : _('Subscription update is in progress. Waiting for result data…');
	    break;
	case 'done':
	    message = total === 0
	        ? _('There are no enabled subscriptions to update.')
	        : _('Update completed: processed %d of %d; successful: %d, failed: %d.')
	            .format(completed, total, succeeded, failed);
	    break;
	case 'done_with_errors':
	    message = _('Update completed with errors: processed %d of %d; successful: %d, failed: %d.')
	        .format(completed, total, succeeded, failed);
	    break;
	default:
	    message = status.message || _('Unknown update status.');
	    break;
	}

	if ((state === 'done' || state === 'done_with_errors') && Number(status.finished_at) > 0) {
	    message += ' ' + _('Completed: %s.').format(
	        new Date(Number(status.finished_at) * 1000).toLocaleString()
	    );
	}

    output.textContent = message;
    button.textContent = manualRefreshButtonLabel(state);
    button.disabled = manualRefreshRequestPending || manualRefreshIsBusy(status);
    button.classList.toggle('spinning', state === 'running');
}

function readManualRefreshStatus(container) {
    var generation = manualRefreshStatusGeneration;

    return xrayExtdStatus()
        .then(function(status) {
            /* Ответ от опроса, начавшегося до нажатия кнопки, уже устарел. */
            if (generation !== manualRefreshStatusGeneration)
                return null;

            if (manualRefreshAwaitingStatus) {
                var state = status.state || 'unknown';
                var requestedAt = Number(status.requested_at || 0);
                var terminal = state === 'done' || state === 'done_with_errors';

                /* Не позволяем запоздалому ответу со старым idle/результатом
                 * затереть только что подтверждённый запрос. */
                if (state === 'idle' ||
                    (terminal && requestedAt > 0 && requestedAt < manualRefreshRequestAt)) {
                    return null;
                }

                manualRefreshAwaitingStatus = false;
            }

            manualRefreshLastStatus = status;
            manualRefreshRequestPending = manualRefreshIsBusy(status);
            updateManualRefreshPanel(status, container);

            return status;
        })
        .catch(function(err) {
            if (generation !== manualRefreshStatusGeneration)
                return null;

            console.warn('[Xray Extender] Cannot read manual refresh status; will retry:', err);

            var panel = container || document.getElementById('xray-extd-manual-refresh-panel');
            if (!panel)
                return null;

            var output = panel.querySelector('#xray-extd-manual-refresh-status');
            var button = panel.querySelector('#xray-extd-manual-refresh-button');
            var activeRequest = manualRefreshRequestPending || manualRefreshIsBusy(manualRefreshLastStatus);

            if (activeRequest) {
                if (output) {
                    output.textContent = _('The request has been sent, but status polling is temporarily unavailable. The daemon may be busy with network processing; waiting for completion and automatically retrying…');
                }
                if (button) {
                    button.disabled = true;
                    button.textContent = manualRefreshButtonLabel(
                        manualRefreshIsBusy(manualRefreshLastStatus)
                            ? manualRefreshLastStatus.state
                            : 'running'
                    );
                }
            }
            else if (!manualRefreshLastStatus) {
                if (output) {
                    output.textContent = _('Failed to read daemon status. Retrying automatically; if the error persists, check the xray_extd.status ACL and the connection to rpcd.');
                }
                if (button) {
                    button.disabled = false;
                    button.textContent = _('Refresh now');
                }

            }
            /* При временной ошибке после завершения сохраняем последнее известное состояние,
             * чтобы интерфейс не мигал и не показывал ложную ошибку ACL. */

            return null;
        });
}

function requestManualRefresh() {
    var panel = document.getElementById('xray-extd-manual-refresh-panel');
    var button = panel && panel.querySelector('#xray-extd-manual-refresh-button');
    var output = panel && panel.querySelector('#xray-extd-manual-refresh-status');

    if (manualRefreshRequestPending || manualRefreshIsBusy(manualRefreshLastStatus))
        return Promise.resolve();

    manualRefreshStatusGeneration++;
    manualRefreshRequestAt = Math.floor(Date.now() / 1000);
    manualRefreshAwaitingStatus = true;
    manualRefreshRequestPending = true;
    if (button) {
        button.disabled = true;
        button.textContent = _('Sending…');
    }
    if (output)
        output.textContent = _('Sending request to daemon…');

    return xrayExtdRefresh()
        .then(function(result) {
            if (result && result.accepted === false) {
                manualRefreshStatusGeneration++;
                var state = result.state || 'unknown';
                manualRefreshAwaitingStatus = false;
                manualRefreshRequestPending = manualRefreshIsBusy({ state: state });

                if (manualRefreshRequestPending) {
                    if (output)
                        output.textContent = _('An update is already in progress. Connecting to its current status…');
                    if (button) {
                        button.disabled = true;
                        button.textContent = manualRefreshButtonLabel(state);
                    }
                }
                else {
                    if (output)
                        output.textContent = result.message || _('The daemon did not accept the update request.');
                    if (button) {
                        button.disabled = false;
                        button.textContent = _('Refresh now');
                    }
                }

                return result;

            }

            if (result && result.accepted === true) {
                /* Не запрашиваем status немедленно: он может вернуть старое состояние
                 * до следующего цикла демона и затереть только что показанный ответ. */
                updateManualRefreshPanel({
                    state: result.state || 'queued',
                    message: result.message || '',
                    total: 0,
                    completed: 0,
                    succeeded: 0,
                    failed: 0
                }, panel);
                return result;
            }

            throw new Error('Unexpected response from xray_extd.refresh');
        })
        .catch(function(err) {
            manualRefreshStatusGeneration++;
            manualRefreshAwaitingStatus = false;
            manualRefreshRequestPending = false;
            console.error('[Xray Extender] Cannot request manual refresh:', err);
            if (output)
                output.textContent = _('Failed to send the request. Check the xray_extd.refresh ACL and the connection to rpcd.');
            if (button) {
                button.disabled = manualRefreshIsBusy(manualRefreshLastStatus);
                button.textContent = manualRefreshButtonLabel(
                    manualRefreshLastStatus && manualRefreshLastStatus.state
                );
            }
        });
}

function startManualRefreshPolling() {
    if (manualRefreshPollStarted)
        return;

    manualRefreshPollStarted = true;

    poll.add(function() {
        if (!document.getElementById('xray-extd-manual-refresh-panel'))
            return;

        return readManualRefreshStatus();
    }, 5);
}


/* =========================================================
 * Раздел: Метаданные подписок
 * =========================================================
 */

function getSubscriptionMetadata() {
    return exec('/bin/cat', [ '/etc/xray_ext/subscription_meta.json' ])
        .then(function(res) {
            // Проверяем результат выполнения команды.
            if (!res || res.code !== 0 || !res.stdout) {
                console.warn('Cannot read subscription metadata: invalid response', res);
                return {};
            }

            // Разбираем JSON и извлекаем метаданные подписок.
            try {
                var data = JSON.parse(res.stdout);

                if (!data || typeof data !== 'object') {
                    console.warn('Invalid subscription metadata format:', data);
                    return {};
                }

                return data.subscriptions || data;
            }
            catch (e) {
                console.warn('Cannot parse subscription metadata:', e);
                return {};
            }
        })
        .catch(function(err) {
            console.warn('Cannot read subscription metadata:', err);
            return {};
        });
}

function formatTraffic(value) {
    var bytes = Number(value);
    if (!isFinite(bytes) || bytes < 0)
        return null;

    var units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
    var unit = 0;
    while (bytes >= 1024 && unit < units.length - 1) {
        bytes /= 1024;
        unit++;
    }

    return (unit === 0 ? String(Math.round(bytes)) : bytes.toFixed(2)) + ' ' + units[unit];
}

function formatExpiry(value) {
    if (value === undefined || value === null || value === '' || Number(value) === 0)
        return null;

    var date = new Date(Number(value) * 1000);
    if (isNaN(date.getTime()))
        return String(value);

    return date.toLocaleString();
}

function renderSubscriptionMetaRow(extId, colSpan) {
    var meta = subscriptionMetadata[extId] || {};
    var row = E('tr', { 'class': 'tr xray-ext-subscription-meta' });
    var cell = E('td', { 'class': 'td', 'colspan': String(colSpan) });
    var title = meta.profile_title || subscriptionNames[extId] || (_('Subscription') + ' (' + extId + ')');

    cell.appendChild(E('div', { 'class': 'meta-title' }, title));

    var details = E('div', { 'class': 'meta-details' });
    var hasDetails = false;

    function addDetail(label, value) {
        if (value === undefined || value === null || value === '')
            return;
        details.appendChild(E('span', {}, label + ': ' + value));
        hasDetails = true;
    }

    var userinfo = meta.userinfo || {};
    if (typeof userinfo === 'string') {
        var parsed = {};
        userinfo.split(';').forEach(function(part) {
            var match = part.match(/\s*(upload|download|total|expire)\s*=\s*(\d+)\s*/i);
            if (match)
                parsed[match[1].toLowerCase()] = Number(match[2]);
        });
        userinfo = parsed;
    }

    var upload = meta.upload !== undefined ? meta.upload : userinfo.upload;
    var download = meta.download !== undefined ? meta.download : userinfo.download;
    var total = meta.total !== undefined ? meta.total : userinfo.total;
    var expire = meta.expire !== undefined ? meta.expire : userinfo.expire;

	if (upload !== undefined)
	    addDetail(_('Uploaded'), formatTraffic(upload) || upload);

	if (download !== undefined)
	    addDetail(_('Downloaded'), formatTraffic(download) || download);

	if (total !== undefined)
	    addDetail(_('Total'), formatTraffic(total) || total);

	var used = Number(upload || 0) + Number(download || 0);

	if (total !== undefined && Number(total) > 0)
	    addDetail(_('Remaining'), formatTraffic(Math.max(0, Number(total) - used)));

	var expiry = formatExpiry(expire);

	if (expiry)
	    addDetail(_('Expires'), expiry);

	if (meta.updated_at)
	    addDetail(_('Updated'), new Date(Number(meta.updated_at) * 1000).toLocaleString('ru-RU'));

	if (meta.support_url) {
	    details.appendChild(E('a', {
	        'href': meta.support_url,
	        'target': '_blank',
	        'rel': 'noopener noreferrer'
	    }, _('Support')));
	    hasDetails = true;
	}

	if (meta.web_page_url) {
	    details.appendChild(E('a', {
	        'href': meta.web_page_url,
	        'target': '_blank',
	        'rel': 'noopener noreferrer'
	    }, _('Website')));
	    hasDetails = true;
	}

	if (hasDetails)
	    cell.appendChild(details);
	else
	    cell.appendChild(E('em', {}, _('Subscription metadata has not been received yet')));

	if (meta.announce) {
	    cell.appendChild(E('div', { 'class': 'meta-announce' }, meta.announce));
	}

    row.appendChild(cell);
    return row;
}

/* =========================================================
 * Раздел: Вспомогательные функции
 * =========================================================
 */

function normalizeList(value) {
    return Array.isArray(value)
        ? value
        : (value ? [ value ] : []);
}

function sameArray(a, b) {
    a = normalizeList(a);
    b = normalizeList(b);

    if (a.length !== b.length)
        return false;

    var sortedA = a.slice().sort();
    var sortedB = b.slice().sort();

    for (var i = 0; i < sortedA.length; i++) {
        if (sortedA[i] !== sortedB[i])
            return false;
    }

    return true;
}

/* =========================================================
 * Раздел: Блокировка чекбоксов
 * =========================================================
 */

function setServerCheckboxesDisabled(disabled) {
    document
        .querySelectorAll('.xray-ext-server-cb')
        .forEach(function(cb) {
            cb.disabled = disabled;
        });
}


/* =========================================================
 * Раздел: Построение списка резервных серверов
 * =========================================================
 */

function buildIndeterminateCfg() {

    var indeterminateCfg = {
        tcp_v4: [],
        tcp_v6: [],
        udp_v4: [],
        udp_v6: []
    };

    var savedTcpV4 = uci.get_first(
        'xray_ext',
        'general',
        'tcp_balancer_v4'
    ) || [];

    var savedTcpV6 = uci.get_first(
        'xray_ext',
        'general',
        'tcp_balancer_v6'
    ) || [];

    var savedUdpV4 = uci.get_first(
        'xray_ext',
        'general',
        'udp_balancer_v4'
    ) || [];

    var savedUdpV6 = uci.get_first(
        'xray_ext',
        'general',
        'udp_balancer_v6'
    ) || [];

    indeterminateCfg.tcp_v4 = savedTcpV4;
    indeterminateCfg.tcp_v6 = savedTcpV6;
    indeterminateCfg.udp_v4 = savedUdpV4;
    indeterminateCfg.udp_v6 = savedUdpV6;

	backup_tcp_v4 = [
	    ...new Set([...backup_tcp_v4, ...savedTcpV4])
	];
	backup_tcp_v6 = [
	    ...new Set([...backup_tcp_v6, ...savedTcpV6])
	];
	backup_udp_v4 = [
	    ...new Set([...backup_udp_v4, ...savedUdpV4])
	];
	backup_udp_v6 = [
	    ...new Set([...backup_udp_v6, ...savedUdpV6])
	];

    console.log(
        '[Backups CFG]',
        backup_tcp_v4,
        backup_tcp_v6,
        backup_udp_v4,
        backup_udp_v6
    );

    console.log(
        '[CFG Arrays]',
        cfg_tcp_v4,
        cfg_tcp_v6,
        cfg_udp_v4,
        cfg_udp_v6
    );

    console.log(
        '[Indeterminate Arrays]',
        indeterminateCfg
    );

    return indeterminateCfg;
}


/* =========================================================
 * Получение PID процесса Xray
 * =========================================================
 */

function getXrayPid() {

    return exec('/bin/sh', [
        '-c',
        "pgrep -f '^/usr/bin/xray run '"
    ])
        .then(function(res) {

            if (res.code !== 0) {
                return Promise.reject(
                    new Error('Xray process not found')
                );
            }

            var pids = (res.stdout || '')
                .trim()
                .split(/\s+/)
                .filter(function(pid) {
                    return /^\d+$/.test(pid);
                });

            if (pids.length !== 1) {
                return Promise.reject(
                    new Error(
                        'Expected one Xray process, found: ' +
                        pids.length
                    )
                );
            }

            return pids[0];
        });
}


/* =========================================================
 * Раздел: Ожидание перезапуска Xray
 * =========================================================
 */

function waitForXrayRestart(oldPid) {

    var started = Date.now();
    var timeout = 30000;
    var newPid = null;

    return new Promise(function(resolve, reject) {

        function check() {

            getXrayPid()

                .then(function(pid) {

                    if (pid !== oldPid) {

                        if (newPid !== pid) {

                            newPid = pid;

                            console.log(
                                '[Xray wait] New PID detected:',
                                oldPid,
                                '->',
                                newPid
                            );
                        }

                        return getRuntimeOutbounds(true);
                    }

                    return null;
                })

                .then(function(result) {

                    if (result !== null) {

                        console.log(
                            '[Xray wait] New Xray process is ready'
                        );

                        resolve(result);
                        return;
                    }

                    if (Date.now() - started >= timeout) {

                        reject(
                            new Error(
                                'Xray restart timeout: new process not ready'
                            )
                        );

                        return;
                    }

                    setTimeout(check, 500);
                })

                .catch(function(err) {

                    if (Date.now() - started >= timeout) {

                        reject(err);
                        return;
                    }

                    setTimeout(check, 500);
                });
        }

        check();
    });
}

/* =========================================================
 * Раздел: Xray API — удаление outbound
 * =========================================================
 */

function removeOutbound(tag) {
    setServerCheckboxesDisabled(true);

    console.log('REMOVE TAG:', tag);

    return exec('/usr/bin/xray', [
        'api',
        'rmo',
        '--server=127.0.0.1:8080',
        tag
    ])
        .then(function(res) {

            console.log('Xray EXEC RESULT:', res);

            if (res.code !== 0) {
                console.error('Xray API ERROR:', res.stderr || res.stdout);
                return Promise.reject(res);
            }

            return res;
        })
        .catch(function(err) {
            console.error('Xray EXEC ERROR:', err);
            throw err;
        })
        .finally(function() {
            setServerCheckboxesDisabled(false);
        });
}

/* =========================================================
 * Раздел: Xray API — добавление outbound
 * =========================================================
 */

function addOutbound(jsonObj) {
    setServerCheckboxesDisabled(true);

    var jsonStr = JSON.stringify({ outbounds: [ jsonObj ] });

    var tmpFile =
        '/tmp/xray-ext-ado-' +
        Date.now() +
        '-' +
        Math.floor(Math.random() * 100000) +
        '.json';
    console.log('ADO TEMP FILE:', tmpFile);

    return exec('/bin/sh', [
        '-c',
        'printf "%s" "$1" > "$2" && ' +
        '/usr/bin/xray api ado --server=127.0.0.1:8080 "$2"; ' +
        'ret=$?; rm -f "$2"; exit $ret',
        'sh',
        jsonStr,
        tmpFile
    ])
        .then(function(res) {

            console.log('Xray add result:', res);

            if (res.code !== 0) {
                console.error('Xray add error:', res.stderr || res.stdout);
                return Promise.reject(res);
            }

            console.log('Xray add OK:', res.stdout);
            return res;
        })
        .catch(function(err) {
            console.error('Xray add ERROR:', err);
            throw err;
        })
        .finally(function() {
            setServerCheckboxesDisabled(false);
        });
}

/* =========================================================
 * Раздел: Xray API — получение outbounds
 * =========================================================
 */

function getRuntimeOutbounds(force) {
    if (!force && runtimeOutboundsPromise)
        return runtimeOutboundsPromise;

    runtimeOutboundsPromise = exec('/usr/bin/xray', [
        'api',
        'lso',
        '--server=127.0.0.1:8080'
    ])
        .then(function(res) {

            if (res.code !== 0) {
                console.error('Xray lso error:', res.stderr || res.stdout);
                return Promise.reject(res);
            }

            var data;

            try {
                data = JSON.parse(res.stdout);
            }
            catch (e) {
                console.error('Cannot parse xray lso:', e);
                console.error('Raw lso output:', res.stdout);
                throw e;
            }

            var result = {
                tcp_v4: [],
                tcp_v6: [],
                udp_v4: [],
                udp_v6: []
            };

            (data.outbounds || []).forEach(function(outbound) {

                var tag = outbound.tag || '';

                var prefix;
                var target;

                if (tag.indexOf('tcp_balancer_v4@balancer_outbound:') === 0) {
                    prefix = 'tcp_balancer_v4@balancer_outbound:';
                    target = result.tcp_v4;
                }
                else if (tag.indexOf('tcp_balancer_v6@balancer_outbound:') === 0) {
                    prefix = 'tcp_balancer_v6@balancer_outbound:';
                    target = result.tcp_v6;
                }
                else if (tag.indexOf('udp_balancer_v4@balancer_outbound:') === 0) {
                    prefix = 'udp_balancer_v4@balancer_outbound:';
                    target = result.udp_v4;
                }
                else if (tag.indexOf('udp_balancer_v6@balancer_outbound:') === 0) {
                    prefix = 'udp_balancer_v6@balancer_outbound:';
                    target = result.udp_v6;
                }
                else {
                    return;
                }

                var cfg = tag.substring(prefix.length);

                if (cfg && target.indexOf(cfg) === -1)
                    target.push(cfg);
            });

            var runtimeSnapshot = JSON.stringify(result);

            if (runtimeSnapshot !== runtimeOutboundsLogSnapshot) {
                console.log('Active runtime lists changed:', result);
                runtimeOutboundsLogSnapshot = runtimeSnapshot;
            }

            return result;
        });

    return runtimeOutboundsPromise;
}

/*
 * Быстрый снимок только списков балансировщиков.
 * Демон публикует его в /tmp после чтения runtime Xray.
 * В отличие от api lso, этот JSON содержит лишь четыре массива cfg ID.
 */
var RUNTIME_LISTS_SNAPSHOT_PATH = '/tmp/xray_extd_runtime_lists.json';

function normalizeRuntimeSnapshotList(value) {
    if (Array.isArray(value))
        return value;

    /* lua-cjson may encode an empty Lua table as {}; here that means []. */
    if (value && typeof value === 'object' && Object.keys(value).length === 0)
        return [];

    return normalizeList(value);
}

function getConfiguredRuntimeLists() {
    return {
        tcp_v4: normalizeList(uci.get_first('xray_core', 'general', 'tcp_balancer_v4')).slice(),
        tcp_v6: normalizeList(uci.get_first('xray_core', 'general', 'tcp_balancer_v6')).slice(),
        udp_v4: normalizeList(uci.get_first('xray_core', 'general', 'udp_balancer_v4')).slice(),
        udp_v6: normalizeList(uci.get_first('xray_core', 'general', 'udp_balancer_v6')).slice(),
        generation: 0,
        updated_at: 0
    };
}

function getRuntimeOutboundsSnapshot() {
    return exec('/bin/cat', [ RUNTIME_LISTS_SNAPSHOT_PATH ])
        .then(function(res) {
            if (!res || res.code !== 0 || !res.stdout)
                throw new Error('Runtime list snapshot is unavailable');

            var data = JSON.parse(res.stdout);

            return {
                tcp_v4: normalizeRuntimeSnapshotList(data.tcp_v4).slice(),
                tcp_v6: normalizeRuntimeSnapshotList(data.tcp_v6).slice(),
                udp_v4: normalizeRuntimeSnapshotList(data.udp_v4).slice(),
                udp_v6: normalizeRuntimeSnapshotList(data.udp_v6).slice(),
                generation: Number(data.generation || 0),
                updated_at: Number(data.updated_at || 0)
            };
        })
        .catch(function(err) {
            if (!runtimeSnapshotWarningShown) {
                console.warn(
                    '[Xray Extender] Runtime list snapshot is not ready; using configured lists until daemon publishes it:',
                    err
                );
                runtimeSnapshotWarningShown = true;
            }

            return getConfiguredRuntimeLists();
        });
}

/* =========================================================
 * Раздел: Построение outbound
 * =========================================================
 */

function buildOutbound(server, listName) {
    var outbound = {
        tag: listName + '@balancer_outbound:' + server['.name'],
        protocol: server.protocol,
        settings: {},
        streamSettings: {}
    };

    switch (server.protocol) {
        case 'vless':
            buildVless(outbound, server);
            break;

        case 'shadowsocks':
            buildShadowsocks(outbound, server);
            break;

        case 'hysteria':
            buildHysteria(outbound, server);
            break;

        default:
            console.error('Unsupported protocol:', server.protocol, server);
            return null;
    }

    applyTransport(outbound, server);
    applySecurity(outbound, server);
    applySockopt(outbound, server);
    applyCustomConfig(outbound, server);

    // Custom config may extend settings, but it must not change the generated
    // outbound identity or the mark reserved for Xray Extender.
    outbound.tag = listName + '@balancer_outbound:' + server['.name'];
    outbound.streamSettings.sockopt = outbound.streamSettings.sockopt || {};
    outbound.streamSettings.sockopt.mark = 253;

	// Hysteria uses its own QUIC transport and must declare it explicitly.
	if (server.protocol === 'hysteria') {
	    outbound.streamSettings.network = 'hysteria';
	}

    return outbound;
}

/* =========================================================
 * Раздел: VLESS
 * =========================================================
 */

function buildVless(outbound, server) {
    outbound.settings = {
        address: server.server,
        port: Number(server.server_port[0]),
        id: server.password,
        email: server.username,
        encryption: server.vless_encryption || 'none'
    };

    if (server.vless_flow_reality)
        outbound.settings.flow = server.vless_flow_reality;

    if (server.vless_flow_tls)
        outbound.settings.flow = server.vless_flow_tls;
}

/* =========================================================
 * Раздел: Shadowsocks
 * =========================================================
 */

function buildShadowsocks(outbound, server) {
    outbound.settings = {
        address: server.server,
        port: Number(server.server_port[0]),
        email: server.username,
        password: server.password,
        method: server.shadowsocks_security,
        uot: server.shadowsocks_udp_over_tcp === '1'
    };
}

/* =========================================================
 * Раздел: Hysteria
 * =========================================================
 */

function buildHysteria(outbound, server) {
    outbound.settings = {
        version: 2,
        address: server.server,
        port: Number(server.server_port[0])
    };
}

/* =========================================================
 * Раздел: Транспорт
 * =========================================================
 */

function applyTransport(outbound, server) {
    if (server.protocol !== 'hysteria') {

        outbound.streamSettings.network = server.transport;

        switch (server.transport) {
            case 'tcp':
                break;

            case 'ws':
                applyWsTransport(outbound, server);
                break;

            case 'grpc':
                applyGrpcTransport(outbound, server);
                break;

            case 'splithttp':
                applySplitHttpTransport(outbound, server);
                break;

            default:
                console.warn('Unknown transport:', server.transport);
                break;
        }
    }

}

/* =========================================================
 * Раздел: Глубокое объединение объектов
 * =========================================================
 */

function mergeDeep(target, source) {
    for (var key in source) {

        if (
            source[key] &&
            typeof source[key] === 'object' &&
            !Array.isArray(source[key])
        ) {
            if (!target[key] || typeof target[key] !== 'object' || Array.isArray(target[key]))
                target[key] = {};

            mergeDeep(target[key], source[key]);
        }
        else {
            target[key] = source[key];
        }
    }

    return target;
}

function mergeCustomValue(target, source) {
    if (source && typeof source === 'object' && !Array.isArray(source)) {
        if (!target || typeof target !== 'object' || Array.isArray(target))
            target = {};
        return mergeDeep(target, source);
    }
    return source;
}

/* =========================================================
 * Раздел: custom_config
 * =========================================================
 */

function applyCustomConfig(outbound, server) {
    if (!server.custom_config)
        return;

    try {
        var custom = JSON.parse(server.custom_config);

        if (custom.settings)
            outbound.settings = mergeCustomValue(outbound.settings, custom.settings);

        if (custom.streamSettings)
            outbound.streamSettings = mergeCustomValue(outbound.streamSettings, custom.streamSettings);

        for (var key in custom) {
            if (key !== 'tag' && key !== 'protocol' &&
                key !== 'settings' && key !== 'streamSettings') {
                outbound[key] = mergeCustomValue(outbound[key], custom[key]);
            }
        }
    }
    catch (e) {
        console.error('Invalid custom_config:', server['.name'], e);
    }
}

/* =========================================================
 * Раздел: Split HTTP
 * =========================================================
 */

function applySplitHttpTransport(outbound, server) {
    outbound.streamSettings.splithttpSettings = {};

    if (server.splithttp_path)
        outbound.streamSettings.splithttpSettings.path = server.splithttp_path;

    if (server.splithttp_host)
        outbound.streamSettings.splithttpSettings.host = server.splithttp_host;
}

/* =========================================================
 * Раздел: Безопасность
 * =========================================================
 */

function applySecurity(outbound, server) {

    if (server.protocol === 'vless') {

        if (server.vless_tls === 'reality') {
            applyRealitySecurity(outbound, server);
            return;
        }

        if (server.vless_tls === 'tls') {
            applyTlsSecurity(outbound, server);
            return;
        }
    }

    if (server.protocol === 'shadowsocks') {

        if (server.shadowsocks_tls === 'tls') {
            outbound.streamSettings.security = 'tls';
            outbound.streamSettings.tlsSettings = {
                serverName: server.shadowsocks_tls_host,
                fingerprint: server.shadowsocks_tls_fingerprint,
                alpn: server.shadowsocks_tls_alpn,
                allowInsecure: server.shadowsocks_tls_insecure === '1'
            };
            return;
        }

        outbound.streamSettings.security = 'none';
        return;
    }

    if (server.protocol === 'hysteria') {
        applyHysteriaSecurity(outbound, server);
        return;
    }
}

/* =========================================================
 * Раздел: Reality
 * =========================================================
 */

function applyRealitySecurity(outbound, server) {
    outbound.streamSettings.security = 'reality';

    outbound.streamSettings.realitySettings = {
        serverName: server.vless_reality_server_name,
        fingerprint: server.vless_reality_fingerprint,
        password: server.vless_reality_public_key,
        shortId: server.vless_reality_short_id,
        show: server.vless_reality_show === '1',
        spiderX: server.vless_reality_spider_x
    };
}

/* =========================================================
 * Раздел: TLS
 * =========================================================
 */

function applyTlsSecurity(outbound, server) {
    outbound.streamSettings.security = 'tls';

    outbound.streamSettings.tlsSettings = {
        serverName: server.vless_tls_host,
        fingerprint: server.vless_tls_fingerprint,
        alpn: server.vless_tls_alpn,
        allowInsecure: server.vless_tls_insecure === '1'
    };
}

/* =========================================================
 * Раздел: Hysteria TLS
 * =========================================================
 */

function applyHysteriaSecurity(outbound, server) {
    outbound.streamSettings.security = 'tls';

    outbound.streamSettings.tlsSettings = {
        serverName: server.hysteria_tls_host,
        fingerprint: server.hysteria_tls_fingerprint,
        alpn: server.hysteria_tls_alpn,
        allowInsecure: server.hysteria_tls_insecure === '1'
    };

    outbound.streamSettings.hysteriaSettings = {
        version: 2,
        auth: server.password
    };

    if (server.hysteria_up_mbps)
        outbound.streamSettings.hysteriaSettings.up = `${server.hysteria_up_mbps}mbps`;

    if (server.hysteria_down_mbps)
        outbound.streamSettings.hysteriaSettings.down = `${server.hysteria_down_mbps}mbps`;

    if (server.hysteria_udphop_port) {
        outbound.streamSettings.hysteriaSettings.udphop = {
            port: server.hysteria_udphop_port,
            interval: Number(server.hysteria_udphop_interval || 30)
        };
    }
}

/* =========================================================
 * Раздел: Sockopt
 * =========================================================
 */

function applySockopt(outbound, server) {
    outbound.streamSettings.sockopt = {
        domainStrategy: server.domain_strategy,
        mark: 253
    };
}

/* =========================================================
 * Раздел: Чекбоксы серверов
 * =========================================================
 */

function mkbox(listName, activeList, server, indeterminateList) {

    var cb = E('input', {
        'type': 'checkbox',
        'class': 'xray-ext-server-cb'
    });

    cb.checked = activeList.indexOf(server['.name']) !== -1;
    cb.indeterminate = indeterminateList.indexOf(server['.name']) !== -1;

    cb._server = server;
    cb._listName = listName;
    cb._tag = listName + '@balancer_outbound:' + server['.name'];

// Создаём список subscriptionRoles
	if (cb.checked) {
		if (server.ext_id && subscriptionRoles[server.ext_id] && subscriptionRoles[server.ext_id] === 'backup') {
			switch(listName) {
				case 'tcp_balancer_v4' :
					backup_tcp_v4.push(server['.name']);
				break;
				case 'tcp_balancer_v6' :
					backup_tcp_v6.push(server['.name']);
				break;
				case 'udp_balancer_v4' :
					backup_udp_v4.push(server['.name']);
				break;
				case 'udp_balancer_v6' :
					backup_udp_v6.push(server['.name']);
				break;
			}
		}
	}

    cb.addEventListener('click', function(ev) {

        var cb = ev.target;
        var cfg = cb._server['.name'];

	    /* Функция проверки роли backup */
	    var roleBackup = function() {
	        return (
	            cb._server['ext_id'] &&
	            subscriptionRoles[cb._server['ext_id']] &&
	            subscriptionRoles[cb._server['ext_id']] === 'backup'
	        );
	    };


        /* =========================================================
         * Добавление
         * =========================================================
         */

        if (cb.checked) {

            if (listName === 'tcp_balancer_v4') {
                if (cfg_tcp_v4.indexOf(cfg) === -1)
                    cfg_tcp_v4.push(cfg);
                if (roleBackup() && backup_tcp_v4.indexOf(cfg) === -1)
                	backup_tcp_v4.push(cfg);
            }
            else if (listName === 'tcp_balancer_v6') {
                if (cfg_tcp_v6.indexOf(cfg) === -1)
                    cfg_tcp_v6.push(cfg);
                if (roleBackup() && backup_tcp_v6.indexOf(cfg) === -1)
                	backup_tcp_v6.push(cfg);
            }
            else if (listName === 'udp_balancer_v4') {
                if (cfg_udp_v4.indexOf(cfg) === -1)
                    cfg_udp_v4.push(cfg);
                if (roleBackup() && backup_udp_v4.indexOf(cfg) === -1)
                	backup_udp_v4.push(cfg);
            }
            else if (listName === 'udp_balancer_v6') {
                if (cfg_udp_v6.indexOf(cfg) === -1)
                    cfg_udp_v6.push(cfg);
                if (roleBackup() && backup_udp_v6.indexOf(cfg) === -1)
                	backup_udp_v6.push(cfg);
            }

            var outboundJson = buildOutbound(cb._server, cb._listName);

            console.log('ADD OUTBOUND:', outboundJson);

            addOutbound(outboundJson);
        }


        /* =========================================================
         * Удаление
         * =========================================================
         */

        else {

            if (listName === 'tcp_balancer_v4') {
                var pos = cfg_tcp_v4.indexOf(cfg);
                if (pos !== -1)
                    cfg_tcp_v4.splice(pos, 1);
                if (roleBackup()) {
	                pos = backup_tcp_v4.indexOf(cfg);
	                if (pos !== -1)
	                    backup_tcp_v4.splice(pos, 1);
                }
            }
            else if (listName === 'tcp_balancer_v6') {
                var pos = cfg_tcp_v6.indexOf(cfg);
                if (pos !== -1)
                    cfg_tcp_v6.splice(pos, 1);
                if (roleBackup()) {
	                pos = backup_tcp_v6.indexOf(cfg);
	                if (pos !== -1)
	                    backup_tcp_v6.splice(pos, 1);
                }
            }
            else if (listName === 'udp_balancer_v4') {
                var pos = cfg_udp_v4.indexOf(cfg);
                if (pos !== -1)
                    cfg_udp_v4.splice(pos, 1);
                if (roleBackup()) {
	                pos = backup_udp_v4.indexOf(cfg);
	                if (pos !== -1)
	                    backup_udp_v4.splice(pos, 1);
                }
            }
            else if (listName === 'udp_balancer_v6') {
                var pos = cfg_udp_v6.indexOf(cfg);
                if (pos !== -1)
                    cfg_udp_v6.splice(pos, 1);
                if (roleBackup()) {
	                pos = backup_udp_v6.indexOf(cfg);
	                if (pos !== -1)
	                    backup_udp_v6.splice(pos, 1);
                }
            }

            removeOutbound(cb._tag);
        }
console.log('cfg_tcp_v4', cfg_tcp_v4);
console.log('cfg_udp_v4', cfg_udp_v4);
console.log('backup_tcp_v4', backup_tcp_v4);
console.log('backup_udp_v4', backup_udp_v4);
    });

    return cb;
}


/* =========================================================
 * Раздел: Применение настроек резолва ко всем серверам
 * =========================================================
 */

function applyResolverSettingsToAllServers() {
    var domainStrategy =
        uci.get_first(
            'xray_ext',
            'general',
            'domain_strategy'
        ) || 'UseIP';

    var dnsMethod =
        uci.get_first(
            'xray_ext',
            'general',
            'domain_resolve_dns_method'
        ) || 'udp';

    var dnsServer =
        uci.get_first(
            'xray_ext',
            'general',
            'domain_resolve_dns'
        ) || '';

    var servers = uci.sections(
        'xray_core',
        'servers'
    ) || [];

    var changedServers = 0;

    servers.forEach(function(server) {
        var section = server['.name'];

        if (!section)
            return;

        var changed = false;

        if (server.domain_strategy !== domainStrategy) {
            uci.set(
                'xray_core',
                section,
                'domain_strategy',
                domainStrategy
            );

            changed = true;
        }

        if (server.domain_resolve_dns_method !== dnsMethod) {
            uci.set(
                'xray_core',
                section,
                'domain_resolve_dns_method',
                dnsMethod
            );

            changed = true;
        }

        if (dnsServer !== '') {
            if (server.domain_resolve_dns !== dnsServer) {
                uci.set(
                    'xray_core',
                    section,
                    'domain_resolve_dns',
                    dnsServer
                );

                changed = true;
            }
        }
        else if (server.domain_resolve_dns != null) {
            uci.unset(
                'xray_core',
                section,
                'domain_resolve_dns'
            );

            changed = true;
        }

        if (changed)
            changedServers++;
    });

    console.log(
        '[Resolver] Servers changed:',
        changedServers,
        'of',
        servers.length
    );

    return changedServers;
}


/* =========================================================
 * Раздел: Сбор изменений в конфигурациях
 * =========================================================
 */

function collectChanges() {

    pendingChanges.xrayCore = saveCfgLists();

    pendingChanges.xrayExt = hasBackupCfgChanges();

    console.log(
        'Pending changes:',
        JSON.stringify(pendingChanges)
    );
}


/* =========================================================
 * Раздел: Оценка изменений в резервных серверах
 * =========================================================
 */

function hasBackupCfgChanges() {

    var saved_backup_tcp_v4 =
        uci.get_first('xray_ext', 'general', 'tcp_balancer_v4');

    var saved_backup_tcp_v6 =
        uci.get_first('xray_ext', 'general', 'tcp_balancer_v6');

    var saved_backup_udp_v4 =
        uci.get_first('xray_ext', 'general', 'udp_balancer_v4');

    var saved_backup_udp_v6 =
        uci.get_first('xray_ext', 'general', 'udp_balancer_v6');

    var changed =
        !sameArray(saved_backup_tcp_v4, backup_tcp_v4) ||
        !sameArray(saved_backup_tcp_v6, backup_tcp_v6) ||
        !sameArray(saved_backup_udp_v4, backup_udp_v4) ||
        !sameArray(saved_backup_udp_v6, backup_udp_v6);

    console.log(
        '[Backup changes]',
        'tcp_v4=', !sameArray(saved_backup_tcp_v4, backup_tcp_v4),
        'tcp_v6=', !sameArray(saved_backup_tcp_v6, backup_tcp_v6),
        'udp_v4=', !sameArray(saved_backup_udp_v4, backup_udp_v4),
        'udp_v6=', !sameArray(saved_backup_udp_v6, backup_udp_v6),
        '=>', changed
    );

    return changed;
}


/* =========================================================
 * Раздел: Сохранение cfg_* в xray_core
 * =========================================================
 */

function saveCfgLists() {
    var changed = false;

    var current_tcp_v4 = uci.get_first('xray_core', 'general', 'tcp_balancer_v4');
    var current_tcp_v6 = uci.get_first('xray_core', 'general', 'tcp_balancer_v6');
    var current_udp_v4 = uci.get_first('xray_core', 'general', 'udp_balancer_v4');
    var current_udp_v6 = uci.get_first('xray_core', 'general', 'udp_balancer_v6');

	var set_backup_tcp_v4 = new Set(backup_tcp_v4);
	var save_cfg_tcp_v4 = cfg_tcp_v4.filter(item => !set_backup_tcp_v4.has(item));
    if (!sameArray(current_tcp_v4, save_cfg_tcp_v4)) {
        changed = true;
        uci.set_first('xray_core', 'general', 'tcp_balancer_v4', save_cfg_tcp_v4);
    }
console.log('current_tcp_v4', current_tcp_v4);
console.log('save_cfg_tcp_v4', save_cfg_tcp_v4);
	var set_backup_tcp_v6 = new Set(backup_tcp_v6);
	var save_cfg_tcp_v6 = cfg_tcp_v6.filter(item => !set_backup_tcp_v6.has(item));
    if (!sameArray(current_tcp_v6, save_cfg_tcp_v6)) {
        changed = true;
        uci.set_first('xray_core', 'general', 'tcp_balancer_v6', save_cfg_tcp_v6);
    }

	var set_backup_udp_v4 = new Set(backup_udp_v4);
	var save_cfg_udp_v4 = cfg_udp_v4.filter(item => !set_backup_udp_v4.has(item));
    if (!sameArray(current_udp_v4, save_cfg_udp_v4)) {
        changed = true;
        uci.set_first('xray_core', 'general', 'udp_balancer_v4', save_cfg_udp_v4);
    }

	var set_backup_udp_v6 = new Set(backup_udp_v6);
	var save_cfg_udp_v6 = cfg_udp_v6.filter(item => !set_backup_udp_v6.has(item));
    if (!sameArray(current_udp_v6, save_cfg_udp_v6)) {
        changed = true;
        uci.set_first('xray_core', 'general', 'udp_balancer_v6', save_cfg_udp_v6);
    }

	return changed;
}

/* ============================================================
 * Сохранение backup_* в xray_ext
 * ============================================================
 */

function saveBackupCfgLists() {

    var saved_backup_tcp_v4 =
        uci.get_first(
            'xray_ext',
            'general',
            'tcp_balancer_v4'
        );

    var saved_backup_tcp_v6 =
        uci.get_first(
            'xray_ext',
            'general',
            'tcp_balancer_v6'
        );

    var saved_backup_udp_v4 =
        uci.get_first(
            'xray_ext',
            'general',
            'udp_balancer_v4'
        );

    var saved_backup_udp_v6 =
        uci.get_first(
            'xray_ext',
            'general',
            'udp_balancer_v6'
        );


    if (
        !sameArray(
            saved_backup_tcp_v4,
            backup_tcp_v4
        )
    ) {
console.log(
    '[Backup SET] tcp_v4:',
    JSON.stringify(backup_tcp_v4)
);
        uci.set_first(
            'xray_ext',
            'general',
            'tcp_balancer_v4',
            backup_tcp_v4.length ? backup_tcp_v4 : null
        );
    }


    if (
        !sameArray(
            saved_backup_tcp_v6,
            backup_tcp_v6
        )
    ) {
console.log(
    '[Backup SET] tcp_v6:',
    JSON.stringify(backup_tcp_v6)
);
        uci.set_first(
            'xray_ext',
            'general',
            'tcp_balancer_v6',
            backup_tcp_v6.length ? backup_tcp_v6 : null
        );
    }


    if (
        !sameArray(
            saved_backup_udp_v4,
            backup_udp_v4
        )
    ) {
console.log(
    '[Backup SET] tcp_v6:',
    JSON.stringify(backup_tcp_v6)
);
        uci.set_first(
            'xray_ext',
            'general',
            'udp_balancer_v4',
            backup_udp_v4.length ? backup_udp_v4 : null
        );
    }


    if (
        !sameArray(
            saved_backup_udp_v6,
            backup_udp_v6
        )
    ) {
console.log(
    '[Backup SET] udp_v6:',
    JSON.stringify(backup_udp_v6)
);
        uci.set_first(
            'xray_ext',
            'general',
            'udp_balancer_v6',
            backup_udp_v6.length ? backup_udp_v6 : null
        );
    }
}

/* =========================================================
 * Раздел: Опрос балансировщиков
 * =========================================================
 */

function cloneRuntimeCfg(source) {
    source = source || {};

    return {
        tcp_v4: normalizeList(source.tcp_v4).slice(),
        tcp_v6: normalizeList(source.tcp_v6).slice(),
        udp_v4: normalizeList(source.udp_v4).slice(),
        udp_v6: normalizeList(source.udp_v6).slice(),
        generation: Number(source.generation || 0),
        updated_at: Number(source.updated_at || 0)
    };
}

function getLiveBalancerRuntimeCfg() {
    return getRuntimeOutboundsSnapshot()
        .then(function(runtimeCfg) {
            balancerRuntimeCfg = cloneRuntimeCfg(runtimeCfg);
            return balancerRuntimeCfg;
        })
        .catch(function(err) {
            console.warn(
                '[Balancer] Cannot read runtime list snapshot; keeping last known state:',
                err
            );

            if (balancerRuntimeCfg)
                return balancerRuntimeCfg;

            return cloneRuntimeCfg({
                tcp_v4: cfg_tcp_v4,
                tcp_v6: cfg_tcp_v6,
                udp_v4: cfg_udp_v4,
                udp_v6: cfg_udp_v6
            });
        });
}

function getFreshXrayServerSections() {
    return getFreshXrayServers('xray_core', 'servers')
        .then(function(sectionsById) {
            var sections = [];

            Object.keys(sectionsById || {}).forEach(function(id) {
                var server = sectionsById[id];

                if (!server || server['.type'] !== 'servers')
                    return;

                if (!server['.name'])
                    server['.name'] = id;

                sections.push(server);
            });

            return sections;
        });
}

function refreshBalancerServerSections(runtimeCfg) {
    var generation = Number(runtimeCfg.generation || 0);

    if (balancerServerSections &&
        balancerServerSectionsGeneration === generation) {
        return Promise.resolve(balancerServerSections);
    }

    if (balancerMetadataRefreshPromise)
        return balancerMetadataRefreshPromise;

    if (Date.now() < balancerMetadataRefreshRetryAfter)
        return Promise.resolve(balancerServerSections || uci.sections('xray_core', 'servers'));

    balancerMetadataRefreshPromise = getFreshXrayServerSections()
        .then(function(sections) {
            balancerServerSections = sections;
            balancerServerSectionsGeneration = generation;
            balancerMetadataRefreshRetryAfter = 0;

            /* The runtime table is already visible. Repaint it now that the
             * slower UCI metadata request has supplied fresh aliases/names. */
            if (lastBalancerPollData &&
                Number(lastBalancerPollData.runtimeCfg.generation || 0) === generation &&
                document.getElementById('xray-ext-balancers')) {
                renderBalancerTables(
                    document.getElementById('xray-ext-balancers'),
                    lastBalancerPollData.runtimeCfg,
                    lastBalancerPollData.observatory,
                    lastBalancerPollData.currentTags,
                    sections
                );
            }

            return sections;

        })
        .catch(function(err) {
            console.warn(
                '[Balancer] Cannot refresh server metadata after runtime change; keeping last known state:',
                err
            );
            balancerMetadataRefreshRetryAfter = Date.now() + 15000;
            return balancerServerSections || uci.sections('xray_core', 'servers');
        })
        .finally(function() {
            balancerMetadataRefreshPromise = null;
        });

    return balancerMetadataRefreshPromise;
}

function refreshBalancerCurrentTags() {
    if (balancerCurrentTagsPromise)
        return balancerCurrentTagsPromise;

    /*
     * One expensive `bi` request per cycle. Skip IPv6 balancers entirely
     * when the page's existing availability check says IPv6 is disabled.
     * Keep stable indexes because renderBalancerTables expects:
     * TCP v4 = 0, TCP v6 = 1, UDP v4 = 2, UDP v6 = 3.
     */
    var balancerTags = [
        { tag: 'tcp_outbound_v4', index: 0 }
    ];

    if (ipv6_enabled)
        balancerTags.push({ tag: 'tcp_outbound_v6', index: 1 });

    balancerTags.push({ tag: 'udp_outbound_v4', index: 2 });

    if (ipv6_enabled)
        balancerTags.push({ tag: 'udp_outbound_v6', index: 3 });

    var entry = balancerTags[balancerCurrentTagIndex % balancerTags.length];
    balancerCurrentTagIndex = (balancerCurrentTagIndex + 1) % balancerTags.length;

    balancerCurrentTagsPromise = getBalancerInfo(entry.tag)
        .then(function(tag) {
            balancerCurrentTags[entry.index] = tag;

            /* Update the visible current-selection marker as soon as this result arrives. */
            var container = document.getElementById('xray-ext-balancers');
            if (container && lastBalancerPollData) {
                lastBalancerPollData.currentTags = balancerCurrentTags.slice();
                renderBalancerTables(
                    container,
                    lastBalancerPollData.runtimeCfg,
                    lastBalancerPollData.observatory,
                    lastBalancerPollData.currentTags,
                    balancerServerSections || uci.sections('xray_core', 'servers')
                );
            }

            return balancerCurrentTags.slice();
        })
        .catch(function(err) {
            console.warn('[Balancer] Cannot refresh current selection; keeping last known state:', err);
            return balancerCurrentTags.slice();
        })
        .finally(function() {
            balancerCurrentTagsPromise = null;
        });

    return balancerCurrentTagsPromise;
}

function refreshBalancerFastData(container) {
    if (balancerFastRefreshPromise)
        return balancerFastRefreshPromise;

    /* The first call may happen before LuCI inserts the container into the DOM. */
    balancerFastRefreshPromise = Promise.all([
        getLiveBalancerRuntimeCfg(),
        getObservatory()
    ])
        .then(function(data) {
            var target = document.getElementById('xray-ext-balancers') || container;
            if (!target)
                return;

            var runtimeCfg = data[0];
            var currentTags = balancerCurrentTags.slice();

            lastBalancerPollData = {
                runtimeCfg: runtimeCfg,
                observatory: data[1],
                currentTags: currentTags
            };

            /* The frequent path only reads the small snapshot and observatory metrics. */
            renderBalancerTables(
                target,
                runtimeCfg,
                data[1],
                currentTags,
                balancerServerSections || uci.sections('xray_core', 'servers')
            );

            /* Fetch the larger UCI metadata only when snapshot generation changes. */
            refreshBalancerServerSections(runtimeCfg);
        })
        .catch(function(err) {
            console.warn('[Balancer] Fast refresh failed; keeping the last rendered state:', err);
        })
        .finally(function() {
            balancerFastRefreshPromise = null;
        });

    return balancerFastRefreshPromise;
}

function startBalancerPolling(container) {
    if (balancerPollStarted)
        return;

    balancerPollStarted = true;

    /* Paint immediately from the snapshot already read by load(). */
    if (balancerRuntimeCfg) {
        renderBalancerTables(
            container,
            balancerRuntimeCfg,
            {},
            balancerCurrentTags.slice(),
            balancerServerSections || uci.sections('xray_core', 'servers')
        );
    }

    /* Fast path: list snapshot + Observatory, every 5 seconds and immediately once. */
    refreshBalancerFastData(container);
    poll.add(function() {
        return refreshBalancerFastData(container);
    }, BALANCER_POLL_INTERVAL);

    /* Slow path: current selection is queried through four separate xray CLI calls. */
    refreshBalancerCurrentTags();
    poll.add(function() {
        if (!document.getElementById('xray-ext-balancers'))
            return;

        return refreshBalancerCurrentTags();
    }, BALANCER_SELECTION_POLL_INTERVAL);
}

function renderBalancerTables(container, runtimeCfg, observatory, currentTags, sections) {
    var content = E('div');

    content.appendChild(
        renderBalancerGroup(
            'tcp_balancer_v4', _('TCP v4'), runtimeCfg.tcp_v4,
            observatory, sections, getBalancerCfg(currentTags[0])
        )
    );

    if (runtimeCfg.tcp_v6.length) {
        content.appendChild(
            renderBalancerGroup(
                'tcp_balancer_v6', _('TCP v6'), runtimeCfg.tcp_v6,
                observatory, sections, getBalancerCfg(currentTags[1])
            )
        );
    }

    content.appendChild(
        renderBalancerGroup(
            'udp_balancer_v4', _('UDP v4'), runtimeCfg.udp_v4,
            observatory, sections, getBalancerCfg(currentTags[2])
        )
    );

    if (runtimeCfg.udp_v6.length) {
        content.appendChild(
            renderBalancerGroup(
                'udp_balancer_v6', _('UDP v6'), runtimeCfg.udp_v6,
                observatory, sections, getBalancerCfg(currentTags[3])
            )
        );
    }

    dom.content(container, content);
}

/* =========================================================
 * Раздел: Метрики
 * =========================================================
 */

function getMetricsServerPort() {
    var port = uci.get_first('xray_core', 'general', 'metrics_server_port');
    port = Number(port);

    if (!port)
        port = 18888;

    return port;
}

/* =========================================================
 * Раздел: Observatory
 * =========================================================
 */

function getObservatory() {
    var port = getMetricsServerPort();

    var url = 'http://127.0.0.1:' + port + '/debug/vars';

    return exec('/usr/bin/wget', [
        '-q',
        '-O',
        '-',
        url
    ])
        .then(function(res) {

            if (res.code !== 0) {
                console.error('Observatory wget error:', res.stderr || res.stdout);
                return {};
            }

            try {
                var vars = JSON.parse(res.stdout);
                return vars.observatory || {};
            }
            catch (e) {
                console.error('Cannot parse Observatory data:', e);
                console.error('Raw debug/vars:', res.stdout);
                return {};
            }
        });
}

/* =========================================================
 * Раздел: Балансировщики — cfg
 * =========================================================
 */

function getBalancerCfg(tag) {
    if (!tag)
        return null;

    var pos = tag.lastIndexOf(':');

    if (pos === -1)
        return null;

    return tag.substring(pos + 1);
}

/* =========================================================
 * Раздел: Балансировщики — информация
 * =========================================================
 */

function getBalancerInfo(balancerTag) {
    return exec('/usr/bin/xray', [
        'api',
        'bi',
        '--server=127.0.0.1:8080',
        balancerTag
    ])
        .then(function(res) {

            if (res.code !== 0) {
                console.error('Balancer info error:', balancerTag, res.stderr || res.stdout);
                return null;
            }

            var match = res.stdout.match(/Selects:\s*\n\s*1\s+(\S+)/);

            if (!match)
                return null;

            return match[1];
        });
}

/* =========================================================
 * Раздел: Поиск сервера по cfg
 * =========================================================
 */

function findServerByCfg(sections, cfg) {
    for (var i = 0; i < sections.length; i++) {
        if (sections[i]['.name'] === cfg)
            return sections[i];
    }

    return null;
}

/* =========================================================
 * Раздел: Отрисовка группы балансировщика
 * =========================================================
 */

function renderBalancerGroup(listName, title, cfgList, observatory, sections, currentCfg) {

    var section = E('div', { 'class': 'cbi-section' });

    section.appendChild(
        E('h3', {}, title)
    );

    var table = E('table', { 'class': 'table cbi-section-table' });

    var thead = E('thead');

    var header = E('tr', { 'class': 'tr table-titles' });

    [
		_('Subscription'),
		_('Server'),
		_('Ping'),
		_('Status')
    ].forEach(function(title) {
        header.appendChild(
            E('th', { 'class': 'th' }, title)
        );
    });

    thead.appendChild(header);
    table.appendChild(thead);

    var tbody = E('tbody');

    var aliveCount = 0;

    cfgList.forEach(function(cfg) {

        var server = findServerByCfg(sections, cfg);

        var subscriptionName = _('Manual');

        if (server && server.ext_id && subscriptionNames[server.ext_id])
            subscriptionName = subscriptionNames[server.ext_id];
        var tag = listName + '@balancer_outbound:' + cfg;

        var obs = observatory[tag];

        var row = E('tr', { 'class': 'tr' });

        row.appendChild(
            E('td', { 'class': 'td' }, subscriptionName)
        );

        var serverName = server && server.alias ? server.alias : cfg;

        var isCurrent = (cfg === currentCfg);

        row.appendChild(
            E(
                'td',
                { 'class': 'td' },
                E(
                    'strong',
                    {},
                    serverName + (isCurrent ? '  ← ' + _('In use') : '')
                )
            )
        );

        var ping = '—';

        if (obs && obs.delay !== undefined && obs.delay < 99999999)
            ping = String(obs.delay) + ' ms';

        row.appendChild(
            E('td', { 'class': 'td' }, ping)
        );

        var status;

		if (!obs)
		    status = _('No data');

		else if (obs.alive === true) {
		    status = _('Alive');
		    aliveCount++;
		}

		else if (obs.delay !== undefined && obs.delay >= 99999999)
		    status = _('Unavailable');

		else
		    status = _('No data');

        row.appendChild(
            E('td', { 'class': 'td' }, status)
        );

        tbody.appendChild(row);
    });

    table.appendChild(tbody);

    section.appendChild(
        E(
            'div',
            { 'class': 'cbi-section-descr' },
            _('Active: %s, alive: %s').format(cfgList.length, aliveCount)
        )
    );

    section.appendChild(table);

    return section;
}

/* =========================================================
 * Раздел: View
 * =========================================================
 */

return view.extend({

    /* =========================================================
     * Раздел: LOAD
     * =========================================================
     */

    load: function() {

        var service = rpc.declare({
            object: 'service',
            method: 'list',
            params: [ 'name' ]
        });

        return Promise.all([
            uci.load('xray_core'),
            uci.load('xray_ext'),
            service('odhcpd'),
            getSubscriptionMetadata()
        ]).then(function(data) {
            return getRuntimeOutboundsSnapshot().then(function(runtimeCfg) {
                return [ data[0], data[1], data[2], runtimeCfg, data[3] ];
            });
        });
    },

    /* =========================================================
     * Раздел: RENDER
     * =========================================================
     */

    render: function(data) {

        addCustomStyles();
console.log(data);
        var m, s, o;

        var odhcpd = data[2];
        subscriptionMetadata = data[4] || {};

        uci.sections('xray_ext', 'subscription').forEach(function(sub) {
            if (sub.ext_id && sub.name)
                subscriptionNames[sub.ext_id] = sub.name;
            	subscriptionRoles[sub.ext_id] = sub.role;
        });

        var runtimeCfg = data[3] || {
            tcp_v4: [],
            tcp_v6: [],
            udp_v4: [],
            udp_v6: []
        };

        /* =========================================================
         * Раздел: Актуальное состояние Xray
         * =========================================================
         */

        cfg_tcp_v4 = normalizeList(runtimeCfg.tcp_v4);
        cfg_tcp_v6 = normalizeList(runtimeCfg.tcp_v6);
        cfg_udp_v4 = normalizeList(runtimeCfg.udp_v4);
        cfg_udp_v6 = normalizeList(runtimeCfg.udp_v6);

        /* Отдельный снимок для динамической вкладки «Балансировщики». */
        balancerRuntimeCfg = cloneRuntimeCfg(runtimeCfg);
        balancerServerSections = uci.sections('xray_core', 'servers');
        balancerServerSectionsGeneration = Number(runtimeCfg.generation || 0);

        /* =========================================================
         * Раздел: IPv6
         * =========================================================
         */

        ipv6_enabled = false;

        if (odhcpd && odhcpd.odhcpd && odhcpd.odhcpd.instances) {
            Object.keys(odhcpd.odhcpd.instances).forEach(function(name) {
                if (odhcpd.odhcpd.instances[name].running === true)
                    ipv6_enabled = true;
            });
        }

        /* =========================================================
         * Раздел: Карта и секция
         * =========================================================
         */

        m = new form.Map('xray_ext', _('Xray Extender'));

        s = m.section(
		    form.TypedSection,
		    'general',
		    _('Subscription management, server health monitoring and balancer tools for luci-app-xray.')
		);

        s.anonymous = true;
        s.addremove = false;

        /* =========================================================
         * Раздел: Save / Apply
         * =========================================================
         */

        var resolverApplyAllRequested = false;

        var originalSave = m.save.bind(m);

        m.save = function(cb, silent) {

            resolverApplyAllRequested = false;

            collectChanges();

            if (pendingChanges.xrayExt) {
                console.log(
                    '[Save] staging xray_ext backup lists'
                );

                saveBackupCfgLists();
            }

            return originalSave(function() {

                var applyAll =
                    !silent && resolverApplyAllRequested;

                resolverApplyAllRequested = false;

                if (applyAll) {
                    var changedServers =
                        applyResolverSettingsToAllServers();

                    if (changedServers > 0) {
                        pendingChanges.xrayCore = true;

                        console.log(
                            '[Save] Resolver settings applied to',
                            changedServers,
                            'servers'
                        );
                    }
                    else {
                        console.log(
                            '[Save] Resolver settings already match all servers'
                        );
                    }
                }

                if (typeof cb === 'function')
                    return cb();

            }, silent);
        };


		/* =========================================================
		 * Раздел: Ожидание перезапуска Xray / второй этап Apply
		 * =========================================================
		 */

		var originalConfirm = ui.changes.confirm.bind(ui.changes);

		ui.changes.confirm = function(checked, deadline, override_token) {

		    /*
		     * Если Xray Core не менялся, перезапуск ждать не нужно.
		     */
		    if (!pendingChanges.xrayCore) {

		        console.log(
		            '[Apply] xray_core unchanged'
		        );

		        return originalConfirm(
		            checked,
		            deadline,
		            override_token
		        );
		    }


		    /*
		     * xray_core изменился.
		     * Первый Apply должен привести к перезапуску Xray.
		     */
		    console.log(
		        '[Apply] xray_core changed, waiting for Xray restart'
		    );


		    ui.changes.displayStatus(
		        'notice spinning',
		        E('p', _('Waiting for Xray restart…'))
		    );


			getXrayPid()

			    .then(function(oldPid) {

			        console.log(
			            '[Apply] Current Xray PID:',
			            oldPid
			        );

			        return waitForXrayRestart(oldPid);
			    })

			    .then(function(result) {

		            console.log(
		                '[Apply] Xray restart detected',
		                result
		            );


		            /*
		             * Первый этап закончен.
		             *
		             * Теперь можно сохранять xray_ext.
		             */
		            if (pendingChanges.xrayExt) {

		                console.log(
		                    '[Apply] Saving xray_ext backup lists'
		                );

		                saveBackupCfgLists();
		            }


		            /*
		             * Передаём управление обратно
		             * стандартному LuCI Apply.
		             */
		            return originalConfirm(
		                checked,
		                deadline,
		                override_token
		            );
		        })

		        .catch(function(err) {

		            console.error(
		                '[Apply] Xray restart failed:',
		                err
		            );

		            ui.changes.displayStatus(
		                'warning',
		                E('p', _('Xray did not restart within the expected time.'))
		            );
		        });
		};


        /* =========================================================
         * Раздел: Вкладки
         * =========================================================
         */

		s.tab('subscriptions', _('Subscriptions'));
		s.tab('servers', _('Servers'));
		s.tab('resolving', _('Server Discovery'));
		s.tab('balancers', _('Balancers'));


        /* =========================================================
         * Раздел: TAB — Подписки
         * =========================================================
         */

        o = s.taboption(
            'subscriptions',
            form.Flag,
            'subscription_direct',
            _('Download subscriptions directly (bypass Xray)'),
            _('When enabled, subscription URLs are fetched by the xrayext system user (UID 666), which is excluded from Xray transparent proxying. This keeps updates working when VPN tunnels are unavailable.')
        );
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('subscriptions', form.DummyValue, '_manual_refresh', _('Subscription Update'));
        o.render = function() {
            var panel = E('div', { 'id': 'xray-extd-manual-refresh-panel', 'class': 'xray-ext-manual-refresh' }, [
                E('button', {
                    'id': 'xray-extd-manual-refresh-button',
                    'type': 'button',
                    'class': 'btn cbi-button cbi-button-action',
                    'click': requestManualRefresh
                }, _('Refresh now')),
                E('span', {
                    'id': 'xray-extd-manual-refresh-status',
                    'class': 'xray-ext-manual-refresh-status'
                }, _('Checking daemon status…'))
            ]);

            readManualRefreshStatus(panel);
            startManualRefreshPolling();

            return panel;
        };

        o = s.taboption('subscriptions', form.SectionValue, '_subscriptions', form.GridSection, 'subscription');

        var ss = o.subsection;

        ss.anonymous = true;
        ss.addremove = true;
        ss.sortable = false;
        ss.nodescriptions = true;

        ss.handleAdd = function(ev, name) {

            var config_name = this.uciconfig || this.map.config;

            var section_id = this.map.data.add(config_name, this.sectiontype, name);

            this.map.data.set(config_name, section_id, 'ext_id', String(Date.now()));

            var mapNode = this.getPreviousModalMap();

            var prevMap = mapNode ? dom.findClassInstance(mapNode) : this.map;

            prevMap.addedSection = section_id;

            return this.renderMoreOptionsModal(section_id);
        };

		ss.option(form.Value, 'name', _('Name'));

		o = ss.option(form.ListValue, 'role', _('Role'));
		o.value('primary', _('Primary'));
		o.value('backup', _('Backup'));
		o.default = 'primary';
		o.rmempty = false;

		o.textvalue = function(section_id) {
		    var role = uci.get('xray_ext', section_id, 'role');
		    return role === 'backup' ? _('Backup') : _('Primary');
		};

		o = ss.option(form.Value, 'url', _('URL'));
		o.rmempty = false;

		o = ss.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';

		o = ss.option(form.Flag, 'add_new', _('Add New'));
		o.default = '1';

		o = ss.option(form.Flag, 'auto_remove', _('Remove Missing'));
		o.default = '0';

		o = ss.option(form.ListValue, 'interval', _('Interval'));
		o.value('30', _('30 min'));
		o.value('60', _('1 hour'));
		o.value('360', _('6 hours'));
		o.value('720', _('12 hours'));
		o.value('1440', _('1 day'));
		o.value('auto', _('Auto'));
        o.default = '360';


		/* =========================================================
		 * Раздел: TAB — Определение серверов
		 * =========================================================
		 */

		o = s.taboption(
		    'resolving',
		    form.ListValue,
		    'domain_strategy',
		    _('Domain Resolution Strategy'),
		    _('Default values for newly added servers. Existing servers will not be affected by these settings.')
		);
		o.value('UseIP', 'UseIP');
		o.value('UseIPv4', 'UseIPv4');
		o.value('UseIPv6', 'UseIPv6');
		o.default = 'UseIP';
		o.rmempty = false;

		o = s.taboption(
		    'resolving',
		    form.ListValue,
		    'domain_resolve_dns_method',
		    _('DNS Method'),
		    _('Used when a DNS server is specified below. Methods marked as "direct" bypass Xray for DNS queries.')
		);
		o.value('udp', _('UDP'));
		o.value('quic+local', _('DNS over QUIC (direct)'));
		o.value('tcp', _('TCP'));
		o.value('tcp+local', _('TCP (direct)'));
		o.value('https', _('DNS over HTTPS'));
		o.value('https+local', _('DNS over HTTPS (direct)'));
		o.default = 'udp';
		o.rmempty = false;

		o = s.taboption(
		    'resolving',
		    form.Value,
		    'domain_resolve_dns',
		    _('DNS Server for Resolution'),
		    _('DNS server address in the format IP or IP:port. Existing servers will not be modified; these values will be used when adding new ones.')
		);
		o.datatype = 'or(ipaddr, ipaddrport(1))';
		o.placeholder = '127.0.0.1:5353';
		o.default = '';

        /* =========================================================
         * Однократное применение к существующим серверам
         * =========================================================
         */

        o = s.taboption(
            'resolving',
            form.Flag,
            '_apply_resolver_settings_to_all',
			_('Apply to All Servers'),
			_('Overwrite Server Hostname Resolving settings for all xray_core servers.')
        );

        o.default = '0';
        o.rmempty = false;

        o.cfgvalue = function() {
            return '0';
        };

        o.write = function(section_id, value) {
            resolverApplyAllRequested = (value === '1');
        };


        /* =========================================================
         * Раздел: TAB — Серверы
         * =========================================================
         */

        o = s.taboption('servers', form.DummyValue, '_servers');
        o.rawhtml = true;

        o.render = function(section_id) {
            return this.cfgvalue(section_id);
        };

        o.cfgvalue = function() {

		    if (this._cachedTable)
		        return this._cachedTable;

            var sections = uci.sections('xray_core', 'servers');

            if (!sections || sections.length === 0)
                return E('em', _('No servers found'));

            var manualServers = [];
            var subscriptionServers = {};
            var indeterminateCgf = buildIndeterminateCfg();

            sections.forEach(function(server) {

                var ext = server.ext_id;

                if (!server.auto || server.auto !== '1')
                    manualServers.push(server);

                else if (ext) {
                    if (!subscriptionServers[ext])
                        subscriptionServers[ext] = [];

                    subscriptionServers[ext].push(server);
                }
            });

            var sortedServers = [];

            manualServers.forEach(function(server) {
                sortedServers.push(server);
            });

            Object.keys(subscriptionServers)
                .sort()
                .forEach(function(ext) {
                    subscriptionServers[ext].forEach(function(server) {
                        sortedServers.push(server);
                    });
                });

            var table = E('table', { 'class': 'table cbi-section-table' });

            var thead = E('thead');

            var header = E('tr', { 'class': 'tr table-titles' });

            [
				_('Subscription'),
				_('Server'),
				_('Protocol'),
				_('Transport'),
				_('Address'),
				_('Port')
            ].forEach(function(title) {
                header.appendChild(
                    E('th', { 'class': 'th' }, title)
                );
            });

            header.appendChild(E('th', { 'class': 'th' }, _('TCP v4')));

            if (ipv6_enabled)
                header.appendChild(E('th', { 'class': 'th' }, _('TCP v6')));

            header.appendChild(E('th', { 'class': 'th' }, _('UDP v4')));

            if (ipv6_enabled)
                header.appendChild(E('th', { 'class': 'th' }, _('UDP v6')));

            thead.appendChild(header);
            table.appendChild(thead);

            var tbody = E('tbody');
            var metadataRowsAdded = {};
            var columnCount = 8 + (ipv6_enabled ? 2 : 0);

            sortedServers.forEach(function(server) {

                if (server.auto === '1' && server.ext_id && !metadataRowsAdded[server.ext_id]) {
                    tbody.appendChild(renderSubscriptionMetaRow(server.ext_id, columnCount));
                    metadataRowsAdded[server.ext_id] = true;
                }

                var rowClass = server.subscription_missing === '1'
                    ? 'tr xray-ext-server-missing'
                    : 'tr';
                var row = E('tr', { 'class': rowClass });

				var source = _('Manual');

				if (server.ext_id) {
				    var name = subscriptionNames[server.ext_id];
				    source = name || (_('Subscription') + ' (' + server.ext_id + ')');
				}

				row.appendChild(E('td', { 'class': 'td' }, source));

				row.appendChild(
				    E(
				        'td',
				        { 'class': 'td' },
				        E('strong', {}, server.alias || _('Unnamed'))
				    )
				);

                row.appendChild(E('td', { 'class': 'td' }, server.protocol || '—'));
                row.appendChild(E('td', { 'class': 'td' }, server.transport || '—'));

                row.appendChild(
                    E(
                        'td',
                        { 'class': 'td' },
                        E('code', {}, server.server || '—')
                    )
                );

                row.appendChild(E('td', { 'class': 'td' }, server.server_port || '—'));

                row.appendChild(
                    E(
                        'td',
                        { 'class': 'td' },
                        mkbox('tcp_balancer_v4', cfg_tcp_v4, server, indeterminateCgf.tcp_v4)
                    )
                );

                if (ipv6_enabled) {
                    row.appendChild(
                        E(
                            'td',
                            { 'class': 'td' },
                            mkbox('tcp_balancer_v6', cfg_tcp_v6, server, indeterminateCgf.tcp_v6)
                        )
                    );
                }

                row.appendChild(
                    E(
                        'td',
                        { 'class': 'td' },
                        mkbox('udp_balancer_v4', cfg_udp_v4, server, indeterminateCgf.udp_v4)
                    )
                );

                if (ipv6_enabled) {
                    row.appendChild(
                        E(
                            'td',
                            { 'class': 'td' },
                            mkbox('udp_balancer_v6', cfg_udp_v6, server, indeterminateCgf.udp_v6)
                        )
                    );
                }

                tbody.appendChild(row);
            });

            table.appendChild(tbody);

			this._cachedTable = table;

            return table;
        };

        /* =========================================================
         * Раздел: TAB — Балансировщики
         * =========================================================
         */

        o = s.taboption('balancers', form.DummyValue, '_balancers', _('Status'));

        o.render = function() {

            var container = E(
                'div',
                { 'id': 'xray-ext-balancers' },
                _('Loading balancer information...')
            );

            startBalancerPolling(container);

            return container;
        };

        return m.render();
    }
});
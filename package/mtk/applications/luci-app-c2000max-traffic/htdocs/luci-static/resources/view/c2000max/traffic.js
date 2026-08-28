'use strict';
'require c2000max.traffic-chart as trafficChart';
'require dom';
'require form';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';
var callTrafficStatus = rpc.declare({
    object: 'c2000max.traffic',
    method: 'status',
    expect: {
        '': {}
    }
});
var callTrafficReset = rpc.declare({
    object: 'c2000max.traffic',
    method: 'reset',
    expect: {
        '': {}
    }
});
var callTrafficCatalog = rpc.declare({
    object: 'c2000max.traffic',
    method: 'catalog',
    expect: {
        '': {}
    }
});
var callCatalogInfo = rpc.declare({
    object: 'c2000max.traffic',
    method: 'catalog_info',
    params: ['profile'],
    expect: {
        '': {}
    }
});
var callCatalogSearch = rpc.declare({
    object: 'c2000max.traffic',
    method: 'catalog_search',
    params: ['profile', 'query', 'category', 'offset', 'limit'],
    expect: {
        '': {}
    }
});
var callCatalogLookup = rpc.declare({
    object: 'c2000max.traffic',
    method: 'catalog_lookup',
    params: ['profile', 'ids'],
    expect: {
        '': {}
    }
});
var callTrafficAudit = rpc.declare({
    object: 'c2000max.traffic',
    method: 'audit',
    params: ['device', 'from', 'to'],
    expect: {
        '': {}
    }
});
var callRecentAudit = rpc.declare({
    object: 'c2000max.traffic',
    method: 'recent_audit',
    params: ['offset', 'limit'],
    expect: {
        '': {}
    }
});
var callFeatureInstall = rpc.declare({
    object: 'c2000max.traffic',
    method: 'feature_install',
    expect: {
        '': {}
    }
});
var callFeatureInstallStatus = rpc.declare({
    object: 'c2000max.traffic',
    method: 'feature_install_status',
    params: ['job_id'],
    expect: {
        '': {}
    }
});
var callFeatureInstallAck = rpc.declare({
    object: 'c2000max.traffic',
    method: 'feature_install_ack',
    params: ['job_id'],
    expect: {
        '': {}
    }
});
var callFeatureList = rpc.declare({
    object: 'c2000max.traffic',
    method: 'feature_list',
    expect: {
        '': {}
    }
});
var callFeatureActivate = rpc.declare({
    object: 'c2000max.traffic',
    method: 'feature_activate',
    params: ['id'],
    expect: {
        '': {}
    }
});
var callFeatureRollback = rpc.declare({
    object: 'c2000max.traffic',
    method: 'feature_rollback',
    expect: {
        '': {}
    }
});
var callPolicyReload = rpc.declare({
    object: 'c2000max.traffic',
    method: 'policy_reload',
    expect: {
        '': {}
    }
});
var currentProfileId = '';
var auditModalSequence = 0;
var featureInstallInProgress = false;
var featureJobBannerNode = null;
var featureJobBannerStatus = {
    state: 'idle'
};
var featureJobRecoveryStarted = false;

function resolveWithin(promise, fallback, timeout) {
    return new Promise(function(resolve) {
        var settled = false;
        var timer = setTimeout(function() {
            if (!settled) {
                settled = true;
                resolve(fallback);
            }
        }, Math.max(1, Number(timeout) || 1));
        Promise.resolve(promise).then(function(value) {
            if (settled)
                return;
            settled = true;
            clearTimeout(timer);
            resolve(value);
        }, function() {
            if (settled)
                return;
            settled = true;
            clearTimeout(timer);
            resolve(fallback);
        });
    });
}

function safeText(value) {
    return [String(value == null ? '' : value)];
}

function safeChoice(value) {
    return E('span', {}, safeText(value));
}

function destroyCharts(root) {
    if (!root)
        return;
    if (root.classList && root.classList.contains('c2000max-chart-frame'))
        root.dispatchEvent(new CustomEvent('c2000max-chart-destroy'));
    root.querySelectorAll('.c2000max-chart-frame').forEach(function(chart) {
        chart.dispatchEvent(new CustomEvent('c2000max-chart-destroy'));
    });
}

function bytes(value) {
    var number = Number(value || 0);
    var units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
    var unit = 0;
    if (!isFinite(number) || number < 0)
        number = 0;
    while (number >= 1024 && unit < units.length - 1) {
        number /= 1024;
        unit++;
    }
    return '%s %s'.format(number.toFixed(unit === 0 ? 0 : 2), units[unit]);
}

function speed(value) {
    return '%s/s'.format(bytes(value));
}

function accelerationName(value) {
    return ({
        mediatek_hnat: 'MediaTek HNAT',
        flow_offloading: 'Flow Offloading',
        disabled: '普通转发'
    })[value] || value || '未知';
}

function sourceName(value) {
    return ({
        hardware_mib: 'HNAT 硬件 MIB → Conntrack',
        flowtable_conntrack: 'Flowtable → Conntrack',
        conntrack: 'Conntrack'
    })[value] || value || '未知';
}

function auditModeName(mode) {
    if (mode === 'balanced') return '均衡（最多检查 8 个有效载荷包）';
    if (mode === 'precise') return '精确（最多检查 64 个有效载荷包）';
    return '无感（机会式识别）';
}

function controlModeName(mode) {
    if (mode === 'force') return '强力管控（定向重检）';
    if (mode === 'strict') return '选择性严格（仅待识别/封禁流暂缓 HNAT）';
    if (mode === 'deep') return '全局深度实验（全部 LAN 绕过加速）';
    return '无感管控（新连接生效）';
}

function trafficPair(upload, download) {
    return E('span', {}, [E('span', {
        'style': 'white-space:nowrap'
    }, ['↑ ', bytes(upload)]), ' / ', E('span', {
        'style': 'white-space:nowrap'
    }, ['↓ ', bytes(download)])]);
}

function historyTotal(point, direction) {
    return Number(point['fiveg_' + direction] || 0) +
        Number(point['other_' + direction] || 0) +
        Number(point['unknown_' + direction] || 0);
}

function asArray(value) {
    if (Array.isArray(value))
        return value;
    if (value && typeof value === 'object')
        return Object.keys(value).map(function(key) {
            return value[key];
        });
    return [];
}

function profileItems(data) {
    return asArray((data || {}).profiles || (data || {}).libraries || (data || {}).items);
}

function profileId(profile) {
    return String((profile || {}).id || (profile || {}).sha256 || '');
}

function ikDisplay(value) {
    return String(value == null ? '' : value).replace(/i\x6buai/ig, 'ik').replace(/\u7231\u5feb/g, 'ik');
}

function profileLabel(profile) {
    var source = String((profile || {}).source_format || (profile || {}).type || 'oaf-v3');
    var label = ikDisplay((profile || {}).label || (profile || {}).name || (profile || {}).version || profileId(profile).slice(0, 12));
    if (source === 'ik-native-v1')
        return 'ik 原生库 %s'.format(label);
    if (/i\x6buai/i.test(source) || /-i\x6buai$/i.test(String((profile || {}).version || '')))
        return 'ik OAF 转换库 %s'.format(label);
    return '特征库 %s'.format(label);
}

function resultError(result, fallback) {
    if (result && result.success === true)
        return null;
    return new Error((result && (result.message || result.error)) || fallback);
}

function rejectConcurrentFeatureJob() {
    if (!featureInstallInProgress)
        return false;
    ui.addNotification(null, E('p', {}, '已有特征库操作正在后台执行，请等待完成后再试。'));
    return true;
}

function featureJobStartCanRelease(result) {
    var state = String((result || {}).state || '');
    return !!(result && (result.busy === true || result.accepted === false || state === 'done' || state === 'failed' || state === 'missing' || state === 'idle' || (result.success === false && state !== 'queued' && state !== 'running')));
}

function featureInstallDelay() {
    return new Promise(function(resolve) {
        window.setTimeout(resolve, 2000);
    });
}

function featureJobPhaseName(status) {
    var phase = String((status || {}).phase || '');
    return ({
        queued: '等待后台任务',
        migrate: '整理旧库审计记录',
        install: '校验、编译并加载规则',
        activate: '切换并重载规则库',
        rollback: '回退并重载规则库',
        done: '处理完成',
        failed: '处理失败',
        upload: '上传文件'
    })[phase] || '后台处理特征库';
}

function renderFeatureJobBanner() {
    if (!featureJobBannerNode)
        return;
    var status = featureJobBannerStatus || {};
    var state = String(status.state || 'idle');
    var phase = featureJobPhaseName(status);
    var message = ikDisplay(status.message || '');
    var body;
    featureJobBannerNode.style.display = state === 'idle' ? 'none' : '';
    featureJobBannerNode.className = 'alert-message ' +
        (state === 'failed' || state === 'missing' ? 'warning' : 'notice');
    if (state === 'idle') {
        L.dom.content(featureJobBannerNode, []);
        return;
    }
    body = E('div', {
        'style': 'display:flex;gap:.75em;align-items:flex-start'
    }, [E('span', {
        'class': state === 'queued' || state === 'running' || state === 'upload' ? 'spinning' : null,
        'style': 'min-width:1.2em;min-height:1.2em'
    }), E('div', {}, [E('strong', {}, safeText('特征库：%s'.format(phase))), E('div', {
        'style': 'margin-top:.2em'
    }, safeText(message || (state === 'done' ? '最近一次特征库操作已完成。' : state === 'failed' ? '最近一次特征库操作失败。' : '任务正在路由器后台执行，请勿断电。'))), (state === 'queued' || state === 'running' || state === 'upload') ? E('div', {
        'style': 'color:#777;font-size:90%;margin-top:.25em'
    }, '可以留在当前页面或切换标签；重新进入本页仍会显示任务进度。') : ''])]);
    L.dom.content(featureJobBannerNode, body);
}

function updateFeatureJobBanner(status) {
    featureJobBannerStatus = status && typeof status === 'object' ? status : {
        state: 'idle'
    };
    renderFeatureJobBanner();
}

function acknowledgeFeatureJob(jobId) {
    if (!jobId)
        return Promise.resolve();
    return resolveWithin(callFeatureInstallAck(jobId), {}, 5000).then(function() {
        updateFeatureJobBanner({
            state: 'idle'
        });
    });
}

function waitFeatureInstall(jobId, progress, failures) {
    return resolveWithin(callFeatureInstallStatus(jobId), null, 5000).then(function(status) {
        if (!status) {
            failures = Number(failures || 0) + 1;
            if (failures >= 5)
                throw new Error('连续无法查询特征库操作进度，请稍后重新进入页面查看。');
            return featureInstallDelay().then(function() {
                return waitFeatureInstall(jobId, progress, failures);
            });
        }
        var state = String((status || {}).state || '');
        updateFeatureJobBanner(status);
        if (state === 'done') {
            featureInstallInProgress = false;
            var result = status.result || status;
            var error = resultError(result, '特征库操作失败');
            if (error) throw error;
            return acknowledgeFeatureJob(jobId).then(function() { return result; });
        }
        if (state === 'failed' || state === 'missing' || state === 'idle') {
            featureInstallInProgress = false;
            var failure = new Error((status && (status.message || status.error)) || '特征库后台操作失败');
            return acknowledgeFeatureJob(jobId).then(function() {
                throw failure;
            });
        }
        if (state !== 'queued' && state !== 'running')
            throw new Error('特征库后台任务返回了未知状态');
        if (progress)
            L.dom.content(progress, safeText(ikDisplay(status.message || '正在后台处理特征库…')));
        return featureInstallDelay().then(function() {
            return waitFeatureInstall(jobId, progress, 0);
        });
    });
}

function resolveFeatureJobStart(result, progress, fallback) {
    var state = String((result || {}).state || '');
    if (result && (result.busy === true || result.accepted === false))
        throw resultError(result, '已有特征库操作任务正在运行') || new Error('已有特征库操作任务正在运行');
    if (state === 'done') {
        var doneResult = result.result || result;
        var doneError = resultError(doneResult, fallback);
        if (doneError) throw doneError;
        return Promise.resolve(doneResult);
    }
    if (state === 'queued' || state === 'running') {
        if (!result.job_id)
            throw new Error('后台任务没有返回任务编号');
        if (progress)
            L.dom.content(progress, safeText(ikDisplay(result.message || '任务已提交，正在后台处理…')));
        updateFeatureJobBanner(result);
        return waitFeatureInstall(result.job_id, progress, 0);
    }
    var error = resultError(result, fallback);
    if (error) throw error;
    return Promise.resolve(result);
}

function appChoiceLabel(app) {
    if (!app)
        return '';
    var suffix = app.missing ? '（已失效）' : '';
    return '【%s】%s%s  #%s'.format(app.category || '未知', app.name || '应用', suffix, app.id);
}

function showAppPicker(option, widget) {
    var selected = {};
    var labels = option.labelCache || (option.labelCache = {});
    var profile = option.profile || currentProfileId;
    var categories = asArray(option.categories);
    var parentModalNode = document.querySelector('#modal_overlay > .modal');
    var parentModal = document.body.classList.contains('modal-overlay-active') && parentModalNode ? {
        node: parentModalNode,
        className: parentModalNode.className,
        children: Array.prototype.slice.call(parentModalNode.childNodes),
        scrollTop: parentModalNode.parentNode.scrollTop
    } : null;
    var sequence = 0;
    var page = 0;
    var pageSize = 50;
    var debounce = null;
    var currentItems = [];
    var selectedOnly = false;
    var query = E('input', {
        'class': 'cbi-input-text',
        'type': 'search',
        'placeholder': '输入软件名称或 APPID',
        'style': 'min-width:240px;flex:1'
    });
    var category = E('select', {
        'class': 'cbi-input-select',
        'style': 'min-width:170px'
    }, [E('option', {
        'value': '0'
    }, '全部分类')].concat(categories.map(function(item) {
        return E('option', {
            'value': String(item.id)
        }, safeText('%s（%s）'.format(item.name, Number(item.count || 0))));
    })));
    var resultBody = E('div', {}, E('p', {
        'class': 'spinning'
    }, '正在查询…'));
    var selectedStatus = E('span');
    var pageStatus = E('span');
    var previous = E('button', {
        'class': 'btn',
        'type': 'button',
        'disabled': ''
    }, '上一页');
    var next = E('button', {
        'class': 'btn',
        'type': 'button',
        'disabled': ''
    }, '下一页');
    var selectPage = E('button', {
        'class': 'btn',
        'type': 'button'
    }, '全选当前页');
    var showSelected = E('button', {
        'class': 'btn',
        'type': 'button'
    }, '只显示已选');
    var clearSelected = E('button', {
        'class': 'btn cbi-button-negative',
        'type': 'button'
    }, '全部取消');
    L.toArray(widget.getValue()).forEach(function(id) {
        selected[String(id)] = true;
    });

    function closePicker(ev) {
        if (ev) {
            ev.preventDefault();
            ev.stopPropagation();
        }
        sequence++;
        if (debounce)
            clearTimeout(debounce);
        if (!parentModal) {
            ui.hideModal();
            return;
        }
        parentModal.node.setAttribute('class', parentModal.className);
        L.dom.content(parentModal.node, parentModal.children);
        document.body.classList.add('modal-overlay-active');
        parentModal.node.parentNode.scrollTop = parentModal.scrollTop;
    }

    function updateSelectedStatus() {
        var count = Object.keys(selected).length;
        L.dom.content(selectedStatus, '已选 %d 个（单项最多 256 个，大批量建议直接选分类）'.format(count));
    }

    function renderResults(result, requestPage) {
        var items = asArray(result.items || result.apps);
        currentItems = items;
        var total = Number(result.total || 0);
        var pageCount = Math.max(1, Math.ceil(total / pageSize));
        page = Math.max(0, Math.min(requestPage, pageCount - 1));
        var rows = items.map(function(app) {
            var id = String(app.id);
            labels[id] = appChoiceLabel(app);
            var checkbox = E('input', {
                'type': 'checkbox',
                'checked': selected[id] ? '' : null,
                'change': function(ev) {
                    if (ev.target.checked && !selected[id] && Object.keys(selected).length >= 256) {
                        ev.target.checked = false;
                        ui.addNotification(null, E('p', {}, '单项软件最多选择 256 个；请使用“应用分类”处理整类软件。'));
                        return;
                    }
                    if (ev.target.checked)
                        selected[id] = true;
                    else
                        delete selected[id];
                    updateSelectedStatus();
                }
            });
            return E('div', {
                'class': 'tr'
            }, [E('div', {
                'class': 'td',
                'style': 'width:3em;text-align:center'
            }, checkbox), E('div', {
                'class': 'td'
            }, [E('strong', {}, safeText(app.name || '未知应用')), E('div', {
                'style': 'color:#777;font-size:90%'
            }, safeText(app.category || '未知分类'))]), E('div', {
                'class': 'td',
                'style': 'width:8em;white-space:nowrap'
            }, '#%s'.format(id))]);
        });
        if (!rows.length)
            rows.push(E('div', {
                'class': 'tr'
            }, E('div', {
                'class': 'td'
            }, '没有匹配的软件。')));
        L.dom.content(resultBody, E('div', {
            'class': 'table cbi-section-table'
        }, [E('div', {
            'class': 'tr table-titles'
        }, [E('div', {
            'class': 'th',
            'style': 'width:3em'
        }, '选择'), E('div', {
            'class': 'th'
        }, '软件'), E('div', {
            'class': 'th',
            'style': 'width:8em'
        }, 'APPID')])].concat(rows)));
        previous.disabled = page <= 0;
        next.disabled = !result.has_more && page >= pageCount - 1;
        L.dom.content(pageStatus, '第 %d / %d 页，共 %d 个可识别软件'.format(page + 1, pageCount, total));
    }

    function loadPage(wantedPage) {
        if (selectedOnly) {
            var selectedItems = Object.keys(selected).sort(function(a, b) {
                return Number(a) - Number(b);
            }).map(function(id) {
                return {
                    id: id,
                    name: labels[id] || '应用 #%s'.format(id),
                    category: '已选应用'
                };
            });
            renderResults({
                items: selectedItems,
                total: selectedItems.length
            }, 0);
            return Promise.resolve();
        }
        var requestSequence = ++sequence;
        var wantedQuery = query.value.trim();
        var wantedCategory = Number(category.value || 0);
        previous.disabled = true;
        next.disabled = true;
        L.dom.content(resultBody, E('p', {
            'class': 'spinning'
        }, '正在查询…'));
        return L.resolveDefault(callCatalogSearch(profile, wantedQuery, wantedCategory, Math.max(0, wantedPage) * pageSize, pageSize), {
            items: [],
            total: 0
        }).then(function(result) {
            if (requestSequence !== sequence || !document.body.contains(resultBody))
                return;
            if (result.success !== true)
                throw new Error(result.message || result.error || '查询软件失败');
            if (result.profile && result.profile !== profile)
                return;
            renderResults(result, wantedPage);
        }).catch(function(error) {
            if (requestSequence === sequence)
                L.dom.content(resultBody, E('div', {
                    'class': 'alert-message warning'
                }, safeText(error.message)));
        });
    }
    query.addEventListener('input', function() {
        if (debounce)
            clearTimeout(debounce);
        debounce = setTimeout(function() {
            loadPage(0);
        }, 300);
    });
    query.addEventListener('keydown', function(ev) {
        if (ev.key === 'Enter') {
            ev.preventDefault();
            if (debounce)
                clearTimeout(debounce);
            loadPage(0);
        }
    });
    category.addEventListener('change', function() {
        loadPage(0);
    });
    previous.addEventListener('click', function(ev) {
        ev.preventDefault();
        loadPage(page - 1);
    });
    next.addEventListener('click', function(ev) {
        ev.preventDefault();
        loadPage(page + 1);
    });
    selectPage.addEventListener('click', function(ev) {
        ev.preventDefault();
        for (var i = 0; i < currentItems.length; i++) {
            var id = String(currentItems[i].id);
            if (!selected[id] && Object.keys(selected).length >= 256)
                break;
            selected[id] = true;
            labels[id] = appChoiceLabel(currentItems[i]);
        }
        updateSelectedStatus();
        loadPage(page);
    });
    showSelected.addEventListener('click', function(ev) {
        ev.preventDefault();
        selectedOnly = !selectedOnly;
        query.disabled = selectedOnly;
        category.disabled = selectedOnly;
        showSelected.textContent = selectedOnly ? '返回搜索结果' : '只显示已选';
        loadPage(selectedOnly ? 0 : page);
    });
    clearSelected.addEventListener('click', function(ev) {
        ev.preventDefault();
        selected = {};
        updateSelectedStatus();
        loadPage(selectedOnly ? 0 : page);
    });
    updateSelectedStatus();
    if (parentModal)
        parentModal.children.forEach(function(child) {
            if (child.parentNode === parentModal.node)
                parentModal.node.removeChild(child);
        });
    ui.showModal('选择软件', [E('div', {
        'style': 'max-height:calc(100vh - 190px);overflow:auto;padding-right:.5em'
    }, [E('div', {
        'style': 'display:flex;gap:.6em;align-items:center;flex-wrap:wrap;margin-bottom:.75em'
    }, [query, category]), E('div', {
        'style': 'display:flex;gap:.5em;align-items:center;flex-wrap:wrap;margin-bottom:.6em'
    }, [selectedStatus, selectPage, showSelected, clearSelected]), resultBody, E('div', {
        'style': 'display:flex;justify-content:flex-end;align-items:center;gap:.6em;margin-top:.75em;flex-wrap:wrap'
    }, [previous, pageStatus, next])]), E('div', {
        'class': 'right'
    }, [E('button', { 'class': 'btn', 'type': 'button', 'click': closePicker }, '取消'), ' ', E('button', {
        'class': 'btn cbi-button-positive important',
        'type': 'button',
        'click': function(ev) {
            ev.preventDefault();
            ev.stopPropagation();
            var ids = Object.keys(selected).sort(function(a, b) {
                return Number(a) - Number(b);
            });
            var selectedLabels = {};
            ids.forEach(function(id) {
                selectedLabels[id] = safeText(labels[id] || '应用 #%s'.format(id));
            });
            widget.clearChoices(true);
            widget.addChoices(ids, selectedLabels);
            widget.setValue(ids);
            closePicker();
        }
    }, '使用已选软件')])], 'c2000max-app-picker-modal');
    loadPage(0);
}
var LazyAppSelector = form.MultiValue.extend({
    renderWidget: function(sectionId, optionIndex, cfgvalue) {
        var values = L.toArray(cfgvalue != null ? cfgvalue : this.default).map(String);
        var labels = this.labelCache || (this.labelCache = {});
        var choices = {};
        values.forEach(function(id) {
            choices[id] = safeText(labels[id] || '应用 #%s'.format(id));
        });
        var widget = new ui.Dropdown(values, choices, {
            id: this.cbid(sectionId),
            multiple: true,
            optional: true,
            create: false,
            display_items: 1,
            dropdown_items: 12,
            select_placeholder: '尚未选择单项软件',
            disabled: (this.readonly != null) ? this.readonly : this.map.readonly,
            validate: this.getValidator(sectionId)
        });
        var widgetNode = widget.render();
        var countNode = E('span', {
            'style': 'color:#777'
        });

        function updateCount() {
            L.dom.content(countNode, '已选 %d 个'.format(L.toArray(widget.getValue()).length));
        }
        widgetNode.addEventListener('cbi-dropdown-change', updateCount);
        updateCount();
        return E('div', {
            'class': 'c2000max-app-selector'
        }, [widgetNode, E('div', {
            'style': 'display:flex;align-items:center;gap:.6em;margin-top:.5em;flex-wrap:wrap'
        }, [E('button', {
            'class': 'btn cbi-button-action',
            'type': 'button',
            'disabled': ((this.readonly != null) ? this.readonly : this.map.readonly) ? '' : null,
            'click': function(ev) {
                ev.preventDefault();
                ev.stopPropagation();
                showAppPicker(this, widget);
            }.bind(this)
        }, '搜索并选择软件'), countNode])]);
    },
    validate: function(sectionId, value) {
        var values = L.toArray(value);
        if (values.length > 256)
            return '单项软件最多选择 256 个；请使用应用分类。';
        for (var i = 0; i < values.length; i++)
            if (!/^[0-9]+$/.test(String(values[i])))
                return '应用 APPID 必须是数字。';
        return true;
    }
});
var TimeWindowSelector = form.DynamicList.extend({
    cfgvalue: function(sectionId) {
        var config = this.uciconfig || this.section.uciconfig || this.map.config;
        var section = this.ucisection || sectionId;
        var current = this.map.data.get(config, section, this.ucioption || this.option);
        if (current != null)
            return current;
        var days = L.toArray(this.map.data.get(config, section, 'days'));
        var start = String(this.map.data.get(config, section, 'start') || '00:00');
        var end = String(this.map.data.get(config, section, 'end') || '00:00');
        if (!days.length)
            days = ['0', '1', '2', '3', '4', '5', '6'];
        return days.map(function(day) {
            return '%s@%s-%s'.format(day, start, end);
        });
    },
    formvalue: function(sectionId) {
        var element = this.getUIElement(sectionId),
            values = element ? element.getValue() : null;

        if (values != null)
            return L.toArray(values);

        var node = this.map.findElement('id', this.cbid(sectionId));
        return node ? Array.prototype.map.call(node.querySelectorAll('.item > input[type="hidden"]'), function(input) {
            return input.value;
        }) : [];
    },
    renderWidget: function(sectionId, optionIndex, cfgvalue) {
        var dayNames = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
        var items = L.toArray(cfgvalue != null ? cfgvalue : this.default);
        var choices = {};
        items.forEach(function(token) {
            var match = String(token).match(/^([0-6])@([0-9:]+)-([0-9:]+)$/);
            if (match)
                choices[token] = '%s %s–%s'.format(dayNames[Number(match[1])], match[2], match[3]);
        });
        var widget = new ui.DynamicList(items, choices, {
            id: this.cbid(sectionId),
            optional: false,
            disabled: (this.readonly != null) ? this.readonly : this.map.readonly
        });
        var widgetNode = widget.render();
        var day = E('select', {
            'class': 'cbi-input-select'
        }, dayNames.map(function(name, index) {
            return E('option', {
                'value': String(index)
            }, name);
        }));
        day.value = '1';
        var start = E('input', {
            'class': 'cbi-input-text',
            'type': 'time',
            'value': '10:00'
        });
        var end = E('input', {
            'class': 'cbi-input-text',
            'type': 'time',
            'value': '12:00'
        });
        var add = E('button', {
            'class': 'btn cbi-button-add',
            'type': 'button',
            'click': function(ev) {
                ev.preventDefault();
                var token = '%s@%s-%s'.format(day.value, start.value, end.value);
                if (!/^([0-6])@(?:[01][0-9]|2[0-3]):[0-5][0-9]-(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(token)) {
                    ui.addNotification(null, E('p', {}, '请选择有效的开始和结束时间。'));
                    return;
                }
                if (widget.getValue().indexOf(token) < 0)
                    widget.addItem(widget.node, token, '%s %s–%s'.format(dayNames[Number(day.value)], start.value, end.value), true);
            }
        }, '添加时段');

        function presetButton(label, days) {
            return E('button', {
                'class': 'btn cbi-button-action',
                'type': 'button',
                'click': function(ev) {
                    ev.preventDefault();
                    var values = days.map(function(value) {
                        return '%s@00:00-00:00'.format(value);
                    });
                    widget.setValue(values);
                }
            }, label);
        }
        return E('div', {
            'class': 'c2000max-time-windows'
        }, [E('div', {
            'style': 'display:flex;gap:.5em;align-items:center;flex-wrap:wrap;margin-bottom:.6em'
        }, [E('span', {}, '快捷设置：'), presetButton('全天', ['0', '1', '2', '3', '4', '5', '6']), presetButton('工作日', ['1', '2', '3', '4', '5']), presetButton('周末', ['0', '6'])]), E('div', {
            'style': 'display:flex;gap:.5em;align-items:center;flex-wrap:wrap;margin-bottom:.6em'
        }, [day, start, E('span', {}, '至'), end, add]), widgetNode, E('div', {
            'style': 'color:#777;margin-top:.35em'
        }, '每条规则可添加任意多个独立时段；起止相同表示全天，结束早于开始表示跨午夜。')]);
    },
    isValid: function(sectionId) {
        var result = this.validate(sectionId, this.formvalue(sectionId));
        this.timeWindowValidationError = result === true ? '' : String(result);
        return result === true;
    },
    getValidationError: function() {
        return this.timeWindowValidationError || '';
    },
    validate: function(sectionId, value) {
        var values = L.toArray(value);
        var dayNames = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
        var intervals = [
            [],
            [],
            [],
            [],
            [],
            [],
            []
        ];
        if (!values.length)
            return '请至少添加一个生效时段。';
        for (var i = 0; i < values.length; i++) {
            var token = String(values[i]);
            var match = token.match(/^([0-6])@((?:[01][0-9]|2[0-3]):[0-5][0-9])-((?:[01][0-9]|2[0-3]):[0-5][0-9])$/);
            if (!match)
                return '时段格式无效，请删除后用上方控件重新添加。';
            var day = Number(match[1]);
            var startParts = match[2].split(':');
            var endParts = match[3].split(':');
            var startMinute = Number(startParts[0]) * 60 + Number(startParts[1]);
            var endMinute = Number(endParts[0]) * 60 + Number(endParts[1]);
            var label = '%s %s–%s'.format(dayNames[day], match[2], match[3]);
            if (startMinute === endMinute)
                intervals[day].push({
                    start: 0,
                    end: 1440,
                    label: label
                });
            else if (startMinute < endMinute)
                intervals[day].push({
                    start: startMinute,
                    end: endMinute,
                    label: label
                });
            else {
                intervals[day].push({
                    start: startMinute,
                    end: 1440,
                    label: label
                });
                intervals[(day + 1) % 7].push({
                    start: 0,
                    end: endMinute,
                    label: label
                });
            }
        }
        for (var d = 0; d < intervals.length; d++) {
            intervals[d].sort(function(a, b) {
                return a.start - b.start || a.end - b.end;
            });
            for (var j = 1; j < intervals[d].length; j++)
                if (intervals[d][j].start < intervals[d][j - 1].end)
                    return '生效时段冲突：%s 与 %s 在%s重叠。'.format(intervals[d][j - 1].label, intervals[d][j].label, dayNames[d]);
        }
        return true;
    }
});

var RuleGridSection = form.GridSection.extend({
    handleAdd: function() {
        if (!currentProfileId) {
            ui.addNotification(null, E('p', {}, '当前规则库尚未初始化，暂时不能创建管控规则。请先在“设置”中安装或激活规则库。'));
            return Promise.resolve();
        }
        var sectionId = this.map.data.add(this.uciconfig || this.map.config, this.sectiontype);
        this.map.data.set('c2000max_traffic', sectionId, 'enabled', '1');
        this.map.data.set('c2000max_traffic', sectionId, 'name', '新管控规则');
        this.map.data.set('c2000max_traffic', sectionId, 'ruleset', currentProfileId);
        this.map.data.set('c2000max_traffic', sectionId, 'target', 'all');
        this.map.data.set('c2000max_traffic', sectionId, 'match_mode', 'category');
        this.map.data.set('c2000max_traffic', sectionId, 'time_windows', ['0@00:00-00:00', '1@00:00-00:00', '2@00:00-00:00', '3@00:00-00:00', '4@00:00-00:00', '5@00:00-00:00', '6@00:00-00:00']);
        this.map.addedSection = sectionId;
        return this.renderMoreOptionsModal(sectionId);
    },
    handleModalSave: function(modalMap, ev) {
        var mapNode = this.getActiveModalMap();
        var activeMap = mapNode ? dom.findClassInstance(mapNode) : null;
        var invalid;
        var saveTasks;

        function reportSaveError(error) {
            var message = error && error.message ? String(error.message) : '',
                oldError = mapNode && mapNode.querySelector('.c2000max-rule-save-error'),
                inlineError;
            invalid = mapNode && mapNode.querySelector('.cbi-input-invalid, .cbi-value-error');
            if (!message || message === '[object Object]')
                message = invalid ? '保存失败，请检查弹窗中标红或提示有误的字段。' : '保存失败，未能写入这条管控规则。';
            if (oldError)
                oldError.remove();
            inlineError = E('div', {
                'class': 'alert-message error c2000max-rule-save-error',
                'style': 'position:relative;z-index:1;margin:.5em 0 1em'
            }, E('p', {}, safeText(message)));
            if (mapNode)
                mapNode.insertBefore(inlineError, mapNode.firstChild);
            else
                ui.addNotification(null, E('p', {}, safeText(message)));
            if (invalid) {
                invalid.scrollIntoView({
                    behavior: 'smooth',
                    block: 'center'
                });
                if (invalid.focus)
                    invalid.focus();
            }
        }

        if (!activeMap) {
            reportSaveError(new Error('保存失败：规则编辑窗口已经失效，请关闭后重新打开。'));
            return Promise.resolve();
        }

        var oldError = mapNode.querySelector('.c2000max-rule-save-error');
        if (oldError)
            oldError.remove();

        try {
            saveTasks = activeMap.save(null, true);
        } catch (error) {
            reportSaveError(error);
            return Promise.resolve();
        }

        while (activeMap.parent) {
            activeMap = activeMap.parent;
            saveTasks = saveTasks
                .then(L.bind(activeMap.load, activeMap))
                .then(L.bind(activeMap.reset, activeMap));
        }

        return saveTasks
            .then(L.bind(this.handleModalCancel, this, modalMap, ev, true))
            .catch(function(error) {
                reportSaveError(error);
            });
    }
});

function renderFeatureManager(featureData, catalog) {
    var profiles = profileItems(featureData);
    var active = String((catalog || {}).profile || (catalog || {}).profile_id || (featureData || {}).active || (featureData || {}).active_id || currentProfileId);
    var previousId = String((featureData || {}).previous || (featureData || {}).previous_id || '');
    var selector = E('select', {
        'class': 'cbi-input-select',
        'style': 'min-width:280px;max-width:100%'
    });
    profiles.forEach(function(profile) {
        var id = profileId(profile);
        if (!id)
            return;
        selector.appendChild(E('option', {
            'value': id,
            'selected': id === active ? '' : null,
            'title': id
        }, safeText('%s · %d 软件 · %d 特征'.format(profileLabel(profile), Number(profile.apps || profile.app_count || 0), Number(profile.features || profile.feature_count || 0)))));
    });
    if (!selector.children.length)
        selector.appendChild(E('option', {
            'value': active
        }, safeText(ikDisplay(catalog.version || '当前特征库'))));

    function activate(id) {
        if (rejectConcurrentFeatureJob())
            return;
        var progress = E('p', {
            'style': 'color:#777'
        }, '确认后将在后台执行切换。');
        ui.showModal('切换特征库', [E('p', {}, '切换时会先完成当前流量记账，再重载特征并重建客户端连接。现有连接可能短暂中断。'), E('p', {}, '管控规则按规则库隔离：只有属于新规则库的规则会生效，历史应用流量仍按原规则库显示。'), progress, E('div', {
            'class': 'right'
        }, [E('button', {
            'class': 'btn',
            'click': ui.hideModal
        }, '取消'), ' ', E('button', {
            'class': 'btn cbi-button-positive important',
            'click': function(ev) {
                var releaseOnError = false;
                var startResponseReceived = false;
                if (rejectConcurrentFeatureJob())
                    return Promise.resolve();
                ev.target.classList.add('spinning');
                ev.target.disabled = true;
                featureInstallInProgress = true;
                return callFeatureActivate(id).then(function(result) {
                    startResponseReceived = true;
                    releaseOnError = featureJobStartCanRelease(result);
                    return resolveFeatureJobStart(result, progress, '特征库切换失败');
                }).then(function() {
                    featureInstallInProgress = false;
                    location.reload();
                }).catch(function(error) {
                    if (releaseOnError)
                        featureInstallInProgress = false;
                    ui.hideModal();
                    ui.addNotification(null, E('p', {}, safeText(startResponseReceived ? error.message : '无法确认切换任务是否已提交；请稍后重新进入页面查看状态。')));
                });
            }
        }, '确认切换')])]);
    }
    var activeProfile = profiles.filter(function(profile) {
        return profileId(profile) === active;
    })[0] || {};
    var sourceTotal = Number(activeProfile.source_apps || activeProfile.source_total || 0);
    var nativeProfile = String(activeProfile.source_format || '') === 'ik-native-v1';
    return E('div', {}, [E('div', {
        'style': 'display:flex;gap:.6em;align-items:center;flex-wrap:wrap'
    }, [selector, E('button', {
        'class': 'btn cbi-button-action',
        'click': function(ev) {
            ev.preventDefault();
            if (selector.value === active) {
                ui.addNotification(null, E('p', {}, '该特征库已在使用。'));
                return;
            }
            activate(selector.value);
        }
    }, '切换到选中库'), E('button', {
        'class': 'btn',
        'disabled': previousId && previousId !== active ? null : '',
        'click': function(ev) {
            ev.preventDefault();
            if (rejectConcurrentFeatureJob())
                return;
            var progress = E('p', {
                'style': 'color:#777'
            }, '确认后将在后台执行回退。');
            ui.showModal('回退特征库', [E('p', {}, '确定切回上一个活动特征库吗？同样会重建现有客户端连接。'), progress, E('div', {
                'class': 'right'
            }, [E('button', {
                'class': 'btn',
                'click': ui.hideModal
            }, '取消'), ' ', E('button', {
                'class': 'btn cbi-button-positive important',
                'click': function(buttonEvent) {
                    var releaseOnError = false;
                    var startResponseReceived = false;
                    if (rejectConcurrentFeatureJob())
                        return Promise.resolve();
                    buttonEvent.target.classList.add('spinning');
                    buttonEvent.target.disabled = true;
                    featureInstallInProgress = true;
                    return callFeatureRollback().then(function(result) {
                        startResponseReceived = true;
                        releaseOnError = featureJobStartCanRelease(result);
                        return resolveFeatureJobStart(result, progress, '特征库回退失败');
                    }).then(function() {
                        featureInstallInProgress = false;
                        location.reload();
                    }).catch(function(error) {
                        if (releaseOnError)
                            featureInstallInProgress = false;
                        ui.hideModal();
                        ui.addNotification(null, E('p', {}, safeText(startResponseReceived ? error.message : '无法确认回退任务是否已提交；请稍后重新进入页面查看状态。')));
                    });
                }
            }, '确认回退')])]);
        }
    }, '回退上一库')]), E('div', {
        'style': 'color:#777;margin-top:.5em'
    }, [String('当前：%s，%d 个可识别软件'.format(ikDisplay(catalog.version || '未知'), Number(catalog.total_apps || catalog.apps || 0))), sourceTotal > Number(catalog.total_apps || 0) ? (nativeProfile ? '；来源库共 %d 个 APPID，%d 个未能被原生匹配器安全兼容。' : '；来源库共 %d 个 APPID，%d 个因 OAF 无法等价表达而未转换。').format(sourceTotal, sourceTotal - Number(catalog.total_apps || 0)) : '。']), E('div', {
        'style': 'color:#777;font-size:90%;margin-top:.35em;word-break:break-all'
    }, safeText('规则库 ID：%s'.format(active || '未初始化')))]);
}

function renderChart(history) {
    var samples = [];
    var maxRate = 0;
    history = asArray(history).filter(function(point) {
        return point && isFinite(Number(point.timestamp)) && Number(point.timestamp) > 0;
    }).sort(function(a, b) {
        return Number(a.timestamp) - Number(b.timestamp);
    }).filter(function(point, index, list) {
        return index === list.length - 1 || Number(point.timestamp) !== Number(list[index + 1].timestamp);
    });
    if (history.length === 1)
        samples.push({
            timestamp: Number(history[0].timestamp),
            upload: 0,
            download: 0
        });
    for (var i = 1; i < history.length; i++) {
        var elapsed = Number(history[i].timestamp) - Number(history[i - 1].timestamp);
        if (elapsed <= 0)
            continue;
        var up = Math.max(0, historyTotal(history[i], 'upload') -
            historyTotal(history[i - 1], 'upload')) / elapsed;
        var down = Math.max(0, historyTotal(history[i], 'download') -
            historyTotal(history[i - 1], 'download')) / elapsed;
        maxRate = Math.max(maxRate, up, down);
        samples.push({
            timestamp: Number(history[i].timestamp),
            upload: up,
            download: down
        });
    }
    if (samples.length > 240)
        samples = samples.slice(samples.length - 240);
    if (!samples.length)
        return E('div', {
            'class': 'alert-message notice'
        }, '尚无有效历史样本；服务首次采样后即显示图表。');
    return E('div', {}, [E('div', {
        'style': 'text-align:right;margin-bottom:.25em;color:#777'
    }, '峰值：%s · %d 个速率点 · 可悬停查看详情'.format(speed(maxRate), samples.length)), trafficChart.line(samples, {
        formatValue: speed,
        height: 240
    })]);
}

function renderPie(items, emptyText) {
    return trafficChart.doughnut(items, {
        emptyText: emptyText || '这个时间段没有应用流量。',
        formatValue: bytes,
        centerLabel: '总计',
        height: 220
    });
}

function createAlwaysBlock(device, app) {
    if (!device.mac)
        return Promise.reject(new Error('此设备没有可用的 MAC 地址，不能创建稳定的设备规则。'));
    var sid = uci.add('c2000max_traffic', 'schedule');
    uci.set('c2000max_traffic', sid, 'name', '阻断 %s - %s'.format(device.name || device.mac, app.name));
    uci.set('c2000max_traffic', sid, 'enabled', '1');
    uci.set('c2000max_traffic', sid, 'target', 'selected');
    uci.set('c2000max_traffic', sid, 'devices', [device.mac]);
    uci.set('c2000max_traffic', sid, 'apps', [String(app.id)]);
    uci.set('c2000max_traffic', sid, 'match_mode', 'app');
    uci.set('c2000max_traffic', sid, 'ruleset', app.profile_id || currentProfileId);
    uci.set('c2000max_traffic', sid, 'time_windows', ['0@00:00-00:00', '1@00:00-00:00', '2@00:00-00:00', '3@00:00-00:00', '4@00:00-00:00', '5@00:00-00:00', '6@00:00-00:00']);
    return uci.save().then(function() {
        return ui.changes.apply(true);
    }).then(function() {
        return callPolicyReload();
    });
}

function confirmAlwaysBlock(device, app) {
    ui.showModal('创建应用阻断规则', [E('p', {}, safeText('将为 %s 创建一条全天阻断“%s”的规则。之后可在本页的“定时应用管控”中修改时间或删除。'.format(device.name || device.mac, app.name))), E('div', {
        'class': 'right'
    }, [E('button', {
        'class': 'btn',
        'click': ui.hideModal
    }, '取消'), ' ', E('button', {
        'class': 'btn cbi-button-negative important',
        'click': function() {
            return createAlwaysBlock(device, app).then(function() {
                ui.hideModal();
                location.reload();
            }).catch(function(error) {
                ui.addNotification(null, E('p', {}, safeText(error.message)));
            });
        }
    }, '创建并应用')])]);
}

function showDeviceAudit(device, seconds) {
    var now = Math.floor(Date.now() / 1000);
    var from = now - seconds;
    var requestSequence = ++auditModalSequence;
    destroyCharts(document.querySelector('#modal_overlay > .modal'));
    ui.showModal('应用流量审计 - %h'.format(device.name || device.ip || device.id), [E('p', {
        'class': 'spinning'
    }, '正在加载应用流量…')], 'c2000max-audit-modal');
    return L.resolveDefault(callTrafficAudit(device.id, from, now), {
        apps: [],
        categories: []
    }).then(function(data) {
        var activeModal = document.querySelector('#modal_overlay > .modal');
        if (requestSequence !== auditModalSequence || !activeModal || !activeModal.classList.contains('c2000max-audit-modal'))
            return;
        var apps = asArray(data.apps);
        var categoryRows = asArray(data.categories);
        var categories = categoryRows.slice(0, 8).map(function(category) {
            return {
                name: category.name,
                value: Number(category.total || 0)
            };
        });
        if (categoryRows.length > 8) {
            categories.push({
                name: '其他分类',
                value: categoryRows.slice(8).reduce(function(sum, category) {
                    return sum + Number(category.total || 0);
                }, 0)
            });
        }
        var fiveg = 0,
            other = 0,
            unknown = 0;
        apps.forEach(function(app) {
            fiveg += Number(app.fiveg_upload || 0) + Number(app.fiveg_download || 0);
            other += Number(app.other_upload || 0) + Number(app.other_download || 0);
            unknown += Number(app.unknown_upload || 0) + Number(app.unknown_download || 0);
        });

        function renderAuditPage(page, sortMode) {
            var pageSize = 20;
            var sorted = apps.slice();
            var descending = /_desc$/.test(sortMode);
            var sortField = /^time_/.test(sortMode) ? 'last_seen' : 'total';
            sorted.sort(function(a, b) {
                var av = Number(a[sortField] || 0);
                var bv = Number(b[sortField] || 0);
                if (av === bv)
                    return String(a.name || '').localeCompare(String(b.name || ''));
                return descending ? bv - av : av - bv;
            });
            var pageCount = Math.max(1, Math.ceil(sorted.length / pageSize));
            page = Math.max(1, Math.min(Number(page) || 1, pageCount));
            var rows = sorted.slice((page - 1) * pageSize, page * pageSize).map(function(app) {
                var lastSeen = Number(app.last_seen || 0);
                return E('div', {
                    'class': 'tr'
                }, [E('div', {
                    'class': 'td',
                    'style': 'min-width:150px;word-break:normal'
                }, [E('strong', {}, safeText(app.name)), E('div', {
                    'style': 'color:#777;font-size:90%'
                }, safeText(app.category || '未知'))]), E('div', {
                    'class': 'td'
                }, trafficPair(app.fiveg_upload, app.fiveg_download)), E('div', {
                    'class': 'td'
                }, trafficPair(app.other_upload, app.other_download)), E('div', {
                    'class': 'td'
                }, trafficPair(app.unknown_upload, app.unknown_download)), E('div', {
                    'class': 'td'
                }, bytes(app.total)), E('div', {
                    'class': 'td',
                    'style': 'white-space:nowrap'
                }, lastSeen ? new Date(lastSeen * 1000).toLocaleString() : '-'), E('div', {
                    'class': 'td'
                }, app.id > 0 && device.mac && (!app.profile_id || app.profile_id === currentProfileId) ? E('button', {
                    'class': 'btn cbi-button-negative',
                    'click': function() {
                        confirmAlwaysBlock(device, app);
                    }
                }, '阻断') : (app.id > 0 && app.profile_id ? '历史规则库' : '-'))]);
            });
            if (!rows.length)
                rows.push(E('div', {
                    'class': 'tr'
                }, E('div', {
                    'class': 'td'
                }, '所选时间段没有流量。')));
            var sortSelect = E('select', {
                'class': 'cbi-input-select',
                'change': function(ev) {
                    renderAuditPage(1, ev.target.value);
                }
            }, [
                ['traffic_desc', '流量：从大到小'],
                ['traffic_asc', '流量：从小到大'],
                ['time_desc', '时间：最近优先'],
                ['time_asc', '时间：最早优先']
            ].map(function(option) {
                return E('option', {
                    'value': option[0],
                    'selected': sortMode === option[0] ? '' : null
                }, option[1]);
            }));
            var pagination = E('div', {
                'style': 'display:flex;align-items:center;justify-content:flex-end;gap:.6em;margin-top:.75em'
            }, [E('button', {
                'class': 'btn',
                'disabled': page <= 1 ? '' : null,
                'click': function() {
                    renderAuditPage(page - 1, sortMode);
                }
            }, '上一页'), E('span', {}, '第 %d / %d 页，共 %d 个应用'.format(page, pageCount, sorted.length)), E('button', {
                'class': 'btn',
                'disabled': page >= pageCount ? '' : null,
                'click': function() {
                    renderAuditPage(page + 1, sortMode);
                }
            }, '下一页')]);
            destroyCharts(document.querySelector('#modal_overlay > .modal'));
            ui.showModal('应用流量审计 - %h'.format(device.name || device.ip || device.id), [E('div', {
                'style': 'max-height:calc(100vh - 190px);overflow-y:auto;overflow-x:hidden;padding-right:.5em'
            }, [E('div', {
                'style': 'display:flex;gap:.5em;flex-wrap:wrap;margin-bottom:1em'
            }, [
                [86400, '24 小时'],
                [604800, '7 天'],
                [2592000, '30 天']
            ].map(function(period) {
                return E('button', {
                    'class': 'btn %s'.format(seconds === period[0] ? 'cbi-button-action' : ''),
                    'click': function() {
                        return showDeviceAudit(device, period[0]);
                    }
                }, period[1]);
            })), E('div', {
                'class': 'c2000max-audit-pies'
            }, [E('div', {}, [E('h4', {}, '应用分类占比'), renderPie(categories, '这个时间段没有可展示的应用分类。')]), E('div', {}, [E('h4', {}, '出口流量类型'), renderPie([{
                name: '5G',
                value: fiveg
            }, {
                name: '其他/宽带',
                value: other
            }, {
                name: '未分类出口',
                value: unknown
            }], '这个时间段没有出口流量。')])]), E('div', {
                'style': 'display:flex;align-items:center;justify-content:space-between;gap:1em;flex-wrap:wrap;margin-top:1.25em'
            }, [E('h4', {
                'style': 'margin:0'
            }, '应用明细'), E('label', {}, ['排序：', sortSelect])]), E('div', {
                'style': 'overflow-x:auto;max-width:100%;margin-top:.5em'
            }, E('div', {
                'class': 'table cbi-section-table',
                'style': 'min-width:1080px'
            }, [E('div', {
                'class': 'tr table-titles'
            }, [E('div', {
                'class': 'th'
            }, '应用'), E('div', {
                'class': 'th'
            }, '5G（上传 / 下载）'), E('div', {
                'class': 'th'
            }, '其他（上传 / 下载）'), E('div', {
                'class': 'th'
            }, '未分类'), E('div', {
                'class': 'th'
            }, '总计'), E('div', {
                'class': 'th'
            }, '最后活动'), E('div', {
                'class': 'th'
            }, '操作')])].concat(rows))), pagination]), E('div', {
                'class': 'right'
            }, E('button', {
                'class': 'btn',
                'click': function() {
                    auditModalSequence++;
                    destroyCharts(document.querySelector('#modal_overlay > .modal'));
                    ui.hideModal();
                }
            }, '关闭'))], 'c2000max-audit-modal');
        }
        renderAuditPage(1, 'time_desc');
    });
}

function renderOverview(status) {
    var totals = status.totals || {};
    var updated = Number(status.updated || 0);
    var totalUpload = Number(totals.fiveg_upload || 0) + Number(totals.other_upload || 0) + Number(totals.unknown_upload || 0);
    var totalDownload = Number(totals.fiveg_download || 0) + Number(totals.other_download || 0) + Number(totals.unknown_download || 0);
    return [E('div', {
        'class': 'cbi-section'
    }, [E('h3', {}, '实时运行状态'), E('div', {
        'class': 'table'
    }, [E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, '统计服务'), E('div', {
        'class': 'td left'
    }, !status.statistics_enabled ? '已关闭' : (status.active ? '运行中' : '已启用，服务未运行')), E('div', {
        'class': 'td left'
    }, '加速模式'), E('div', {
        'class': 'td left'
    }, safeText(accelerationName(status.acceleration)))]), E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, '统计来源'), E('div', {
        'class': 'td left'
    }, status.statistics_enabled ? safeText(sourceName(status.counter_source)) : '未采集'), E('div', {
        'class': 'td left'
    }, '最后采样'), E('div', {
        'class': 'td left'
    }, updated ? '%s%s'.format(status.statistics_enabled ? '' : '历史：', new Date(updated * 1000).toLocaleString()) : (status.statistics_enabled ? '等待首次采样' : '无历史样本'))]), E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, '特征库'), E('div', {
        'class': 'td left'
    }, safeText('%s / %s 个应用 / %s 条内核特征'.format(ikDisplay(status.feature_version || '未知'), Number(status.feature_apps || 0), Number(status.audit_loaded_features || 0)))), E('div', {
        'class': 'td left'
    }, '加速暂缓'), E('div', {
        'class': 'td left'
    }, status.audit_holds_acceleration ? ('未知连接最多检查 %d 个有效载荷包'.format(Number(status.audit_packets || 0))) : '不暂缓')]), E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, '生效 APPID / DNS 域名'), E('div', {
        'class': 'td left'
    }, '%d / %d'.format(Number(status.policy_rules || 0), Number(status.policy_dns_domains || 0))), E('div', {
        'class': 'td left'
    }, '管控方式'), E('div', {
        'class': 'td left'
    }, controlModeName(status.effective_control_mode || status.control_mode))]), E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, 'HNAT 绕过范围'), E('div', {
        'class': 'td left'
    }, status.policy_hnat_scope === 'global' ? '全部 LAN（实验）' : (status.policy_hnat_scope === 'selected' ? '%d 个受控终端'.format(Math.max(0, Number(status.policy_bypass_clients || 0))) : '无')), E('div', {
        'class': 'td left'
    }, 'DNS 协同'), E('div', {
        'class': 'td left'
    }, Number(status.policy_dns_domains || 0) > 0 ? '已启用 IPv4 / IPv6 动态集合' : '当前规则没有可安全提取的域名')]), E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, '趋势样本'), E('div', {
        'class': 'td left'
    }, String(Number(status.history_samples || 0))), E('div', {
        'class': 'td left'
    }, '日志占用'), E('div', {
        'class': 'td left'
    }, '%s / %s'.format(bytes(status.storage_used), bytes(status.storage_limit)))]), E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, '应用审计'), E('div', {
        'class': 'td left'
    }, !status.audit_enabled ? '已关闭' : (status.audit_active ? '运行中' : '引擎未运行')), E('div', {
        'class': 'td left'
    }, '识别策略'), E('div', {
        'class': 'td left'
    }, auditModeName(status.audit_mode))])]), !status.statistics_enabled ? E('div', {
        'class': 'alert-message notice'
    }, '流量统计已关闭；下方累计值与趋势只是以前保留的历史数据，不会继续更新。') : '']), E('div', {
        'class': 'cbi-section'
    }, [E('h3', {}, '总流量趋势'), renderChart(status.history), E('p', {}, ['累计总量：', trafficPair(totalUpload, totalDownload)])]), E('div', {
        'class': 'cbi-section'
    }, [E('h3', {}, '分类累计流量'), E('div', {
        'class': 'table'
    }, [E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, E('strong', {}, '5G 流量')), E('div', {
        'class': 'td left'
    }, trafficPair(totals.fiveg_upload, totals.fiveg_download)), E('div', {
        'class': 'td left'
    }, E('strong', {}, '其他/宽带流量')), E('div', {
        'class': 'td left'
    }, trafficPair(totals.other_upload, totals.other_download))])]), E('div', {
        'class': 'right'
    }, [E('button', {
        'class': 'btn cbi-button-negative',
        'click': function() {
            ui.showModal('清空累计流量', [E('p', {}, '确定清空全部累计流量和趋势图吗？'), E('div', {
                'class': 'right'
            }, [E('button', {
                'class': 'btn',
                'click': ui.hideModal
            }, '取消'), ' ', E('button', {
                'class': 'btn cbi-button-negative important',
                'click': function() {
                    return callTrafficReset().then(ui.hideModal);
                }
            }, '确认清空')])]);
        }
    }, '清空统计')])])];
}

function deviceRows(status, auditOnly) {
    var devices = asArray(status.devices);
    var rows = devices.map(function(device) {
        var title = device.name || device.ip || device.mac || device.id || '未知设备';
        var detail = [];
        if (device.ip && device.ip !== title) detail.push(device.ip);
        if (device.mac && device.mac !== title) detail.push(device.mac);
        var cells = [E('div', {
            'class': 'td'
        }, [E('strong', {}, safeText(title)), detail.length ? E('div', {
            'style': 'color:#777;font-size:90%'
        }, safeText(detail.join(' · '))) : ''])];
        if (!auditOnly) {
            cells.push(E('div', {
                'class': 'td'
            }, trafficPair(device.fiveg_upload, device.fiveg_download)));
            cells.push(E('div', {
                'class': 'td'
            }, trafficPair(device.other_upload, device.other_download)));
            cells.push(E('div', {
                'class': 'td'
            }, trafficPair(device.unknown_upload, device.unknown_download)));
        }
        cells.push(E('div', {
            'class': 'td'
        }, E('button', {
            'class': 'btn cbi-button-action',
            'click': function() {
                return showDeviceAudit(device, 86400);
            }
        }, '查看应用')));
        return E('div', {
            'class': 'tr'
        }, cells);
    });
    if (!rows.length)
        rows.push(E('div', {
            'class': 'tr'
        }, E('div', {
            'class': 'td'
        }, '尚无设备流量。')));
    return rows;
}

function renderDevices(status) {
    return E('div', {
        'class': 'cbi-section'
    }, [E('h3', {}, '各设备流量'), E('div', {
        'class': 'table cbi-section-table'
    }, [E('div', {
        'class': 'tr table-titles'
    }, [E('div', {
        'class': 'th'
    }, '设备'), E('div', {
        'class': 'th'
    }, '5G（上传 / 下载）'), E('div', {
        'class': 'th'
    }, '其他/宽带（上传 / 下载）'), E('div', {
        'class': 'th'
    }, '未分类（上传 / 下载）'), E('div', {
        'class': 'th'
    }, '应用审计')])].concat(deviceRows(status, false)))]);
}

function renderAuditSummary(status) {
    if (!status.audit_enabled) {
        return [E('div', {
            'class': 'cbi-section'
        }, [E('h3', {}, '应用审计'), E('div', {
            'class': 'alert-message notice'
        }, '应用审计已关闭；以前保存的记录仍会保留，但关闭状态不会继续采集或展示设备应用流量。' + '若“流量统计”仍开启，基础流量计数会独立运行。')])];
    }
    return [E('div', {
        'class': 'cbi-section'
    }, [E('h3', {}, '应用识别状态'), E('div', {
        'class': 'table'
    }, [E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, '审计引擎'), E('div', {
        'class': 'td left'
    }, !status.audit_enabled ? '已关闭（流量记为未审计）' : (status.audit_active ? '运行中' : '已启用，引擎未运行')), E('div', {
        'class': 'td left'
    }, '识别策略'), E('div', {
        'class': 'td left'
    }, auditModeName(status.audit_mode))]), E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, '当前连接'), E('div', {
        'class': 'td left'
    }, '%d 已识别 / %d 未识别'.format(Number(status.audit_identified_connections || 0), Number(status.audit_unknown_connections || 0))), E('div', {
        'class': 'td left'
    }, '可见 secmark'), E('div', {
        'class': 'td left'
    }, String(Number(status.audit_secmark_connections || 0)))]), E('div', {
        'class': 'tr'
    }, [E('div', {
        'class': 'td left'
    }, '加载特征'), E('div', {
        'class': 'td left'
    }, String(Number(status.audit_loaded_features || 0))), E('div', {
        'class': 'td left'
    }, '加速暂缓'), E('div', {
        'class': 'td left'
    }, status.audit_holds_acceleration ? ('未知连接最多检查 %d 个有效载荷包'.format(Number(status.audit_packets || 0))) : '不暂缓')])])].concat(status.audit_error ? [E('div', {
        'class': 'alert-message warning'
    }, safeText('应用审计错误：%s'.format(status.audit_error)))] : [])), E('div', {
        'class': 'cbi-section'
    }, [E('h3', {}, '按设备查看应用'), E('p', {}, '点击设备后可切换 24 小时、7 天或 30 天，并对应用明细分页、排序。'), E('div', {
        'class': 'table cbi-section-table'
    }, [E('div', {
        'class': 'tr table-titles'
    }, [E('div', {
        'class': 'th'
    }, '设备'), E('div', {
        'class': 'th'
    }, '操作')])].concat(deviceRows(status, true)))])];
}

function renderRealtimeAudit(initialData, auditEnabled) {
    if (!auditEnabled)
        return E('div', {
            'class': 'cbi-section'
        }, E('div', {
            'class': 'alert-message notice'
        }, '应用审计已关闭，不读取历史或实时应用记录。'));
    var page = 0;
    var pageSize = 50;
    var sequence = 0;
    var timer = null;
    var loading = false;
    var loaded = false;
    var body = E('div', {}, E('div', {
        'class': 'alert-message notice'
    }, '切换到“实时应用”标签后再读取最近记录，不占用首屏加载时间。'));
    var pageStatus = E('span');
    var updateStatus = E('span', {
        'style': 'color:#777'
    });
    var previous = E('button', {
        'class': 'btn',
        'type': 'button',
        'disabled': ''
    }, '上一页');
    var next = E('button', {
        'class': 'btn',
        'type': 'button',
        'disabled': ''
    }, '下一页');
    var interval = E('select', {
        'class': 'cbi-input-select',
        'disabled': ''
    }, [E('option', {
        'value': '3'
    }, '每 3 秒'), E('option', {
        'value': '5',
        'selected': ''
    }, '每 5 秒'), E('option', {
        'value': '10'
    }, '每 10 秒'), E('option', {
        'value': '30'
    }, '每 30 秒')]);
    var live = E('input', {
        'type': 'checkbox'
    });
    var refresh = E('button', {
        'class': 'btn cbi-button-action',
        'type': 'button'
    }, '立即刷新');

    function renderResult(result, requestPage) {
        var items = asArray(result.items).slice().sort(function(a, b) {
            var time = (Number(b.timestamp_ms || 0) || Number(b.timestamp || b.last_seen || 0) * 1000) -
                (Number(a.timestamp_ms || 0) || Number(a.timestamp || a.last_seen || 0) * 1000);
            if (time)
                return time;
            return String(a.device_id || a.device || '').localeCompare(String(b.device_id || b.device || ''));
        });
        var total = Math.min(150, Math.max(0, Number(result.total || 0)));
        var pageCount = Math.max(1, Math.ceil(total / pageSize));
        var rows;
        page = Math.max(0, Math.min(requestPage, pageCount - 1));
        rows = items.map(function(item) {
            var timestamp = Number(item.timestamp || item.last_seen || 0);
            var device = item.device_name || item.device || item.device_ip || item.device_id || '未知设备';
            var detail = [];
            if (item.device_ip && item.device_ip !== device) detail.push(item.device_ip);
            if (item.device_id && item.device_id !== device && item.device_id !== item.device_ip) detail.push(item.device_id);
            return E('div', {
                'class': 'tr'
            }, [E('div', {
                'class': 'td'
            }, [E('strong', {}, safeText(item.name || '应用 #%s'.format(Number(item.id || 0)))), E('div', {
                'style': 'color:#777;font-size:90%'
            }, safeText('%s · APPID %s'.format(item.category || '未分类', Number(item.id || 0))))]), E('div', {
                'class': 'td',
                'style': 'white-space:nowrap'
            }, timestamp ? new Date(timestamp * 1000).toLocaleString() : '未知时间'), E('div', {
                'class': 'td'
            }, [E('strong', {}, safeText(device)), detail.length ? E('div', {
                'style': 'color:#777;font-size:90%'
            }, safeText(detail.join(' · '))) : ''])]);
        });
        if (!rows.length)
            rows.push(E('div', {
                'class': 'tr'
            }, E('div', {
                'class': 'td'
            }, '尚无已识别的应用记录；未知连接不会出现在这里。')));
        L.dom.content(body, E('div', {
            'style': 'overflow-x:auto;max-width:100%'
        }, E('div', {
            'class': 'table cbi-section-table',
            'style': 'min-width:720px'
        }, [E('div', {
            'class': 'tr table-titles'
        }, [E('div', {
            'class': 'th'
        }, '应用'), E('div', {
            'class': 'th',
            'style': 'width:15em'
        }, '时间'), E('div', {
            'class': 'th'
        }, '设备')])].concat(rows))));
        previous.disabled = page <= 0;
        next.disabled = !result.has_more || page >= pageCount - 1;
        L.dom.content(pageStatus, '第 %d / %d 页，共保留最近 %d 条'.format(page + 1, pageCount, total));
        var updated = Number(result.updated || 0);
        L.dom.content(updateStatus, updated ? '最新记录：%s'.format(new Date(updated * 1000).toLocaleString()) : '等待审计记录');
    }

    function loadPage(wantedPage) {
        if (loading)
            return Promise.resolve();
        loaded = true;
        loading = true;
        var requestSequence = ++sequence;
        previous.disabled = true;
        next.disabled = true;
        refresh.disabled = true;
        return callRecentAudit(Math.max(0, wantedPage) * pageSize, pageSize).then(function(result) {
            if (requestSequence !== sequence)
                return;
            if (result.success !== true)
                throw new Error(result.message || result.error || '读取最近应用失败');
            result.items = (result.items || []).slice().sort(function(a, b) {
                return Number(b.timestamp || 0) - Number(a.timestamp || 0);
            });
            renderResult(result, wantedPage);
        }).catch(function(error) {
            if (requestSequence === sequence)
                L.dom.content(body, E('div', {
                    'class': 'alert-message warning'
                }, safeText('读取最近应用失败：' + (error.message || String(error)))));
        }).finally(function() {
            if (requestSequence === sequence) {
                refresh.disabled = false;
                loading = false;
                if (live.checked)
                    scheduleTimer();
            }
        });
    }

    function stopTimer() {
        if (timer !== null) {
            clearInterval(timer);
            timer = null;
        }
    }

    function realtimeTabActive() {
        var pane = panel.closest('[data-tab]');
        return !pane || pane.getAttribute('data-tab-active') === 'true';
    }

    function scheduleTimer() {
        stopTimer();
        if (!live.checked)
            return;
        timer = setTimeout(function() {
            timer = null;
            if (!document.body.contains(panel)) {
                stopTimer();
                return;
            }
            if (realtimeTabActive())
                loadPage(page);
            else
                scheduleTimer();
        }, Number(interval.value || 5) * 1000);
    }
    previous.addEventListener('click', function(ev) {
        ev.preventDefault();
        loadPage(page - 1);
    });
    next.addEventListener('click', function(ev) {
        ev.preventDefault();
        loadPage(page + 1);
    });
    refresh.addEventListener('click', function(ev) {
        ev.preventDefault();
        loadPage(page);
    });
    live.addEventListener('change', function() {
        interval.disabled = !live.checked;
        if (live.checked) {
            page = 0;
            loadPage(0);
        } else {
            stopTimer();
        }
    });
    interval.addEventListener('change', scheduleTimer);
    var panel = E('div', {
        'class': 'cbi-section'
    }, [E('div', {
        'style': 'display:flex;align-items:center;justify-content:space-between;gap:1em;flex-wrap:wrap'
    }, [E('div', {}, [E('h3', {
        'style': 'margin-bottom:.25em'
    }, '最近识别的应用'), E('div', {}, '按时间从新到旧显示最近 150 条；未知连接已过滤。')]), E('div', {
        'style': 'display:flex;align-items:center;gap:.6em;flex-wrap:wrap'
    }, [E('label', {
        'style': 'display:flex;align-items:center;gap:.35em'
    }, [live, '实时刷新']), interval, refresh])]), E('div', {
        'style': 'margin:.6em 0'
    }, updateStatus), body, E('div', {
        'style': 'display:flex;justify-content:flex-end;align-items:center;gap:.6em;margin-top:.75em;flex-wrap:wrap'
    }, [previous, pageStatus, next])]);
    if (initialData && initialData.success === true) {
        loaded = true;
        renderResult(initialData, 0);
    }
    setTimeout(function() {
        var pane = panel.closest('[data-tab]');
        if (pane)
            pane.addEventListener('cbi-tab-active', function() {
                if (!loaded) {
                    page = 0;
                    loadPage(0);
                } else if (live.checked) {
                    page = 0;
                    loadPage(0);
                }
            });
    }, 0);
    return panel;
}
return view.extend({
    handleSave: function(ev) {
        var activeManagement = document.querySelector('#c2000-traffic-tabs > [data-tab-active="true"][data-tab="traffic-rules"], ' + '#c2000-traffic-tabs > [data-tab-active="true"][data-tab="traffic-settings"]');
        var ready = activeManagement && this._managementRenderPromise ? this._managementRenderPromise : Promise.resolve();
        return ready.then(function() {
            var maps = (this._managementMaps || []).filter(function(map) {
                return map.root && document.body.contains(map.root);
            });
            if (activeManagement && !maps.length)
                throw new Error('管控规则表单尚未载入，请稍后重试。');
            return maps.reduce(function(task, map) {
                return task.then(function() {
                    return map.save();
                });
            }, Promise.resolve());
        }.bind(this));
    },
    load: function() {
        var statusRequest = L.resolveDefault(callTrafficStatus(), {});
        return uci.load('c2000max_traffic').then(function() {
            var active = String(uci.get('c2000max_traffic', 'audit', 'ruleset') || '');
            var featureJobRequest = L.resolveDefault(callFeatureInstallStatus(''), {
                state: 'idle',
                _loadFailed: true
            });
            var featureRequest = L.resolveDefault(callFeatureList(), {
                profiles: [],
                _loadFailed: true
            });
            var catalogRequest = L.resolveDefault(callCatalogInfo(''), {
                profile: active,
                categories: [],
                total_apps: 0,
                _loadFailed: true
            });
            var lookupRequest = catalogRequest.then(function(info) {
                if (!info || info._loadFailed || info.success === false)
                    return {
                        profile: active,
                        items: [],
                        _loadFailed: true
                    };
                var lookupProfile = String(info.profile || info.profile_id || '');
                var wanted = {};
                if (!lookupProfile)
                    return {
                        profile: active,
                        items: [],
                        _loadFailed: true
                    };
                uci.sections('c2000max_traffic', 'schedule', function(section) {
                    var ruleset = String(section.ruleset || active);
                    if (ruleset !== lookupProfile)
                        return;
                    L.toArray(section.apps).forEach(function(id) {
                        if (/^[0-9]+$/.test(String(id))) wanted[String(id)] = true;
                    });
                });
                return L.resolveDefault(callCatalogLookup(lookupProfile, Object.keys(wanted).join(',')), {
                    profile: lookupProfile,
                    items: [],
                    _loadFailed: true
                });
            });
            var deferredFeature = {
                profiles: [],
                _deferred: true
            };
            var deferredCatalog = {
                profile: active,
                categories: [],
                total_apps: 0,
                _deferred: true
            };
            var deferredLookup = {
                profile: active,
                items: [],
                _deferred: true
            };
            var deferredStatus = {
                _deferred: true
            };
            return Promise.all([resolveWithin(statusRequest, deferredStatus, 1800), resolveWithin(featureRequest, deferredFeature, 1800), resolveWithin(catalogRequest, deferredCatalog, 1800), resolveWithin(lookupRequest, deferredLookup, 1800), resolveWithin(featureJobRequest, {
                state: 'idle',
                _deferred: true
            }, 800)]).then(function(base) {
                var statusDeferred = base[0] === deferredStatus;
                var status = statusDeferred ? {} : (base[0] || {});
                var features = base[1] || {};
                active = String(status.feature_profile || features.active || features.active_id || active);
                currentProfileId = active;
                return {
                    status: status,
                    features: features,
                    catalog: base[2] || {},
                    lookup: base[3] || {},
                    featureJob: base[4] || {
                        state: 'idle'
                    },
                    featureJobRequest: featureJobRequest,
                    recentAudit: null,
                    statusRequest: statusRequest,
                    managementDeferred: !!(statusDeferred || base[1]._deferred || base[2]._deferred || base[3]._deferred),
                    managementRequest: Promise.all([featureRequest, catalogRequest, lookupRequest])
                };
            });
        });
    },
    render: function(data) {
        var statisticsConfigured = uci.get('c2000max_traffic', 'config', 'enabled') === '1';
        var auditConfigured = uci.get('c2000max_traffic', 'audit', 'enabled') === '1';
        var status = Object.assign({
            statistics_enabled: statisticsConfigured,
            audit_enabled: auditConfigured
        }, data.status || {});
        var featureData = data.features || {};
        var catalog = data.catalog || {};
        var lookup = data.lookup || {};
        var recentAudit = data.recentAudit || {};
        var initialFeatureJob = data.featureJob || {
            state: 'idle'
        };
        var devices = asArray(status.devices);
        var categories = asArray(catalog.categories);
        var selectedLabels = {};
        asArray(lookup.items || lookup.apps).forEach(function(app) {
            selectedLabels[String(app.id)] = appChoiceLabel(app);
        });
        var catalogProfile = catalog._deferred || catalog._loadFailed ? '' : String(catalog.profile || catalog.profile_id || '');
        currentProfileId = String(catalogProfile || featureData.active || featureData.active_id || status.feature_profile || currentProfileId);
        var inactiveSchedules = 0;
        uci.sections('c2000max_traffic', 'schedule', function(section) {
            var ruleset = String(section.ruleset || currentProfileId);
            if (ruleset !== currentProfileId) inactiveSchedules++;
        });
        var settingsMap = new form.Map('c2000max_traffic', null, null);
        var rulesMap = new form.Map('c2000max_traffic', null, null);
        this._managementMaps = [rulesMap, settingsMap];
        var s = settingsMap.section(form.NamedSection, 'config', 'traffic', '统计与存储');
        s.anonymous = true;
        var o = s.option(form.Flag, 'enabled', '启用流量统计');
        o.default = o.disabled;
        o.rmempty = false;
        o = s.option(form.Value, 'sample_interval', '采样间隔（秒）');
        o.datatype = 'and(uinteger,min(5),max(300))';
        o.default = '10';
        o.rmempty = false;
        o = s.option(form.Value, 'flush_interval', '持久化间隔（秒）', '写入闪存的间隔，建议不小于 3600 秒。');
        o.datatype = 'and(uinteger,min(300),max(86400))';
        o.default = '3600';
        o.rmempty = false;
        o = s.option(form.Value, 'storage_limit_mb', '日志数据上限（MB）', '默认最多保留 100 MB 的趋势和应用明细；超过后自动删除最早记录。');
        o.datatype = 'and(uinteger,min(1),max(2048))';
        o.default = '100';
        o.rmempty = false;
        s = settingsMap.section(form.NamedSection, 'audit', 'audit', '审计与规则库', '默认关闭。无感模式不会为了识别阻止 HNAT/PPE 或软件 Flow Offload，未识别连接直接记为“未知/其他”；均衡和精确模式会暂缓未知连接加速以提高识别率。');
        s.anonymous = true;
        o = s.option(form.Flag, 'enabled', '启用应用审计');
        o.default = o.disabled;
        o.rmempty = false;
        o = s.option(form.ListValue, 'recognition_mode', '识别策略');
        o.value('seamless', '无感（立即加速，识别率较低）');
        o.value('balanced', '均衡（推荐；最多检查 8 个有效载荷包后恢复硬件加速）');
        o.value('precise', '精确（未知连接最多检查 64 个有效载荷包）');
        o.default = 'seamless';
        o.rmempty = false;
        o.description = '均衡模式只暂缓尚未识别的新连接，最多检查 8 个有效载荷包后即恢复 HNAT/PPE；不会全局关闭硬件加速。无感模式可能在首个应用载荷到达前就被硬件接管，从而漏识别。';
        o = s.option(form.ListValue, 'control_mode', '管控生效方式');
        o.value('seamless', '无感管控（最少影响加速）');
        o.value('force', '强力管控（定向重检现有连接）');
        o.value('strict', '选择性严格（推荐用于实际拦截）');
        o.value('deep', '全局深度实验（排障；全部 LAN 走 CPU）');
        o.default = 'seamless';
        o.rmempty = false;
        o.description = '所有模式都会使用 DNS A/AAAA 动态集合辅助 APPID。选择性严格只在受控终端的新连接尚未识别时暂缓加速，并让 UDP/443 回退到可识别的 TCP/TLS：允许流分类后立即恢复 HNAT/PPE，只有命中封禁的流保持 NO_OFFLOAD 并被拒绝；全局深度实验才会让全部 LAN 流量走 CPU。';
        o = s.option(form.Value, 'retention_days', '明细保留天数');
        o.datatype = 'and(uinteger,min(1),max(90))';
        o.default = '30';
        o.rmempty = false;
        o = s.option(form.DummyValue, '_feature_profiles', '已上传的规则库', '同一时刻只激活一个经过校验的 OAF v3/v4 Profile；不同库的 APPID、历史和管控规则互相隔离。');
        o.rawhtml = true;
        o.cfgvalue = function() {
            return renderFeatureManager(featureData, catalog);
        };
        o = s.option(form.Button, '_upload_feature', '上传新规则库');
        o.inputstyle = 'action';
        o.inputtitle = '选择文件并更新';
        o.onclick = function(ev) {
            var progress = null;
            var uploadCompleted = false;
            var releaseOnError = false;
            var startResponseReceived = false;
            if (rejectConcurrentFeatureJob())
                return Promise.resolve();
            featureInstallInProgress = true;
            updateFeatureJobBanner({
                state: 'upload',
                phase: 'upload',
                message: '正在把特征库上传到路由器；上传完成后会自动转入后台校验和编译。'
            });
            return ui.uploadFile('/tmp/c2000max-feature-upload', ev.target).then(function() {
                uploadCompleted = true;
                return callFeatureInstall();
            }).then(function(result) {
                startResponseReceived = true;
                var state = String((result || {}).state || '');
                var asyncAccepted = result && result.accepted !== false && (state === 'queued' || state === 'running');
                releaseOnError = featureJobStartCanRelease(result);
                if (asyncAccepted) {
                    progress = E('p', {}, safeText(result.message || '上传完成，正在后台安装特征库…'));
                    ui.addNotification(null, progress);
                }
                return resolveFeatureJobStart(result, progress, '特征库安装失败');
            }).then(function(result) {
                featureInstallInProgress = false;
                ui.addNotification(null, E('p', {}, safeText('特征库已更新到 %s，共 %d 个应用。'.format(ikDisplay(result.version), Number(result.apps || 0)))));
                location.reload();
            }).catch(function(error) {
                if (!uploadCompleted || releaseOnError)
                    featureInstallInProgress = false;
                if (!uploadCompleted || releaseOnError)
                    updateFeatureJobBanner({
                        state: 'failed',
                        phase: 'failed',
                        message: error.message
                    });
                ui.addNotification(null, E('p', {}, safeText(uploadCompleted && !startResponseReceived ? '无法确认安装任务是否已提交；请稍后重新进入页面查看状态。' : error.message)));
            });
        };
        s = rulesMap.section(RuleGridSection, 'schedule', '管控规则', '多条规则可重叠，任一命中即阻断。每条规则可以设置多个不同星期、不同时间段；当前仅显示活动库的规则%s。'.format(inactiveSchedules ? '，另有 %d 条其他库规则已隐藏且不生效'.format(inactiveSchedules) : ''));
        s.anonymous = true;
        s.addremove = true;
        s.sortable = true;
        s.nodescriptions = true;
        s.filter = function(sectionId) {
            return String(uci.get('c2000max_traffic', sectionId, 'ruleset') || currentProfileId) === currentProfileId;
        };
        o = s.option(form.Flag, 'enabled', '启用');
        o.default = o.enabled;
        o.rmempty = false;
        o.editable = true;
        o.width = '10%';
        o = s.option(form.Value, 'name', '规则名称');
        o.default = '新管控规则';
        o.placeholder = '例如：上课时间禁用游戏';
        o.rmempty = false;
        var rulesetOption = o = s.option(form.Value, 'ruleset', '所属规则库');
        o.default = currentProfileId;
        o.rmempty = false;
        o.readonly = true;
        o.modalonly = true;
        o = s.option(TimeWindowSelector, 'time_windows', '生效时段');
        o.default = ['0@00:00-00:00', '1@00:00-00:00', '2@00:00-00:00', '3@00:00-00:00', '4@00:00-00:00', '5@00:00-00:00', '6@00:00-00:00'];
        o.rmempty = false;
        o.modalonly = true;
        o = s.option(form.ListValue, 'target', '作用设备');
        o.value('all', '全部设备（可设白名单）');
        o.value('selected', '仅指定设备');
        o.default = 'all';
        o.rmempty = false;
        o.modalonly = true;
        var deviceOption = o = s.option(form.DynamicList, 'devices', '指定设备');
        o.depends('target', 'selected');
        o.modalonly = true;
        devices.forEach(function(device) {
            if (device.mac) o.value(device.mac, safeChoice('%s（%s）'.format(device.name || device.ip || device.mac, device.mac)));
        });
        var whitelistOption = o = s.option(form.DynamicList, 'whitelist', '设备白名单');
        o.depends('target', 'all');
        o.modalonly = true;
        devices.forEach(function(device) {
            if (device.mac) o.value(device.mac, safeChoice('%s（%s）'.format(device.name || device.ip || device.mac, device.mac)));
        });
        var matchModeOption = o = s.option(form.ListValue, 'match_mode', '应用管控方式', '选择一种管控依据后，只显示并保存对应的选择菜单。');
        o.value('category', '按照应用分类管控');
        o.value('app', '按照指定应用管控');
        o.default = 'category';
        o.rmempty = false;
        o.modalonly = true;
        o.cfgvalue = function(sectionId) {
            var configured = uci.get('c2000max_traffic', sectionId, 'match_mode');
            if (configured === 'category' || configured === 'app')
                return configured;
            return L.toArray(uci.get('c2000max_traffic', sectionId, 'apps')).length &&
                !L.toArray(uci.get('c2000max_traffic', sectionId, 'categories')).length ? 'app' : 'category';
        };
        o.write = function(sectionId, value) {
            uci.set('c2000max_traffic', sectionId, 'match_mode', value);
            uci.unset('c2000max_traffic', sectionId, value === 'category' ? 'apps' : 'categories');
        };
        var categoryOption = o = s.option(form.MultiValue, 'categories', '应用分类', '勾选后阻断该分类下的全部应用；分类来自当前特征库。');
        o.depends('match_mode', 'category');
        o.rmempty = false;
        o.modalonly = true;
        categories.forEach(function(category) {
            o.value(String(category.id), safeChoice(category.name));
        });
        var appOption = o = s.option(LazyAppSelector, 'apps', '指定应用', '打开搜索器后才按 50 条/页查询，不会一次加载整个软件库。');
        o.depends('match_mode', 'app');
        o.modalonly = true;
        o.rmempty = false;
        o.profile = currentProfileId;
        o.categories = categories;
        o.labelCache = selectedLabels;
        var modalStyle = E('style', {}, ['.modal.c2000max-audit-modal{width:calc(100vw - 3rem);max-width:1280px!important;}', '.modal.c2000max-app-picker-modal{width:calc(100vw - 3rem);max-width:1050px!important;}', '.c2000max-audit-pies{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.25em;align-items:start;}', '.c2000max-tabs-wrap>.cbi-tabmenu{overflow-x:auto;white-space:nowrap;flex-wrap:nowrap;}', '.c2000max-app-selector{width:32rem;max-width:100%;min-width:0;}', '.c2000max-app-selector>.cbi-dropdown{display:block;width:100%!important;max-width:100%!important;min-width:0!important;box-sizing:border-box;}', '.c2000max-app-selector>.cbi-dropdown>ul{width:100%!important;max-width:100%!important;min-width:0!important;box-sizing:border-box;overflow-x:hidden;}', '.c2000max-app-selector>.cbi-dropdown>ul.dropdown{left:0!important;right:auto!important;width:100%!important;min-width:100%!important;max-width:100%!important;}', '.c2000max-app-selector>.cbi-dropdown>ul>li{min-width:0!important;max-width:100%!important;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}', '@media(max-width:760px){.modal.c2000max-audit-modal,.modal.c2000max-app-picker-modal{width:calc(100vw - 1rem);margin:1em auto;}.c2000max-audit-pies{grid-template-columns:1fr;}}'].join(''));
        var latestStatus = status;
        var statusPollRequest = data.statusRequest || null;
        var profileConsistencyRequest = null;
        var pendingProfileId = '';
        if (statusPollRequest) {
            Promise.resolve(statusPollRequest).finally(function() {
                if (statusPollRequest === data.statusRequest)
                    statusPollRequest = null;
            });
        }

        function statusHasData(nextStatus) {
            return nextStatus && typeof nextStatus === 'object' && Object.keys(nextStatus).length > 0;
        }

        function tabIsActive(name) {
            var pane = document.querySelector('#c2000-traffic-tabs > [data-tab="%s"]'.format(name));
            return pane && pane.getAttribute('data-tab-active') === 'true';
        }

        function verifyProfileGeneration() {
            if (featureInstallInProgress || profileConsistencyRequest || !pendingProfileId)
                return;
            var wantedProfile = pendingProfileId;
            var request = L.resolveDefault(callCatalogInfo(''), {});
            profileConsistencyRequest = request;
            request.then(function(info) {
                var resolvedProfile = String((info || {}).profile || (info || {}).profile_id || '');
                if (!featureInstallInProgress && pendingProfileId === wantedProfile && resolvedProfile === wantedProfile && wantedProfile !== currentProfileId && document.body.contains(page))
                    location.reload();
            }).finally(function() {
                if (profileConsistencyRequest === request)
                    profileConsistencyRequest = null;
                if (!featureInstallInProgress && pendingProfileId && pendingProfileId !== wantedProfile)
                    verifyProfileGeneration();
            });
        }

        function updateStatusPanels(nextStatus, forcedTab) {
            if (!statusHasData(nextStatus))
                return;
            if (nextStatus.feature_profile && currentProfileId && nextStatus.feature_profile !== currentProfileId) {
                pendingProfileId = String(nextStatus.feature_profile);
                verifyProfileGeneration();
                return;
            }
            pendingProfileId = '';
            latestStatus = nextStatus;
            if (forcedTab === 'traffic-overview' || (!forcedTab && tabIsActive('traffic-overview'))) {
                var overview = document.getElementById('c2000-traffic-overview-body');
                if (overview) {
                    destroyCharts(overview);
                    L.dom.content(overview, renderOverview(nextStatus));
                }
            }
            if (forcedTab === 'traffic-audit' || (!forcedTab && tabIsActive('traffic-audit'))) {
                var auditBody = document.getElementById('c2000-traffic-audit-body');
                if (auditBody)
                    L.dom.content(auditBody, renderAuditSummary(nextStatus));
            }
        }
        poll.add(function() {
            if (statusPollRequest)
                return Promise.resolve();
            var request = L.resolveDefault(callTrafficStatus(), {});
            statusPollRequest = request;
            request.then(function(nextStatus) {
                updateStatusPanels(nextStatus);
            }).finally(function() {
                if (statusPollRequest === request)
                    statusPollRequest = null;
            });
            return resolveWithin(request, null, 3000);
        }, 5);

        function setAllRules(enabled) {
            var changed = 0;
            uci.sections('c2000max_traffic', 'schedule', function(section) {
                if (String(section.ruleset || currentProfileId) !== currentProfileId)
                    return;
                uci.set('c2000max_traffic', section['.name'], 'enabled', enabled ? '1' : '0');
                changed++;
            });
            if (!changed) {
                ui.addNotification(null, E('p', {}, '当前规则库没有可批量操作的规则。'));
                return Promise.resolve();
            }
            return uci.save().then(function() {
                return ui.changes.apply(true);
            }).then(function() {
                return callPolicyReload();
            }).then(function() {
                location.reload();
            });
        }
        var rulesBody = E('div', {}, E('p', {
            'class': 'spinning'
        }, '正在后台载入管控规则…'));
        var settingsBody = E('div', {}, E('p', {
            'class': 'spinning'
        }, '正在后台载入设置…'));
        var batchToolbar = E('div', {
            'style': 'display:flex;gap:.6em;flex-wrap:wrap;margin:0 0 1em'
        }, [E('button', {
            'class': 'btn cbi-button-positive',
            'type': 'button',
            'click': function(ev) {
                ev.preventDefault();
                return setAllRules(true);
            }
        }, '启用当前库全部规则'), E('button', {
            'class': 'btn cbi-button-negative',
            'type': 'button',
            'click': function(ev) {
                ev.preventDefault();
                return setAllRules(false);
            }
        }, '停用当前库全部规则')]);
        var tabGroup = E('div', {
            'id': 'c2000-traffic-tabs'
        }, [E('div', {
            'data-tab': 'traffic-overview',
            'data-tab-title': '概览',
            'data-tab-active': 'true'
        }, E('div', {
            'id': 'c2000-traffic-overview-body'
        }, renderOverview(status))), E('div', {
            'data-tab': 'traffic-audit',
            'data-tab-title': '应用审计'
        }, E('div', {
            'id': 'c2000-traffic-audit-body'
        }, renderAuditSummary(status))), E('div', {
            'data-tab': 'traffic-realtime',
            'data-tab-title': '实时应用'
        }, renderRealtimeAudit(recentAudit, auditConfigured)), E('div', {
            'data-tab': 'traffic-rules',
            'data-tab-title': '管控规则'
        }, [batchToolbar, rulesBody]), E('div', {
            'data-tab': 'traffic-settings',
            'data-tab-title': '设置'
        }, settingsBody)]);
        var jobBanner = E('div', {
            'id': 'c2000max-feature-job-banner',
            'style': 'display:none;margin:0 0 1em'
        });
        var page = E('div', {
            'class': 'c2000max-tabs-wrap'
        }, [modalStyle, E('h2', {}, 'C2000MAX 流量统计'), jobBanner, tabGroup]);
        featureJobBannerNode = jobBanner;
        updateFeatureJobBanner(initialFeatureJob);

        function recoverFeatureJob(status) {
            var state = String((status || {}).state || 'idle');
            updateFeatureJobBanner(status);
            if ((state === 'done' || state === 'failed' || state === 'missing') && (status || {}).job_id) {
                acknowledgeFeatureJob(status.job_id);
                return;
            }
            if ((state !== 'queued' && state !== 'running') || featureJobRecoveryStarted || !(status || {}).job_id)
                return;
            featureJobRecoveryStarted = true;
            featureInstallInProgress = true;
            waitFeatureInstall(status.job_id, null, 0).then(function(result) {
                updateFeatureJobBanner({
                    state: 'done',
                    phase: 'done',
                    message: '特征库后台处理完成，正在载入新的规则库和分类…'
                });
                window.setTimeout(function() {
                    location.reload();
                }, 800);
            }).catch(function(error) {
                featureInstallInProgress = false;
                updateFeatureJobBanner({
                    state: 'failed',
                    phase: 'failed',
                    message: error.message
                });
            });
        }
        recoverFeatureJob(initialFeatureJob);
        Promise.resolve(data.featureJobRequest).then(recoverFeatureJob);
        ui.tabs.initTabGroup(tabGroup.children);
        var managementOpened = false;
        Array.prototype.forEach.call(tabGroup.children, function(pane) {
            pane.addEventListener('cbi-tab-active', function() {
                var tabName = pane.getAttribute('data-tab');
                updateStatusPanels(latestStatus, tabName);
                if (tabName === 'traffic-rules' || tabName === 'traffic-settings') {
                    managementOpened = true;
                    maybeRenderManagementForm();
                }
            });
        });
        var managementReady = !data.managementDeferred;
        var managementRenderStarted = false;
        var managementRenderResolve;
        this._managementRenderPromise = new Promise(function(resolve) {
            managementRenderResolve = resolve;
        });
        var managementPane = tabGroup.querySelector('[data-tab="traffic-rules"][data-tab-active="true"], [data-tab="traffic-settings"][data-tab-active="true"]');
        if (managementPane)
            managementOpened = true;

        function renderManagementForm() {
            Promise.all([rulesMap.render(), settingsMap.render()]).then(function(forms) {
                if (document.body.contains(rulesBody))
                    L.dom.content(rulesBody, forms[0]);
                if (document.body.contains(settingsBody))
                    L.dom.content(settingsBody, forms[1]);
                managementRenderResolve(forms);
            }).catch(function(error) {
                managementRenderResolve([]);
                var warning = E('div', {
                    'class': 'alert-message warning'
                }, safeText('管控规则或设置载入失败：%s'.format(error.message || error)));
                if (document.body.contains(rulesBody)) L.dom.content(rulesBody, warning);
                if (document.body.contains(settingsBody)) L.dom.content(settingsBody, E('div', {
                    'class': 'alert-message warning'
                }, safeText(error.message || error)));
            });
        }

        function maybeRenderManagementForm() {
            if (!managementOpened || !managementReady || managementRenderStarted)
                return;
            managementRenderStarted = true;
            setTimeout(renderManagementForm, 0);
        }
        if (!data.managementDeferred) {
            L.dom.content(rulesBody, E('div', {
                'class': 'alert-message notice'
            }, '切换到“管控规则”或“设置”后再渲染表单，不占用流量概览首屏时间。'));
            L.dom.content(settingsBody, E('div', {
                'class': 'alert-message notice'
            }, '切换到本标签后载入设置。'));
            maybeRenderManagementForm();
        } else {
            var deferredNotice = E('div', {
                'class': 'alert-message notice'
            }, [E('p', {
                'class': 'spinning'
            }, '规则库元数据仍在后台载入；统计视图可以正常使用。'), E('p', {}, '载入完成后本页会自动更新一次，无需手动刷新。')]);
            L.dom.content(rulesBody, deferredNotice);
            L.dom.content(settingsBody, E('div', {
                'class': 'alert-message notice'
            }, '设置元数据正在载入…'));
            Promise.all([resolveWithin(data.statusRequest, status, 5000), Promise.resolve(data.managementRequest)]).then(function(deferred) {
                var nextStatus = deferred[0] || status;
                var result = deferred[1];
                var failed = !result || result.some(function(item) {
                    return !item || item._loadFailed || item.success === false;
                });
                if (failed) {
                    managementRenderResolve([]);
                    L.dom.content(rulesBody, E('div', {
                        'class': 'alert-message warning'
                    }, '规则库元数据读取失败；统计页面不受影响，请稍后重新进入“管控规则”。'));
                    return;
                }
                status = nextStatus;
                featureData = result[0] || {};
                catalog = result[1] || {};
                lookup = result[2] || {};
                currentProfileId = String(catalog.profile || catalog.profile_id || featureData.active || featureData.active_id || currentProfileId);
                rulesetOption.default = currentProfileId;
                devices = asArray(status.devices);
                categories = asArray(catalog.categories);
                selectedLabels = {};
                asArray(lookup.items || lookup.apps).forEach(function(app) {
                    selectedLabels[String(app.id)] = appChoiceLabel(app);
                });
                devices.forEach(function(device) {
                    if (!device.mac)
                        return;
                    var label = safeChoice('%s（%s）'.format(device.name || device.ip || device.mac, device.mac));
                    deviceOption.value(device.mac, label);
                    whitelistOption.value(device.mac, safeChoice('%s（%s）'.format(device.name || device.ip || device.mac, device.mac)));
                });
                categories.forEach(function(category) {
                    categoryOption.value(String(category.id), safeChoice(category.name));
                });
                appOption.profile = currentProfileId;
                appOption.categories = categories;
                appOption.labelCache = selectedLabels;
                managementReady = true;
                maybeRenderManagementForm();
            });
        }
        Promise.resolve(data.statusRequest).then(function(nextStatus) {
            updateStatusPanels(nextStatus);
        });
        return page;
    }
});
